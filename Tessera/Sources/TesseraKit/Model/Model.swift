import Foundation

/// Orientation of an entry on the board.
public enum Orientation: String, Sendable, Hashable, Codable { case across, down }

/// Supported corpus languages (Latin-script, high-resource).
public enum Lang: String, Sendable, CaseIterable, Codable {
    case en, nl, de, fr, es, it
}

/// Cell coordinate. Row grows downward, column rightward.
public struct Coord: Hashable, Sendable, Codable {
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
        // Stage 1: explicit map for non-decomposable glyphs (ß/æ/ł/ø/...).
        // Done BEFORE NFKD so ß→SS, ł→L, etc. survive the strip pass.
        var stage1 = ""
        for ch in surface.lowercased() {
            if ch.isWhitespace || ch == "-" || ch == "'" { continue }
            if let m = multi[ch] { stage1 += m }
            else if let s = single[ch] { stage1.append(s) }
            else { stage1.append(ch) }
        }
        // Stage 2: NFKD decomposes 'ó' → 'o' + combining acute. We iterate
        // unicode SCALARS (not Characters / grapheme clusters) so the base
        // 'o' survives and the combining mark is dropped — iterating
        // Characters would keep them glued together as one non-ASCII cluster.
        var out = ""
        for scalar in stage1.decomposedStringWithCanonicalMapping.unicodeScalars {
            let ch = Character(scalar)
            if ch.isASCII, ch.isLetter {
                out.append(Character(ch.uppercased()))
            }
        }
        return out
    }
}

/// A corpus word with one clue, ready to place. `gridForm` is the crossing key.
public struct Entry: Sendable, Hashable, Codable {
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
public struct PlacedEntry: Sendable, Hashable, Codable {
    public let entry: Entry
    public let origin: Coord
    public let orientation: Orientation
    public init(entry: Entry, origin: Coord, orientation: Orientation) {
        self.entry = entry; self.origin = origin; self.orientation = orientation
    }
    public var cells: [Coord] {
        (0..<entry.length).map { origin.step(orientation, $0) }
    }
}

/// A generated puzzle: the fixed solution plus its clue list. Player progress
/// (current fills, revealed cells) lives separately in GameState.
public struct Puzzle: Sendable, Codable {
    public let placed: [PlacedEntry]
    public let solution: [Coord: Character]   // correct letter per white cell
    public let languages: [Lang]
    public init(placed: [PlacedEntry], solution: [Coord: Character], languages: [Lang]) {
        self.placed = placed; self.solution = solution; self.languages = languages
    }

    // Character isn't Codable; encode the solution as ["r,c": "X"].
    private enum CK: String, CodingKey { case placed, solution, languages }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CK.self)
        self.placed = try c.decode([PlacedEntry].self, forKey: .placed)
        self.languages = try c.decode([Lang].self, forKey: .languages)
        let raw = try c.decode([String: String].self, forKey: .solution)
        var s: [Coord: Character] = [:]
        for (k, v) in raw {
            let parts = k.split(separator: ",")
            guard parts.count == 2, let r = Int(parts[0]), let col = Int(parts[1]),
                  let ch = v.first else { continue }
            s[Coord(r, col)] = ch
        }
        self.solution = s
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CK.self)
        try c.encode(placed, forKey: .placed)
        try c.encode(languages, forKey: .languages)
        var raw: [String: String] = [:]
        for (coord, ch) in solution { raw["\(coord.r),\(coord.c)"] = String(ch) }
        try c.encode(raw, forKey: .solution)
    }
}
