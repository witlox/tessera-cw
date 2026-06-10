import Foundation
import GRDB

/// Read-only access to the bundled corpus. The generator depends on this
/// protocol, not on GRDB — so tests can inject an in-memory pool.
public protocol CorpusStore {
    /// One clued entry per word_id for the given languages, de-duplicated by
    /// gridForm (a grid cannot contain the same crossing key twice).
    /// Mirrors content/engine `load_pool`.
    func cluedPool(languages: [Lang], minLen: Int, maxLen: Int) throws -> [Entry]
}

/// GRDB implementation over the bundled, read-only `tessera.sqlite`.
public struct SQLiteCorpusStore: CorpusStore {
    private let dbQueue: DatabaseQueue

    public init(bundledResource: String = "tessera", ext: String = "sqlite",
                bundle: Bundle = .module) throws {
        guard let url = bundle.url(forResource: bundledResource, withExtension: ext) else {
            throw CorpusError.resourceMissing
        }
        var config = Configuration()
        config.readonly = true
        self.dbQueue = try DatabaseQueue(path: url.path, configuration: config)
    }

    public func cluedPool(languages: [Lang], minLen: Int = 3, maxLen: Int = 11) throws -> [Entry] {
        let codes = languages.map(\.rawValue)
        let placeholders = databaseQuestionMarks(count: codes.count)
        let sql = """
            SELECT w.grid_form, w.surface, w.language, cl.text
            FROM words w
            JOIN clues cl ON cl.word_id = w.id
            WHERE w.language IN (\(placeholders)) AND w.grid_len BETWEEN ? AND ?
            GROUP BY w.id
        """
        let args = StatementArguments(codes + [minLen, maxLen])
        return try dbQueue.read { db in
            var seen = Set<String>()
            var pool: [Entry] = []
            let rows = try Row.fetchCursor(db, sql: sql, arguments: args)
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

    public enum CorpusError: Error { case resourceMissing }
}
