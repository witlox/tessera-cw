import Foundation

/// `MatchService` stand-in used in unit tests, previews, and the
/// "Game Center unavailable" fallback path. Every networked operation throws
/// a descriptive error so the UI's empty state can quote it verbatim.
public final class StubMatchService: MatchService, @unchecked Sendable {
    public var isAuthenticated: Bool { false }
    public let inbound: AsyncStream<MatchEvent>
    public let newMatches: AsyncStream<String>
    private let continuation: AsyncStream<MatchEvent>.Continuation
    private let newMatchesContinuation: AsyncStream<String>.Continuation

    public init() {
        var cont: AsyncStream<MatchEvent>.Continuation!
        self.inbound = AsyncStream { cont = $0 }
        var nm: AsyncStream<String>.Continuation!
        self.newMatches = AsyncStream { nm = $0 }
        self.continuation = cont
        self.newMatchesContinuation = nm
    }

    public func authenticate() async throws {
        throw Error.unavailable
    }
    public func attach(matchID: String,
                       seedingIfEmpty: MatchConfig?) async throws -> (MatchHandle, MatchPayload) {
        throw Error.unavailable
    }
    public func payload(for match: MatchHandle) async throws -> MatchPayload {
        throw Error.unavailable
    }
    public func submit(_ move: Move, fills: [String: String],
                       in match: MatchHandle) async throws {
        throw Error.unavailable
    }
    public func check(locks: [CoordWire], clears: [CoordWire],
                      fills: [String: String], in match: MatchHandle) async throws {
        throw Error.unavailable
    }
    public func pass(revealing cell: CoordWire, fills: [String: String],
                     in match: MatchHandle) async throws {
        throw Error.unavailable
    }
    public func signalDone(fills: [String: String], in match: MatchHandle,
                           finalWinner: String?) async throws {
        throw Error.unavailable
    }
    public func endMatch(move: Move?, locks: [CoordWire],
                         fills: [String: String], winnerPlayerID: String,
                         in match: MatchHandle) async throws {
        throw Error.unavailable
    }
    public func quit(handle: MatchHandle) async throws {
        throw Error.unavailable
    }
    public func reportLeaderboard(score: Int, to id: LeaderboardID) async throws {
        // Silently ignore — caller treats leaderboard posts as best-effort.
    }
    public func loadActiveMatchIDs() async throws -> [String] { [] }

    public enum Error: LocalizedError {
        case unavailable
        public var errorDescription: String? {
            "Multiplayer needs Game Center; this build can’t reach it. " +
            "Finish the App Store Connect record (see SETUP.md) to enable."
        }
    }
}
