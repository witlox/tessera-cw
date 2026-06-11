import Foundation
import TesseraKit

/// Snapshot suitable for JSON persistence. The Puzzle itself is small
/// (~28 entries, ~150 cells) — round-tripping is trivial.
struct SoloSnapshot: Codable {
    var puzzle: Puzzle
    var languages: [Lang]
    var difficulty: Generator.Difficulty
    var themeSlug: String?
    var startedAt: Date
    var state: GameState
}

/// Single-slot persistence in Application Support. Two writes back-to-back
/// (e.g. typing fast) are fine — this is a small file, atomic write.
enum SoloStore {
    private static let filename = "solo.json"

    private static var url: URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil, create: true) else { return nil }
        let folder = base.appendingPathComponent("Tessera", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(filename)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    @discardableResult
    static func save(_ snap: SoloSnapshot) -> Bool {
        guard let url else { return false }
        do {
            let data = try encoder.encode(snap)
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    static func load() -> SoloSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(SoloSnapshot.self, from: data)
    }

    static func clear() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
