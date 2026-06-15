import Foundation

/// Per-puzzle player progress. Independent of solo vs. multiplayer: solo stores
/// it locally; multiplayer ships a serialised copy in `GKTurnBasedMatch.matchData`
/// alongside the move log so both clients agree on what's been revealed.
public struct GameState: Sendable, Codable, Equatable {
    /// Player-filled letters (may be wrong; correctness checked against the puzzle).
    public var fills: [Coord: Character]
    /// Cells the player has explicitly revealed (truth shown regardless of fill).
    public var revealed: Set<Coord>
    /// Cells the opponent's "reveal-on-pass" granted (multiplayer only).
    public var revealedByOpponent: Set<Coord>
    /// Cells locked by a successful Check (multiplayer only). The letter at
    /// a locked cell is the puzzle's solution and `place` / `clear` refuse
    /// to touch it.
    public var locked: Set<Coord>
    /// Whose entry is currently highlighted; the BoardView drives selection.
    public var selection: Selection?
    /// Wall-clock total play time, in seconds. Solo only; ignored in multiplayer.
    public var elapsedSeconds: Double

    public init(fills: [Coord: Character] = [:],
                revealed: Set<Coord> = [],
                revealedByOpponent: Set<Coord> = [],
                locked: Set<Coord> = [],
                selection: Selection? = nil,
                elapsedSeconds: Double = 0) {
        self.fills = fills; self.revealed = revealed
        self.revealedByOpponent = revealedByOpponent
        self.locked = locked
        self.selection = selection; self.elapsedSeconds = elapsedSeconds
    }

    public struct Selection: Sendable, Codable, Equatable {
        public var origin: Coord
        public var orientation: Orientation
        public init(origin: Coord, orientation: Orientation) {
            self.origin = origin; self.orientation = orientation
        }
    }

    // MARK: - Queries

    public func isComplete(_ puzzle: Puzzle) -> Bool {
        for (coord, correct) in puzzle.solution {
            if revealed.contains(coord) || revealedByOpponent.contains(coord)
                || locked.contains(coord) { continue }
            guard let f = fills[coord], f == correct else { return false }
        }
        return true
    }

    public func wrongCells(_ puzzle: Puzzle) -> Set<Coord> {
        var bad: Set<Coord> = []
        for (coord, ch) in fills {
            if revealed.contains(coord) || revealedByOpponent.contains(coord)
                || locked.contains(coord) { continue }
            if puzzle.solution[coord] != ch { bad.insert(coord) }
        }
        return bad
    }

    public func effectiveLetter(_ coord: Coord, in puzzle: Puzzle) -> Character? {
        if revealed.contains(coord) || revealedByOpponent.contains(coord)
            || locked.contains(coord) {
            return puzzle.solution[coord]
        }
        return fills[coord]
    }

    // MARK: - Mutations

    public mutating func place(_ letter: Character, at coord: Coord, in puzzle: Puzzle) {
        guard puzzle.solution[coord] != nil else { return }
        if revealed.contains(coord) || revealedByOpponent.contains(coord)
            || locked.contains(coord) { return }
        fills[coord] = letter
    }

    public mutating func clear(at coord: Coord) {
        if revealed.contains(coord) || revealedByOpponent.contains(coord)
            || locked.contains(coord) { return }
        fills.removeValue(forKey: coord)
    }

    public mutating func revealCell(_ coord: Coord, in puzzle: Puzzle) {
        guard puzzle.solution[coord] != nil else { return }
        revealed.insert(coord)
        fills[coord] = puzzle.solution[coord]
    }

    public mutating func revealEntry(_ placed: PlacedEntry, in puzzle: Puzzle) {
        for c in placed.cells { revealCell(c, in: puzzle) }
    }

    public mutating func revealAll(in puzzle: Puzzle) {
        for c in puzzle.solution.keys { revealCell(c, in: puzzle) }
    }

    public func pickUntouchedCell(_ puzzle: Puzzle, rng: inout SeededRNG) -> Coord? {
        let untouched = puzzle.solution.keys.filter { c in
            fills[c] == nil && !revealed.contains(c) && !revealedByOpponent.contains(c)
                && !locked.contains(c)
        }
        return untouched.isEmpty ? nil : untouched.randomElement(using: &rng)
    }

    // MARK: - Codable (custom; Coord-keyed dicts and Character don't auto-synthesise)

    private enum CK: String, CodingKey {
        case fills, revealed, revealedByOpponent, locked, selection, elapsedSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CK.self)
        let fillsRaw = try c.decode([String: String].self, forKey: .fills)
        var f: [Coord: Character] = [:]
        for (k, v) in fillsRaw {
            guard let coord = Coord.parse(k), let ch = v.first else { continue }
            f[coord] = ch
        }
        self.fills = f
        self.revealed = Set(try c.decode([String].self, forKey: .revealed)
                              .compactMap(Coord.parse))
        self.revealedByOpponent = Set(try c.decode([String].self, forKey: .revealedByOpponent)
                              .compactMap(Coord.parse))
        // Backwards compat — solo saves from before locked existed have no
        // such key; default to empty.
        self.locked = Set((try? c.decode([String].self, forKey: .locked))?
                              .compactMap(Coord.parse) ?? [])
        self.selection = try c.decodeIfPresent(Selection.self, forKey: .selection)
        self.elapsedSeconds = try c.decode(Double.self, forKey: .elapsedSeconds)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CK.self)
        var fillsRaw: [String: String] = [:]
        for (coord, ch) in fills { fillsRaw[coord.wireKey] = String(ch) }
        try c.encode(fillsRaw, forKey: .fills)
        try c.encode(revealed.map(\.wireKey).sorted(), forKey: .revealed)
        try c.encode(revealedByOpponent.map(\.wireKey).sorted(), forKey: .revealedByOpponent)
        try c.encode(locked.map(\.wireKey).sorted(), forKey: .locked)
        try c.encodeIfPresent(selection, forKey: .selection)
        try c.encode(elapsedSeconds, forKey: .elapsedSeconds)
    }
}

// `Coord.parse` / `Coord.wireKey` live in MoveCodec.swift — the wire
// payload uses the same encoding so both files share a single helper.

