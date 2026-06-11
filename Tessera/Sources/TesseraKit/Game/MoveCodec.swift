import Foundation

/// Wire payload that lives inside `GKTurnBasedMatch.matchData`. Carries
/// everything needed for either client to reconstruct identical board state
/// without ever transmitting the puzzle solution itself.
public struct MatchPayload: Sendable, Codable {
    public static let currentVersion = 1
    public let version: Int
    public let config: MatchConfig
    /// Move log — replay produces the current `fills` map deterministically.
    public let moves: [Move]
    /// Reveal-on-pass selections (deterministic per turn so both clients agree).
    public let passReveals: [PassReveal]
    /// Player IDs in turn order. Used to attribute moves and resolve completion.
    public let players: [String]
    public let createdAt: Date

    public init(config: MatchConfig, moves: [Move] = [],
                passReveals: [PassReveal] = [], players: [String], createdAt: Date) {
        self.version = Self.currentVersion
        self.config = config
        self.moves = moves
        self.passReveals = passReveals
        self.players = players
        self.createdAt = createdAt
    }

    public struct PassReveal: Sendable, Codable, Hashable {
        public let by: String         // player ID who passed
        public let revealed: CoordWire
        public let at: Date
        public init(by: String, revealed: CoordWire, at: Date) {
            self.by = by; self.revealed = revealed; self.at = at
        }
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

    /// Whose turn it is right now, given the move count modulo player count.
    /// Passes count as "no move" so they also advance the turn — encoded by
    /// the caller appending to `passReveals`, and updating `moves` count via
    /// virtual tick (we treat reveals as turn-advancing too).
    var currentTurnPlayer: String? {
        guard !players.isEmpty else { return nil }
        let turn = moves.count + passReveals.count
        return players[turn % players.count]
    }
}
