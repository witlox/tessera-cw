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
            let raw = try MoveCodec.decode(data)
            let payload = reconcile(payload: raw, with: gkMatch)
            return (MatchHandle(id: gkMatch.matchID, config: payload.config), payload)
        }
        // Fresh match — we're the player who initiated it.
        guard let config = seedingIfEmpty else { throw MatchError.notSeeded }
        let me = GKLocalPlayer.local.gamePlayerID
        let players = mergeParticipants(into: [], from: gkMatch.participants, me: me)
        // Player A (the seeder) takes the first turn; GameKit's matchmaker
        // hands control to us right after creation.
        let payload = MatchPayload(config: config, players: players,
                                   createdAt: Date(),
                                   currentPlayer: me)
        let encoded = try MoveCodec.encode(payload)
        try await save(matchData: encoded, in: gkMatch, endTurn: false)
        return (MatchHandle(id: gkMatch.matchID, config: config), payload)
    }

    public func payload(for handle: MatchHandle) async throws -> MatchPayload {
        let match = try await load(matchID: handle.id)
        let raw = try MoveCodec.decode(match.matchData ?? Data())
        return reconcile(payload: raw, with: match)
    }

    // MARK: - Submit / pass

    public func submit(_ move: Move, in handle: MatchHandle) async throws {
        let match = try await load(matchID: handle.id)
        let payload = try MoveCodec.decode(match.matchData ?? Data())
        let me = GKLocalPlayer.local.gamePlayerID
        let refreshed = mergeParticipants(into: payload.players, from: match.participants, me: me)
        let updated = payload.with(moves: payload.moves + [move],
                                   players: refreshed)
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
        let refreshed = mergeParticipants(into: payload.players, from: match.participants, me: me)
        guard let next = opponentID(in: match, players: refreshed, me: me) else {
            throw MatchError.opponentNotReady
        }
        let updated = payload.with(moves: payload.moves + [move],
                                   players: refreshed,
                                   currentPlayer: next)
        let data = try MoveCodec.encode(updated)
        try await save(matchData: data, in: match, endTurn: true)
    }

    public func signalDone(in handle: MatchHandle, finalWinner: String?) async throws {
        let match = try await load(matchID: handle.id)
        let payload = try MoveCodec.decode(match.matchData ?? Data())
        let me = GKLocalPlayer.local.gamePlayerID
        let refreshed = mergeParticipants(into: payload.players, from: match.participants, me: me)
        guard let next = opponentID(in: match, players: refreshed, me: me) else {
            throw MatchError.opponentNotReady
        }
        let updated = payload.with(doneSignals: payload.doneSignals + [me],
                                   players: refreshed,
                                   currentPlayer: next)
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
        let refreshed = mergeParticipants(into: payload.players, from: match.participants, me: me)
        guard let next = opponentID(in: match, players: refreshed, me: me) else {
            throw MatchError.opponentNotReady
        }
        let updated = payload.with(passReveals: payload.passReveals + [reveal],
                                   players: refreshed,
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

    // MARK: - Reconciliation helpers

    /// Re-derive `players` and `currentPlayer` against GameKit's authoritative
    /// state. The matchData we decoded may have been seeded before all
    /// `GKPlayer` bindings resolved — in that case `payload.players` is
    /// missing the opponent's ID and `payload.currentPlayer` is whatever
    /// stale value the last writer (often *us*) committed. GameKit's own
    /// `currentParticipant` is the only source of truth for whose turn it is.
    private func reconcile(payload: MatchPayload, with match: GKTurnBasedMatch) -> MatchPayload {
        let me = GKLocalPlayer.local.gamePlayerID
        let refreshed = mergeParticipants(into: payload.players,
                                          from: match.participants, me: me)
        let serverCurrent = match.currentParticipant?.player?.gamePlayerID
        let needsPlayers = refreshed != payload.players
        let needsCurrent = serverCurrent != nil
            && !serverCurrent!.isEmpty
            && payload.currentPlayer != serverCurrent!
        guard needsPlayers || needsCurrent else { return payload }
        return payload.with(players: refreshed,
                            currentPlayer: serverCurrent ?? payload.currentPlayer)
    }

    /// Fold every observed participant `gamePlayerID` into `baseline`,
    /// preserving order and de-duplicating. `me` is always included so the
    /// payload stays self-describing even when no opponent has been bound.
    private func mergeParticipants(into baseline: [String],
                                    from participants: [GKTurnBasedParticipant],
                                    me: String) -> [String] {
        var merged = baseline
        if !me.isEmpty, !merged.contains(me) { merged.append(me) }
        for p in participants {
            if let id = p.player?.gamePlayerID, !id.isEmpty, !merged.contains(id) {
                merged.append(id)
            }
        }
        return merged
    }

    /// Best-effort opponent `gamePlayerID`. Tries the merged `players` list
    /// first; if that's still us-only (opponent's GKPlayer unresolved at the
    /// time matchData was written), falls back to the non-current participant
    /// in `match.participants`. Returns nil only when the opponent's
    /// participant slot has no `player` binding at all — callers should
    /// surface this as `opponentNotReady` rather than write a payload that
    /// lies about whose turn it is.
    private func opponentID(in match: GKTurnBasedMatch,
                            players: [String], me: String) -> String? {
        if let other = players.first(where: { $0 != me && !$0.isEmpty }) { return other }
        return match.participants
            .first { $0 !== match.currentParticipant }?
            .player?.gamePlayerID
    }

    private func save(matchData data: Data, in match: GKTurnBasedMatch,
                      endTurn: Bool) async throws {
        // GameKit rejects both saveCurrentTurn and endTurn with GKError 23 /
        // GKServerStatusCode 5102 ("Not your turn") when the caller isn't the
        // current participant server-side. Catch the desync locally so the
        // view layer can refresh state and re-render isMyTurn correctly
        // instead of showing the user a raw GKErrorDomain message.
        let me = GKLocalPlayer.local.gamePlayerID
        if let current = match.currentParticipant?.player?.gamePlayerID,
           current != me {
            throw MatchError.notMyTurn
        }
        if endTurn {
            // Filter by object identity against `currentParticipant`, NOT by
            // `player?.gamePlayerID`. Right after an invitee accepts, GameKit
            // can take a moment to bind the `GKPlayer` to that participant —
            // during the window `participant.player` is nil, so the
            // gamePlayerID filter (`nil != us`) would keep the unbound slot
            // and the server rejects the endTurn with GKError 23 /
            // GKServerStatusCode 5102 ("invalid participant / turn state").
            // Identity-against-currentParticipant works regardless of player
            // resolution; see Apple's Turn-Based Matches guide.
            let nextParticipants = match.participants.filter {
                $0 !== match.currentParticipant
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
        case notMyTurn
        case opponentNotReady
        public var errorDescription: String? {
            switch self {
            case .notAuthenticated:
                return "Sign in to Game Center to play multiplayer."
            case .noMatch:
                return "Couldn’t find or load a match. Try again."
            case .notSeeded:
                return "The match hasn’t been set up yet. Wait a moment and reopen it."
            case .notMyTurn:
                return "It’s not your turn anymore — refreshing…"
            case .opponentNotReady:
                return "Waiting for the other player to join. Try again in a moment."
            }
        }
    }
}
#endif
