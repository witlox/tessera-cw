#if canImport(GameKit)
import Foundation
import GameKit

/// GameKit-backed `MatchService`. Authenticates the local player, finds a
/// turn-based match programmatically (no UI dependency from inside the
/// library), and bridges `GKLocalPlayerListener` callbacks to an `AsyncStream`
/// of `MatchEvent` for the view layer.
public final class GameKitMatchService: NSObject, MatchService, GKLocalPlayerListener {
    public var isAuthenticated: Bool { GKLocalPlayer.local.isAuthenticated }

    private var continuation: AsyncStream<MatchEvent>.Continuation?
    public let inbound: AsyncStream<MatchEvent>

    /// Caller-supplied turn timeout in seconds; the 60s shot clock is enforced
    /// at the UI layer too, but we also tell GameKit so a stalled opponent
    /// can be skipped server-side after a generous grace period.
    public let turnTimeout: TimeInterval

    /// Set after `authenticate()` resolves. Errors carried so the UI can
    /// distinguish "not signed in" from "Game Center not configured".
    public private(set) var lastAuthError: Error?

    public init(turnTimeout: TimeInterval = 60 * 60 * 24) {  // 24h server-side
        self.turnTimeout = turnTimeout
        var cont: AsyncStream<MatchEvent>.Continuation!
        self.inbound = AsyncStream { cont = $0 }
        super.init()
        self.continuation = cont
    }

    // MARK: - Authentication

    public func authenticate() async throws {
        if GKLocalPlayer.local.isAuthenticated {
            GKLocalPlayer.local.register(self)
            return
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            GKLocalPlayer.local.authenticateHandler = { [weak self] _, error in
                if let error {
                    self?.lastAuthError = error
                    cont.resume(throwing: error); return
                }
                if GKLocalPlayer.local.isAuthenticated {
                    GKLocalPlayer.local.register(self!)
                    cont.resume()
                }
                // If !isAuthenticated && error == nil, GameKit is presenting UI;
                // wait for the next callback. Don't resume yet.
            }
        }
    }

    // MARK: - Matchmaking (programmatic, UI-less)

    public func findMatch(languages: [Lang], difficulty: Generator.Difficulty,
                          themeSlug: String?) async throws -> (MatchHandle, MatchPayload) {
        guard isAuthenticated else { throw MatchError.notAuthenticated }
        let request = GKMatchRequest()
        request.minPlayers = 2; request.maxPlayers = 2
        request.defaultNumberOfPlayers = 2

        let gkMatch: GKTurnBasedMatch = try await withCheckedThrowingContinuation { cont in
            GKTurnBasedMatch.find(for: request) { match, error in
                if let error { cont.resume(throwing: error); return }
                guard let match else { cont.resume(throwing: MatchError.noMatch); return }
                cont.resume(returning: match)
            }
        }

        // First turn: seed matchData. Subsequent rejoins: load what's there.
        if (gkMatch.matchData?.isEmpty ?? true) {
            let seed = UInt64.random(in: 1...UInt64.max)
            let config = MatchConfig(seed: seed, languages: languages,
                                     difficulty: difficulty, themeSlug: themeSlug)
            let players = gkMatch.participants.compactMap { $0.player?.gamePlayerID }
            let payload = MatchPayload(config: config, players: players, createdAt: Date())
            let data = try MoveCodec.encode(payload)
            try await save(matchData: data, in: gkMatch, endTurn: false)
            return (MatchHandle(id: gkMatch.matchID, config: config), payload)
        } else {
            let payload = try MoveCodec.decode(gkMatch.matchData ?? Data())
            return (MatchHandle(id: gkMatch.matchID, config: payload.config), payload)
        }
    }

    public func payload(for handle: MatchHandle) async throws -> MatchPayload {
        let match = try await load(matchID: handle.id)
        return try MoveCodec.decode(match.matchData ?? Data())
    }

    // MARK: - Submit / pass

    public func submit(_ move: Move, in handle: MatchHandle) async throws {
        let match = try await load(matchID: handle.id)
        var payload = try MoveCodec.decode(match.matchData ?? Data())
        let appended = MatchPayload(
            config: payload.config,
            moves: payload.moves + [move],
            passReveals: payload.passReveals,
            players: payload.players,
            createdAt: payload.createdAt
        )
        payload = appended
        let data = try MoveCodec.encode(payload)
        try await save(matchData: data, in: match, endTurn: true)
    }

    public func pass(revealing cell: CoordWire, in handle: MatchHandle) async throws {
        let match = try await load(matchID: handle.id)
        let payload = try MoveCodec.decode(match.matchData ?? Data())
        let me = GKLocalPlayer.local.gamePlayerID
        let reveal = MatchPayload.PassReveal(by: me, revealed: cell, at: Date())
        let appended = MatchPayload(
            config: payload.config,
            moves: payload.moves,
            passReveals: payload.passReveals + [reveal],
            players: payload.players,
            createdAt: payload.createdAt
        )
        let data = try MoveCodec.encode(appended)
        try await save(matchData: data, in: match, endTurn: true)
    }

    // MARK: - GKLocalPlayerListener

    public func player(_ player: GKPlayer, receivedTurnEventFor match: GKTurnBasedMatch,
                       didBecomeActive: Bool) {
        guard let data = match.matchData, !data.isEmpty,
              let payload = try? MoveCodec.decode(data) else { return }
        // Last appended move OR pass is what the opponent just did.
        if let lastMove = payload.moves.last {
            continuation?.yield(.opponentMove(lastMove))
        } else if let lastPass = payload.passReveals.last {
            continuation?.yield(.opponentPassed(revealedCell: lastPass.revealed))
        }
        if match.status == .ended {
            let winner = match.participants.first { $0.matchOutcome == .won }?
                .player?.gamePlayerID
            continuation?.yield(.matchEnded(winner: winner))
        }
    }

    public func player(_ player: GKPlayer, matchEnded match: GKTurnBasedMatch) {
        let winner = match.participants.first { $0.matchOutcome == .won }?
            .player?.gamePlayerID
        continuation?.yield(.matchEnded(winner: winner))
    }

    // MARK: - Match lookup helpers

    private func load(matchID: String) async throws -> GKTurnBasedMatch {
        try await withCheckedThrowingContinuation { cont in
            GKTurnBasedMatch.load(withID: matchID) { match, error in
                if let error { cont.resume(throwing: error); return }
                guard let match else { cont.resume(throwing: MatchError.noMatch); return }
                cont.resume(returning: match)
            }
        }
    }

    private func save(matchData data: Data, in match: GKTurnBasedMatch,
                      endTurn: Bool) async throws {
        if endTurn {
            let nextParticipants = match.participants.filter {
                $0.player?.gamePlayerID != GKLocalPlayer.local.gamePlayerID
            }
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                match.endTurn(withNextParticipants: nextParticipants,
                              turnTimeout: turnTimeout, match: data) { error in
                    if let error { c.resume(throwing: error) } else { c.resume() }
                }
            }
        } else {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                match.saveCurrentTurn(withMatch: data) { error in
                    if let error { c.resume(throwing: error) } else { c.resume() }
                }
            }
        }
    }

    public enum MatchError: LocalizedError {
        case notAuthenticated
        case noMatch
        public var errorDescription: String? {
            switch self {
            case .notAuthenticated:
                return "Sign in to Game Center to play multiplayer."
            case .noMatch:
                return "Couldn’t find or load a match. Try again."
            }
        }
    }
}
#endif
