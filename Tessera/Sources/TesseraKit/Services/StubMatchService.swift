import Foundation

/// `MatchService` stand-in used in unit tests, previews, and the
/// "Game Center unavailable" fallback path. Every networked operation throws
/// a descriptive error so the UI's empty state can quote it verbatim.
public final class StubMatchService: MatchService, @unchecked Sendable {
    public var isAuthenticated: Bool { false }
    public let inbound: AsyncStream<MatchEvent>
    private let continuation: AsyncStream<MatchEvent>.Continuation

    public init() {
        var cont: AsyncStream<MatchEvent>.Continuation!
        self.inbound = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    public func authenticate() async throws {
        throw Error.unavailable
    }
    public func findMatch(languages: [Lang], difficulty: Generator.Difficulty,
                          themeSlug: String?) async throws -> (MatchHandle, MatchPayload) {
        throw Error.unavailable
    }
    public func payload(for match: MatchHandle) async throws -> MatchPayload {
        throw Error.unavailable
    }
    public func submit(_ move: Move, in match: MatchHandle) async throws {
        throw Error.unavailable
    }
    public func pass(revealing cell: CoordWire, in match: MatchHandle) async throws {
        throw Error.unavailable
    }

    public enum Error: LocalizedError {
        case unavailable
        public var errorDescription: String? {
            "Multiplayer needs Game Center; this build can’t reach it. " +
            "Finish the App Store Connect record (see SETUP.md) to enable."
        }
    }
}
