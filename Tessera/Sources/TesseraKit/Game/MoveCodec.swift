import Foundation

/// Wire payload that lives inside `GKTurnBasedMatch.matchData`. Carries
/// everything needed for either client to reconstruct identical board state
/// without ever transmitting the puzzle solution itself.
public struct MatchPayload: Sendable, Codable {
    public static let currentVersion = 3
    public let version: Int
    public let config: MatchConfig
    /// Move log — attribution per cell for the both-done tiebreak.
    /// v3 no longer replays this to derive `fills` (the `fills` snapshot is
    /// authoritative); it's preserved only so the winner can be picked by
    /// correct-letter count when both players signal done.
    public let moves: [Move]
    /// Reveal-on-pass selections (deterministic per turn so both clients agree).
    public let passReveals: [PassReveal]
    /// IDs of players who have permanently signalled "I'm done". Once both
    /// players are in this list, the match ends (winner by correct-letter
    /// count; tiebreak: whoever signalled done first).
    public let doneSignals: [String]
    /// Player IDs in turn order. Used to attribute moves and resolve completion.
    public let players: [String]
    public let createdAt: Date
    /// Authoritative ID of the player whose turn it is right now.
    public let currentPlayer: String

    /// v3 snapshot of every filled cell on the board. Coord encoded as
    /// "r,c". Letters from the move log no longer drive replay — a
    /// failed Check needs to be able to delete filled cells without
    /// rewriting history, and an interleaved event log would balloon
    /// the wire payload. The snapshot is small (≤ board cells × 2
    /// bytes) and authoritative.
    public let fills: [String: String]
    /// v3 cumulative set of locked cells — once a Check passes on an
    /// entry, every cell in it goes here and `place` refuses to overwrite
    /// them. Same string encoding as `fills` keys.
    public let lockedCells: [CoordWire]

    public init(config: MatchConfig, moves: [Move] = [],
                passReveals: [PassReveal] = [],
                doneSignals: [String] = [],
                players: [String], createdAt: Date,
                currentPlayer: String? = nil,
                fills: [String: String] = [:],
                lockedCells: [CoordWire] = []) {
        self.version = Self.currentVersion
        self.config = config
        self.moves = moves
        self.passReveals = passReveals
        self.doneSignals = doneSignals
        self.players = players
        self.createdAt = createdAt
        self.currentPlayer = currentPlayer ?? players.first ?? ""
        self.fills = fills
        self.lockedCells = lockedCells
    }

    /// Copy-with for the turn-ending operations. v3 adds `fills` and
    /// `lockedCells`; every write that touches the board emits a fresh
    /// snapshot, so even a within-turn `submit` should pass the current
    /// fills through.
    public func with(moves: [Move]? = nil,
                     passReveals: [PassReveal]? = nil,
                     doneSignals: [String]? = nil,
                     players: [String]? = nil,
                     currentPlayer: String? = nil,
                     fills: [String: String]? = nil,
                     lockedCells: [CoordWire]? = nil) -> MatchPayload {
        MatchPayload(
            config: config,
            moves: moves ?? self.moves,
            passReveals: passReveals ?? self.passReveals,
            doneSignals: doneSignals ?? self.doneSignals,
            players: players ?? self.players,
            createdAt: createdAt,
            currentPlayer: currentPlayer ?? self.currentPlayer,
            fills: fills ?? self.fills,
            lockedCells: lockedCells ?? self.lockedCells
        )
    }

    public struct PassReveal: Sendable, Codable, Hashable {
        public let by: String         // player ID who passed
        public let revealed: CoordWire
        public let at: Date
        public init(by: String, revealed: CoordWire, at: Date) {
            self.by = by; self.revealed = revealed; self.at = at
        }
    }

    private enum CK: String, CodingKey {
        case version, config, moves, passReveals, doneSignals
        case players, createdAt, currentPlayer
        case fills, lockedCells
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CK.self)
        self.version = (try? c.decode(Int.self, forKey: .version)) ?? Self.currentVersion
        self.config = try c.decode(MatchConfig.self, forKey: .config)
        self.moves = try c.decode([Move].self, forKey: .moves)
        self.passReveals = try c.decode([PassReveal].self, forKey: .passReveals)
        self.doneSignals = (try? c.decode([String].self, forKey: .doneSignals)) ?? []
        self.players = try c.decode([String].self, forKey: .players)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        if let cp = try? c.decode(String.self, forKey: .currentPlayer), !cp.isEmpty {
            self.currentPlayer = cp
        } else {
            self.currentPlayer = self.players.first ?? ""
        }
        // v3 fields — absent in v2 matches still in flight on TestFlight.
        // For v2, the empty snapshot is filled by `gameState(for:)`'s
        // move-replay fallback so resumed games render correctly.
        self.fills = (try? c.decode([String: String].self, forKey: .fills)) ?? [:]
        self.lockedCells = (try? c.decode([CoordWire].self, forKey: .lockedCells)) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CK.self)
        try c.encode(version, forKey: .version)
        try c.encode(config, forKey: .config)
        try c.encode(moves, forKey: .moves)
        try c.encode(passReveals, forKey: .passReveals)
        try c.encode(doneSignals, forKey: .doneSignals)
        try c.encode(players, forKey: .players)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(currentPlayer, forKey: .currentPlayer)
        try c.encode(fills, forKey: .fills)
        try c.encode(lockedCells, forKey: .lockedCells)
    }
}

public enum MoveCodec {
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

    public static func encode(_ payload: MatchPayload) throws -> Data {
        try encoder.encode(payload)
    }
    public static func decode(_ data: Data) throws -> MatchPayload {
        try decoder.decode(MatchPayload.self, from: data)
    }
}

public extension MatchPayload {
    /// Rebuilds the current GameState from `config` + payload snapshot.
    /// v3 trusts `fills` as the authoritative cell-content map; v2 (no
    /// snapshot persisted) falls back to replaying the move log so
    /// in-flight matches on TestFlight upgrade cleanly. Locked cells are
    /// always written with the truth letter from `puzzle.solution`, and
    /// `passReveals` add their cell as opponent-revealed truth.
    func gameState(for puzzle: Puzzle) -> GameState {
        var s = GameState()
        if !fills.isEmpty {
            for (key, letter) in fills {
                guard let coord = Coord.parse(key), let ch = letter.first else { continue }
                s.fills[coord] = ch
            }
        } else {
            // v2 payload: derive fills from move-log replay.
            for m in moves {
                s.place(m.letter, at: m.cell.coord, in: puzzle)
            }
        }
        for wire in lockedCells {
            s.locked.insert(wire.coord)
            if let truth = puzzle.solution[wire.coord] {
                s.fills[wire.coord] = truth
            }
        }
        for p in passReveals {
            s.revealedByOpponent.insert(p.revealed.coord)
            if let truth = puzzle.solution[p.revealed.coord] {
                s.fills[p.revealed.coord] = truth
            }
        }
        return s
    }

    /// Whose turn it is right now. Letters placed within a turn do NOT
    /// advance the turn — only `pass`, `check` or `signalDone` do, and each
    /// writes the new `currentPlayer` into the payload.
    var currentTurnPlayer: String? {
        guard !players.isEmpty else { return nil }
        return currentPlayer.isEmpty ? players.first : currentPlayer
    }

    /// Other player relative to the given ID. Two-player only.
    func other(than p: String) -> String? {
        players.first { $0 != p }
    }

    /// Number of correct letters attributable to the given player, used as
    /// the both-done tiebreak. We take the LATEST move per cell (last-wins)
    /// AND check the snapshot still contains that letter — a failed Check
    /// could have cleared it.
    func correctLetterCount(playerID: String, puzzle: Puzzle) -> Int {
        var latest: [Coord: Move] = [:]
        for m in moves {
            latest[m.cell.coord] = m
        }
        var count = 0
        for (coord, move) in latest where move.by == playerID {
            guard puzzle.solution[coord] == move.letter else { continue }
            if !fills.isEmpty {
                let key = "\(coord.r),\(coord.c)"
                guard fills[key] != nil else { continue }
            }
            count += 1
        }
        return count
    }
}

/// String-keying helper for `fills`. Coord keys travel as "r,c" so the
/// JSON dictionary stays homogeneous (`JSONEncoder` can't key on
/// arbitrary Codable types).
extension Coord {
    public static func parse(_ s: String) -> Coord? {
        let parts = s.split(separator: ",")
        guard parts.count == 2, let r = Int(parts[0]), let c = Int(parts[1]) else { return nil }
        return Coord(r, c)
    }
    public var wireKey: String { "\(r),\(c)" }
}
