import Foundation

/// Wire payload that lives inside `GKTurnBasedMatch.matchData`. Carries
/// everything needed for either client to reconstruct identical board state
/// without ever transmitting the puzzle solution itself.
public struct MatchPayload: Sendable, Codable {
    public static let currentVersion = 2
    public let version: Int
    public let config: MatchConfig
    /// Move log — replay produces the current `fills` map deterministically.
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
    /// Authoritative ID of the player whose turn it is right now. Updated by
    /// every turn-ending operation (pass, submitClosing, signalDone). The
    /// payload-derived `currentTurnPlayer` reads this directly rather than
    /// computing turn count modulo, which can't represent auto-pass-on-word
    /// vs. pass-with-reveal without yet another counter.
    public let currentPlayer: String

    public init(config: MatchConfig, moves: [Move] = [],
                passReveals: [PassReveal] = [],
                doneSignals: [String] = [],
                players: [String], createdAt: Date,
                currentPlayer: String? = nil) {
        self.version = Self.currentVersion
        self.config = config
        self.moves = moves
        self.passReveals = passReveals
        self.doneSignals = doneSignals
        self.players = players
        self.createdAt = createdAt
        self.currentPlayer = currentPlayer ?? players.first ?? ""
    }

    /// Copy-with for the turn-ending operations.
    public func with(moves: [Move]? = nil,
                     passReveals: [PassReveal]? = nil,
                     doneSignals: [String]? = nil,
                     currentPlayer: String? = nil) -> MatchPayload {
        MatchPayload(
            config: config,
            moves: moves ?? self.moves,
            passReveals: passReveals ?? self.passReveals,
            doneSignals: doneSignals ?? self.doneSignals,
            players: players,
            createdAt: createdAt,
            currentPlayer: currentPlayer ?? self.currentPlayer
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
    /// Rebuilds the current GameState from `config` + moves + reveals.
    /// `puzzle` must be generated from `config.seed` on the local pool so
    /// solution coords align with the move log.
    func gameState(for puzzle: Puzzle) -> GameState {
        var s = GameState()
        for m in moves {
            s.place(m.letter, at: m.cell.coord, in: puzzle)
        }
        for p in passReveals {
            // Treat as opponent-granted reveal from the other player's POV.
            // The view layer decides whether to colour it differently.
            s.revealedByOpponent.insert(p.revealed.coord)
            if let truth = puzzle.solution[p.revealed.coord] {
                s.fills[p.revealed.coord] = truth
            }
        }
        return s
    }

    /// Whose turn it is right now. Letters placed within a turn do NOT
    /// advance the turn — only `pass`, `submitClosing` (auto-pass on word
    /// complete) or `signalDone` do, and each of those writes the new
    /// `currentPlayer` into the payload.
    var currentTurnPlayer: String? {
        guard !players.isEmpty else { return nil }
        return currentPlayer.isEmpty ? players.first : currentPlayer
    }

    /// Other player relative to the given ID. Two-player only.
    func other(than p: String) -> String? {
        players.first { $0 != p }
    }

    /// Number of correct letters attributable to the given player, used as
    /// the both-done tiebreak. We take the LATEST move per cell (last-wins),
    /// then count the ones placed by `playerID` that match the solution.
    func correctLetterCount(playerID: String, puzzle: Puzzle) -> Int {
        var latest: [Coord: Move] = [:]
        for m in moves {
            latest[m.cell.coord] = m
        }
        var count = 0
        for (coord, move) in latest where move.by == playerID {
            if puzzle.solution[coord] == move.letter { count += 1 }
        }
        return count
    }
}
