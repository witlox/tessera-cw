import Foundation

/// Orientation of an entry on the board.
public enum Orientation: Sendable, Hashable { case across, down }

/// Supported corpus languages (Latin-script, high-resource).
public enum Lang: String, Sendable, CaseIterable, Codable {
    case en, nl, de, fr, es, it
}

/// Cell coordinate. Row grows downward, column rightward.
public struct Coord: Hashable, Sendable {
    public let r: Int, c: Int
    public init(_ r: Int, _ c: Int) { self.r = r; self.c = c }
    public func step(_ o: Orientation, _ i: Int) -> Coord {
        o == .across ? Coord(r, c + i) : Coord(r + i, c)
    }
}

/// Canonical A–Z crossing key, mirroring the Python `grid_form()` exactly.
/// Crossings match on this, never on the diacritic surface. Keep folding rules
/// IN SYNC with content/tessera_content.py (the corpus is built with that one).
public enum GridForm {
    private static let multi: [Character: String] = [
        "ß": "SS", "æ": "AE", "œ": "OE", "þ": "TH"
    ]
    private static let single: [Character: Character] = [
        "ł": "L", "ø": "O", "đ": "D", "ð": "D", "ñ": "N"
    ]
    public static func fold(_ surface: String) -> String {
        var out = ""
        // NFKD strips combining accents; explicit map handles ligatures/strokes.
        for ch in surface.lowercased().decomposedStringWithCanonicalMapping {
            if ch.isWhitespace || ch == "-" || ch == "'" { continue }
            if let m = multi[ch] { out += m }
            else if let s = single[ch] { out.append(s) }
            else if ch.isLetter, ch.isASCII { out.append(Character(ch.uppercased())) }
            // non-ASCII combining marks (from NFKD) are dropped
        }
        return out
    }
}

/// A corpus word with one clue, ready to place. `gridForm` is the crossing key.
public struct Entry: Sendable, Hashable {
    public let gridForm: String      // e.g. "STRASSE"
    public let surface: String       // e.g. "Straße" (display)
    public let language: Lang
    public let clue: String
    public init(gridForm: String, surface: String, language: Lang, clue: String) {
        self.gridForm = gridForm; self.surface = surface
        self.language = language; self.clue = clue
    }
    public var length: Int { gridForm.count }
}

/// An entry fixed onto the board at an origin and orientation.
public struct PlacedEntry: Sendable, Hashable {
    public let entry: Entry
    public let origin: Coord
    public let orientation: Orientation
    public var cells: [Coord] {
        (0..<entry.length).map { origin.step(orientation, $0) }
    }
}

/// A generated puzzle: the fixed solution plus its clue list. Player progress
/// (current fills, revealed cells) lives separately in GameState.
public struct Puzzle: Sendable {
    public let placed: [PlacedEntry]
    public let solution: [Coord: Character]   // correct letter per white cell
    public let languages: [Lang]
    public init(placed: [PlacedEntry], solution: [Coord: Character], languages: [Lang]) {
        self.placed = placed; self.solution = solution; self.languages = languages
    }
}
