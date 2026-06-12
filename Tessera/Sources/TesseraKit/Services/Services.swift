import Foundation

// Service SEAMS only. Concrete GameKit conformances live in `Services/GameKitMatchService.swift`.
// These protocols let TesseraKit (generator, game logic) stay UI- and
// platform-agnostic and unit-testable.

/// Stable IDs for the two leaderboards. These strings MUST match exactly
/// the Leaderboard IDs you create under App Store Connect → Game Center →
/// Leaderboards for your app. Changing them after launch resets the
/// scores, so don't.
public enum LeaderboardID: String, Sendable, CaseIterable, Codable {
    case multiplayerWins  = "io.witlox.TesseraCrossword.multiplayerWins"
    case puzzlesSolved    = "io.witlox.TesseraCrossword.puzzlesSolved"

    public var displayName: String {
        switch self {
        case .multiplayerWins: return "Multiplayer wins"
        case .puzzlesSolved:   return "Puzzles solved"
        }
    }
}

/// Picker constraint: at least one, at most three languages per board. The
/// upper bound is a playability decision (mixing six Latin alphabets in one
/// grid stops being fun) — nothing monetary about it.
public struct LanguageMix: Sendable, Equatable {
    public static let maxLanguages = 3
    public let languages: [Lang]
    public init?(_ requested: [Lang]) {
        let unique = NSOrderedSet(array: requested.map(\.rawValue))
            .array.compactMap { Lang(rawValue: $0 as! String) }
        guard !unique.isEmpty else { return nil }
        self.languages = Array(unique.prefix(Self.maxLanguages))
    }
}

/// Async turn-based match seam (Game Center / GKTurnBasedMatch).
///
/// Fairness contract: a match carries a single puzzle `seed`; both players
/// generate the IDENTICAL board locally via `Generator(seed:)`. Only moves and
/// the shot-clock travel over the wire — never the solution.
public protocol MatchService {
    /// True once GKLocalPlayer has authenticated. The home screen uses this to
    /// gate the "Multiplayer" entry point.
    var isAuthenticated: Bool { get }

    /// Drives Game Center sign-in if needed. No-op on subsequent calls.
    func authenticate() async throws

    /// Attach to a match the user just picked in the matchmaker UI (or one
    /// the system delivered via a friend invite). If `matchData` is empty
    /// — i.e. we're the player who initiated — seed it with
    /// `seedingIfEmpty`. Returns the handle plus the initial payload so
    /// the local view can render before the next inbound event arrives.
    func attach(matchID: String,
                seedingIfEmpty: MatchConfig?) async throws -> (MatchHandle, MatchPayload)

    /// Stream of match IDs that arrived via the user picking from the
    /// matchmaker, a friend invite landing, or a background turn event on
    /// a not-yet-attached match. AppModel listens here and decides whether
    /// to attach (and create a view-model).
    var newMatches: AsyncStream<String> { get }

    /// Reloads the authoritative payload from the backing store. Called
    /// after every inbound event to absorb the opponent's last move.
    func payload(for match: MatchHandle) async throws -> MatchPayload

    /// Submit one filled cell within the active turn. Does NOT advance the
    /// turn — only `pass` / `submitClosing` / `signalDone` do that. The
    /// player keeps placing letters until they pass voluntarily, complete a
    /// word correctly, or the shot clock expires.
    func submit(_ move: Move, in match: MatchHandle) async throws

    /// Submit one filled cell AND end the turn in one shot. Used by the
    /// auto-pass-on-word-complete path so the opponent is notified
    /// immediately of the move that closed the word.
    func submitClosing(_ move: Move, in match: MatchHandle) async throws

    /// Voluntarily pass without filling. Caller picks the cell to reveal —
    /// it has the local Puzzle and the current GameState, so it can pick an
    /// untouched correct cell deterministically. Both clients compute the
    /// same candidate set from the seed + move log, so they agree.
    func pass(revealing cell: CoordWire, in match: MatchHandle) async throws

    /// Mark the local player as "I'm done". When `finalWinner` is nil the
    /// turn is handed to the opponent (first-done case). When non-nil this
    /// is the second-done call — the match is ended with that winner ID
    /// and final `matchOutcome`s set in the same operation.
    func signalDone(in match: MatchHandle, finalWinner: String?) async throws

    /// End the turn-based match. Sets `matchOutcome` to .won on the
    /// participant whose `gamePlayerID` matches `winnerPlayerID` and .lost
    /// on everyone else, then writes final matchData and closes the match.
    /// Called by `MatchViewModel` when the winning move just completed the
    /// puzzle. The other client will see `.matchEnded` via inbound.
    func endMatch(handle: MatchHandle, winnerPlayerID: String) async throws

    /// Post a score to a Game Center leaderboard. Best-effort — if the
    /// local player isn't authenticated, the call is silently dropped (we
    /// don't want a missing GC sign-in to fail solo completions).
    func reportLeaderboard(score: Int, to id: LeaderboardID) async throws

    /// Inbound match events (opponent moves, timeouts, completion).
    var inbound: AsyncStream<MatchEvent> { get }
}

/// Per-match configuration captured at start so both clients can reproduce
/// the identical board from `seed`.
public struct MatchConfig: Sendable, Codable, Hashable {
    public let seed: UInt64
    public let languages: [Lang]
    public let difficulty: Generator.Difficulty
    public let themeSlug: String?
    public init(seed: UInt64, languages: [Lang],
                difficulty: Generator.Difficulty, themeSlug: String?) {
        self.seed = seed; self.languages = languages
        self.difficulty = difficulty; self.themeSlug = themeSlug
    }
}

public struct MatchHandle: Sendable, Hashable {
    public let id: String
    public let config: MatchConfig
    public init(id: String, config: MatchConfig) { self.id = id; self.config = config }
}

public struct Move: Sendable, Codable, Hashable {
    /// Game Center `gamePlayerID` of the player who placed this letter. Used
    /// to attribute correct-letter count for the "both done → winner" tiebreak.
    public let by: String
    public let cell: CoordWire
    public let letter: Character
    /// Server-trusted shot-clock boundary (when the placing player's turn ends).
    public let atTurnDeadline: Date
    public init(by: String, cell: CoordWire, letter: Character, atTurnDeadline: Date) {
        self.by = by; self.cell = cell; self.letter = letter
        self.atTurnDeadline = atTurnDeadline
    }

    private enum CodingKeys: String, CodingKey { case by, cell, letter, atTurnDeadline }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(by, forKey: .by)
        try c.encode(cell, forKey: .cell)
        try c.encode(String(letter), forKey: .letter)
        try c.encode(atTurnDeadline, forKey: .atTurnDeadline)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `by` is optional during decoding for safety against any in-flight
        // pre-bump payloads; "" means "unattributed" and won't match either
        // player when the tiebreak runs.
        by = (try? c.decode(String.self, forKey: .by)) ?? ""
        cell = try c.decode(CoordWire.self, forKey: .cell)
        let s = try c.decode(String.self, forKey: .letter)
        guard let ch = s.first else {
            throw DecodingError.dataCorruptedError(forKey: .letter, in: c,
                debugDescription: "empty letter")
        }
        letter = ch
        atTurnDeadline = try c.decode(Date.self, forKey: .atTurnDeadline)
    }
}

public enum MatchEvent: Sendable {
    case opponentMove(Move)
    case opponentPassed(revealedCell: CoordWire)
    case turnTimedOut
    case matchEnded(winner: String?)
}

/// Codable mirror of Coord for the wire (Coord stays a value type internal).
public struct CoordWire: Sendable, Codable, Hashable {
    public let r: Int
    public let c: Int
    public init(_ r: Int, _ c: Int) { self.r = r; self.c = c }
    public init(_ coord: Coord) { self.r = coord.r; self.c = coord.c }
    public var coord: Coord { Coord(r, c) }
}
