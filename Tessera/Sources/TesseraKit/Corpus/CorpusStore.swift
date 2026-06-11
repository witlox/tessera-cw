import Foundation
import GRDB

/// Read-only access to the bundled corpus. The generator depends on this
/// protocol, not on GRDB — so tests can inject an in-memory pool.
public protocol CorpusStore {
    /// One clued entry per word_id for the given languages, de-duplicated by
    /// gridForm (a grid cannot contain the same crossing key twice). When
    /// `themeSlug` is provided, the pool is restricted to words that belong to
    /// that theme; theme membership is populated for all 6 clued languages.
    func cluedPool(languages: [Lang], themeSlug: String?, minLen: Int, maxLen: Int) throws -> [Entry]

    /// Themes available in the corpus. Each carries the count of clued words
    /// per language so the picker can show effective pool size up front.
    func themes() throws -> [Theme]

    /// Effective pool size for a (languages, theme) combo. The picker uses this
    /// to gate "too sparse to play" and to scale the generator's target.
    func poolCount(languages: [Lang], themeSlug: String?, minLen: Int, maxLen: Int) throws -> Int
}

public struct Theme: Sendable, Hashable, Identifiable {
    public let slug: String
    public let label: String
    /// language code → clued-word count in this theme
    public let counts: [String: Int]
    public var id: String { slug }
    public init(slug: String, label: String, counts: [String: Int]) {
        self.slug = slug; self.label = label; self.counts = counts
    }
}

/// GRDB implementation over the bundled, read-only `tessera.sqlite`.
public struct SQLiteCorpusStore: CorpusStore {
    private let dbQueue: DatabaseQueue

    /// Default initialiser — loads the bundled corpus baked into TesseraKit.
    public init() throws {
        try self.init(bundle: .module)
    }

    /// Test seam — point at a different `.sqlite` in any bundle.
    public init(bundle: Bundle, resource: String = "tessera", ext: String = "sqlite") throws {
        guard let url = bundle.url(forResource: resource, withExtension: ext) else {
            throw CorpusError.resourceMissing
        }
        var config = Configuration()
        config.readonly = true
        self.dbQueue = try DatabaseQueue(path: url.path, configuration: config)
    }

    public func cluedPool(languages: [Lang], themeSlug: String? = nil,
                          minLen: Int = 3, maxLen: Int = 11) throws -> [Entry] {
        let codes = languages.map(\.rawValue)
        let langPlaceholders = databaseQuestionMarks(count: codes.count)
        var sql = """
            SELECT w.grid_form, w.surface, w.language, cl.text
            FROM words w
            JOIN clues cl ON cl.word_id = w.id AND cl.validated = 1
            """
        var args: [DatabaseValueConvertible] = []
        if themeSlug != nil {
            sql += """
                 JOIN word_groups wg ON wg.word_id = w.id
                 JOIN groups g       ON g.id       = wg.group_id AND g.slug = ?
                """
            args.append(themeSlug!)
        }
        sql += """
             WHERE w.language IN (\(langPlaceholders)) AND w.grid_len BETWEEN ? AND ?
             GROUP BY w.id
            """
        args.append(contentsOf: codes)
        args.append(minLen); args.append(maxLen)

        return try dbQueue.read { db in
            var seen = Set<String>()
            var pool: [Entry] = []
            let rows = try Row.fetchCursor(db, sql: sql, arguments: StatementArguments(args))
            while let row = try rows.next() {
                let gf: String = row[0]
                if seen.contains(gf) { continue }     // de-dup by crossing key
                seen.insert(gf)
                guard let lang = Lang(rawValue: row[2]) else { continue }
                pool.append(Entry(gridForm: gf, surface: row[1], language: lang, clue: row[3]))
            }
            return pool
        }
    }

    public func themes() throws -> [Theme] {
        try dbQueue.read { db in
            let groupRows = try Row.fetchAll(db, sql:
                "SELECT id, slug, label_en FROM groups ORDER BY slug")
            var themes: [Theme] = []
            for g in groupRows {
                let gid: Int = g[0]
                let countRows = try Row.fetchAll(db, sql: """
                    SELECT w.language, COUNT(*)
                    FROM word_groups wg
                    JOIN words w ON w.id = wg.word_id
                    JOIN clues c ON c.word_id = w.id AND c.validated = 1 AND c.language = w.language
                    WHERE wg.group_id = ?
                    GROUP BY w.language
                    """, arguments: [gid])
                var counts: [String: Int] = [:]
                for r in countRows { counts[r[0]] = r[1] }
                themes.append(Theme(slug: g[1], label: g[2], counts: counts))
            }
            return themes
        }
    }

    public func poolCount(languages: [Lang], themeSlug: String? = nil,
                          minLen: Int = 3, maxLen: Int = 11) throws -> Int {
        // Cheaper than materialising entries; the picker calls this on every change.
        let codes = languages.map(\.rawValue)
        let langPlaceholders = databaseQuestionMarks(count: codes.count)
        var sql = """
            SELECT COUNT(DISTINCT w.grid_form)
            FROM words w
            JOIN clues cl ON cl.word_id = w.id AND cl.validated = 1
            """
        var args: [DatabaseValueConvertible] = []
        if themeSlug != nil {
            sql += """
                 JOIN word_groups wg ON wg.word_id = w.id
                 JOIN groups g       ON g.id       = wg.group_id AND g.slug = ?
                """
            args.append(themeSlug!)
        }
        sql += " WHERE w.language IN (\(langPlaceholders)) AND w.grid_len BETWEEN ? AND ?"
        args.append(contentsOf: codes)
        args.append(minLen); args.append(maxLen)
        return try dbQueue.read { db in
            try Int.fetchOne(db, sql: sql, arguments: StatementArguments(args)) ?? 0
        }
    }

    public enum CorpusError: Error { case resourceMissing }
}
