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

    /// Match IDs of the local player's currently active (non-ended)
    /// turn-based matches, sorted most-recently-active first. Used by the
    /// home screen to surface ongoing games at launch without waiting for
    /// an opponent turn event — without this, a cold-launched app shows
    /// nothing until the user re-opens the match via an invite or a
    /// notification tap.
    func loadActiveMatchIDs() async throws -> [String]

    /// Reloads the authoritative payload from the backing store. Called
    /// after every inbound event to absorb the opponent's last move.
    func payload(for match: MatchHandle) async throws -> MatchPayload

    /// Submit one filled cell within the active turn. Does NOT advance the
    /// turn — only `pass` / `check` / `signalDone` do. `fills` is the full
    /// post-placement snapshot so the wire payload stays a self-describing
    /// truth (a failed Check needs to clear cells without rewriting the
    /// move log, so we no longer derive `fills` by replaying moves).
    func submit(_ move: Move, fills: [String: String],
                in match: MatchHandle) async throws

    /// Verify the cells the player has placed in an entry and end the turn.
    /// Caller computes the outcome locally (it has the solution): if the
    /// entry is fully correct it passes the entry's cells in `locks`; if
    /// any letter is wrong it passes those cells in `clears`. `fills` is
    /// the post-Check snapshot (already with `clears` removed by the
    /// caller). One operation, one turn boundary.
    func check(locks: [CoordWire], clears: [CoordWire],
               fills: [String: String], in match: MatchHandle) async throws

    /// Voluntarily pass without filling. Caller picks the cell to reveal —
    /// it has the local Puzzle and the current GameState, so it can pick an
    /// untouched correct cell deterministically. Both clients compute the
    /// same candidate set from the seed + state, so they agree. `fills`
    /// captures whatever the player typed during their turn.
    func pass(revealing cell: CoordWire, fills: [String: String],
              in match: MatchHandle) async throws

    /// Mark the local player as "I'm done". When `finalWinner` is nil the
    /// turn is handed to the opponent (first-done case). When non-nil this
    /// is the second-done call — the match is ended with that winner ID
    /// and final `matchOutcome`s set in the same operation.
    func signalDone(fills: [String: String], in match: MatchHandle,
                    finalWinner: String?) async throws

    /// End the turn-based match atomically with the winning move folded in.
    /// `move` is optional — when the puzzle is completed by a Check (which
    /// doesn't add a Move), pass nil. `locks` carries any cells the same
    /// operation should lock (the Check's entry). `fills` is the final
    /// board snapshot. Sets `matchOutcome` to .won on the
    /// `winnerPlayerID` participant and .lost on everyone else, then
    /// writes final matchData and closes the match — ONE GameKit write,
    /// no save-then-end race that produced GKError 5003 / `current-turn-
    /// number value: -1` when both writes hit the server back-to-back.
    func endMatch(move: Move?, locks: [CoordWire],
                  fills: [String: String], winnerPlayerID: String,
                  in match: MatchHandle) async throws

    /// Permanently leave a match without finishing it. Used to recover
    /// from corrupted state on the home screen (and from the in-match
    /// overflow). Sets the local participant's `matchOutcome` to `.quit`
    /// and ends the match for the local player; the other client sees a
    /// `.matchEnded` event with the local player as loser.
    func quit(handle: MatchHandle) async throws

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
    /// Game Center display name of the opponent at the time of attach.
    /// Nil while GameKit hasn't yet bound the invitee's `GKPlayer` to the
    /// participant slot — the view layer falls back to a generic
    /// "Opponent" string when this is nil.
    public let opponentDisplayName: String?
    public init(id: String, config: MatchConfig, opponentDisplayName: String? = nil) {
        self.id = id; self.config = config
        self.opponentDisplayName = opponentDisplayName
    }
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
    /// The opponent just ended their turn (or the user opened a match the
    /// listener was watching). Carries the freshly-decoded payload from
    /// GameKit's authoritative `matchData` so the view-model can refresh
    /// directly — no second server round-trip, and no risk of a stale
    /// `GKTurnBasedMatch.load(withID:)` cache hit missing the opponent's
    /// latest moves. `matchID` lets `AppModel` dispatch the event to the
    /// right match — events for one match must not bleed into another
    /// match's view-model.
    case turnReceived(matchID: String, MatchPayload)
    case matchEnded(matchID: String, winner: String?)
}

/// Codable mirror of Coord for the wire (Coord stays a value type internal).
public struct CoordWire: Sendable, Codable, Hashable {
    public let r: Int
    public let c: Int
    public init(_ r: Int, _ c: Int) { self.r = r; self.c = c }
    public init(_ coord: Coord) { self.r = coord.r; self.c = coord.c }
    public var coord: Coord { Coord(r, c) }
}
