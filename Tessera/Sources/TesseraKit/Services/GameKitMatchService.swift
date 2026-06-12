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

    private var newMatchesContinuation: AsyncStream<String>.Continuation?
    public let newMatches: AsyncStream<String>

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
        var nm: AsyncStream<String>.Continuation!
        self.newMatches = AsyncStream { nm = $0 }
        super.init()
        self.continuation = cont
        self.newMatchesContinuation = nm
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

    // MARK: - Attach (matchmaker UI feeds match IDs to AppModel via newMatches)

    public func attach(matchID: String,
                       seedingIfEmpty: MatchConfig?) async throws -> (MatchHandle, MatchPayload) {
        guard isAuthenticated else { throw MatchError.notAuthenticated }
        let gkMatch = try await load(matchID: matchID)
        if let data = gkMatch.matchData, !data.isEmpty {
            // Resumed match (or the opponent has already seeded it).
            let payload = try MoveCodec.decode(data)
            return (MatchHandle(id: gkMatch.matchID, config: payload.config), payload)
        }
        // Fresh match — we're the player who initiated it.
        guard let config = seedingIfEmpty else { throw MatchError.notSeeded }
        let players = gkMatch.participants.compactMap { $0.player?.gamePlayerID }
        // Player A (the seeder) takes the first turn; GameKit's matchmaker
        // hands control to us right after creation.
        let payload = MatchPayload(config: config, players: players,
                                   createdAt: Date(),
                                   currentPlayer: GKLocalPlayer.local.gamePlayerID)
        let encoded = try MoveCodec.encode(payload)
        try await save(matchData: encoded, in: gkMatch, endTurn: false)
        return (MatchHandle(id: gkMatch.matchID, config: config), payload)
    }

    public func payload(for handle: MatchHandle) async throws -> MatchPayload {
        let match = try await load(matchID: handle.id)
        return try MoveCodec.decode(match.matchData ?? Data())
    }

    // MARK: - Submit / pass

    public func submit(_ move: Move, in handle: MatchHandle) async throws {
        let match = try await load(matchID: handle.id)
        let payload = try MoveCodec.decode(match.matchData ?? Data())
        let updated = payload.with(moves: payload.moves + [move])
        let data = try MoveCodec.encode(updated)
        // Letters within a turn do NOT advance the turn — only an explicit
        // pass (or shot-clock-driven pass) ends it. saveCurrentTurn persists
        // the move log without notifying the opponent.
        try await save(matchData: data, in: match, endTurn: false)
    }

    public func submitClosing(_ move: Move, in handle: MatchHandle) async throws {
        let match = try await load(matchID: handle.id)
        let payload = try MoveCodec.decode(match.matchData ?? Data())
        let me = GKLocalPlayer.local.gamePlayerID
        let next = payload.other(than: me) ?? me
        let updated = payload.with(moves: payload.moves + [move],
                                   currentPlayer: next)
        let data = try MoveCodec.encode(updated)
        try await save(matchData: data, in: match, endTurn: true)
    }

    public func signalDone(in handle: MatchHandle, finalWinner: String?) async throws {
        let match = try await load(matchID: handle.id)
        let payload = try MoveCodec.decode(match.matchData ?? Data())
        let me = GKLocalPlayer.local.gamePlayerID
        let updated = payload.with(doneSignals: payload.doneSignals + [me],
                                   currentPlayer: payload.other(than: me) ?? me)
        let data = try MoveCodec.encode(updated)
        if let winner = finalWinner {
            for participant in match.participants {
                guard let pid = participant.player?.gamePlayerID else { continue }
                participant.matchOutcome = (pid == winner) ? .won : .lost
            }
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                match.endMatchInTurn(withMatch: data) { error in
                    if let error { c.resume(throwing: error) } else { c.resume() }
                }
            }
        } else {
            try await save(matchData: data, in: match, endTurn: true)
        }
    }

    public func endMatch(handle: MatchHandle, winnerPlayerID: String) async throws {
        let match = try await load(matchID: handle.id)
        for participant in match.participants {
            guard let pid = participant.player?.gamePlayerID else { continue }
            participant.matchOutcome = (pid == winnerPlayerID) ? .won : .lost
        }
        let data = match.matchData ?? Data()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            match.endMatchInTurn(withMatch: data) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }

    public func reportLeaderboard(score: Int, to id: LeaderboardID) async throws {
        guard GKLocalPlayer.local.isAuthenticated else { return }
        try await GKLeaderboard.submitScore(score, context: 0,
                                            player: GKLocalPlayer.local,
                                            leaderboardIDs: [id.rawValue])
    }

    public func pass(revealing cell: CoordWire, in handle: MatchHandle) async throws {
        let match = try await load(matchID: handle.id)
        let payload = try MoveCodec.decode(match.matchData ?? Data())
        let me = GKLocalPlayer.local.gamePlayerID
        let reveal = MatchPayload.PassReveal(by: me, revealed: cell, at: Date())
        let next = payload.other(than: me) ?? me
        let updated = payload.with(passReveals: payload.passReveals + [reveal],
                                   currentPlayer: next)
        let data = try MoveCodec.encode(updated)
        try await save(matchData: data, in: match, endTurn: true)
    }

    // MARK: - GKLocalPlayerListener

    public func player(_ player: GKPlayer, receivedTurnEventFor match: GKTurnBasedMatch,
                       didBecomeActive: Bool) {
        // didBecomeActive=true means the user just opened (or was just sent
        // to) this match — either from the matchmaker picking/inviting, a
        // friend's invitation notification, or a launch from a deep link.
        // We surface it as a newMatches event so AppModel can attach.
        if didBecomeActive {
            newMatchesContinuation?.yield(match.matchID)
        }

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
        case notSeeded
        public var errorDescription: String? {
            switch self {
            case .notAuthenticated:
                return "Sign in to Game Center to play multiplayer."
            case .noMatch:
                return "Couldn’t find or load a match. Try again."
            case .notSeeded:
                return "The match hasn’t been set up yet. Wait a moment and reopen it."
            }
        }
    }
}
#endif
