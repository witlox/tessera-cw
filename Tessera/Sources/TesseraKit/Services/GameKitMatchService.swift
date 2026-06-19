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

    /// Guards `register(self)` and continuation resume so each happens at
    /// most once over the app lifetime. GameKit re-invokes
    /// `authenticateHandler` on UI present, sign-in success, sign-in/out
    /// transitions, and again whenever downstream surfaces
    /// (`GKGameCenterViewController` for leaderboards, the matchmaker, etc.)
    /// make Game Center re-verify the player.
    private let authStateLock = NSLock()
    private var isListenerRegistered = false

    public func authenticate() async throws {
        if GKLocalPlayer.local.isAuthenticated {
            registerListenerOnce()
            return
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // GameKit fires this handler MORE THAN ONCE across the app's
            // lifetime — once to present its sign-in UI, once on success,
            // and again whenever something downstream (presenting
            // `GKGameCenterViewController` for leaderboards is the one
            // that surfaced this on TestFlight) makes Game Center
            // re-verify the player. `CheckedContinuation` traps a second
            // resume in `libswift_Concurrency` and aborts the process —
            // the reported crash was exactly that, in closure #1 of
            // `authenticate()` triggered by the leaderboards button.
            // `AuthToken` clamps to a single resume; subsequent
            // invocations just keep the local player state in sync.
            let token = AuthToken(continuation: cont)
            GKLocalPlayer.local.authenticateHandler = { [weak self] _, error in
                guard let self else { return }
                if let error {
                    self.lastAuthError = error
                    token.resumeOnce { $0.resume(throwing: error) }
                    return
                }
                if GKLocalPlayer.local.isAuthenticated {
                    self.registerListenerOnce()
                    token.resumeOnce { $0.resume() }
                }
                // !isAuthenticated && error == nil → GameKit is
                // presenting its sign-in UI; wait for the next callback.
            }
        }
    }

    private func registerListenerOnce() {
        authStateLock.lock()
        let already = isListenerRegistered
        isListenerRegistered = true
        authStateLock.unlock()
        if !already { GKLocalPlayer.local.register(self) }
    }

    /// Wraps a `CheckedContinuation` so resuming is idempotent. GameKit
    /// can call our `authenticateHandler` again after we've already
    /// completed the awaiting Task — without this, the second resume
    /// crashes the process via `CheckedContinuation`'s sanity trap.
    private final class AuthToken: @unchecked Sendable {
        private var cont: CheckedContinuation<Void, Error>?
        private let lock = NSLock()
        init(continuation: CheckedContinuation<Void, Error>) {
            self.cont = continuation
        }
        func resumeOnce(_ op: (CheckedContinuation<Void, Error>) -> Void) {
            lock.lock()
            let captured = cont
            cont = nil
            lock.unlock()
            if let captured { op(captured) }
        }
    }

    // MARK: - Attach (matchmaker UI feeds match IDs to AppModel via newMatches)

    public func attach(matchID: String,
                       seedingIfEmpty: MatchConfig?) async throws -> (MatchHandle, MatchPayload) {
        guard isAuthenticated else { throw MatchError.notAuthenticated }
        let gkMatch = try await load(matchID: matchID)
        let me = GKLocalPlayer.local.gamePlayerID
        let opponentName = opponentDisplayName(in: gkMatch, me: me)
        if let data = gkMatch.matchData, !data.isEmpty {
            // Resumed match (or the opponent has already seeded it).
            let raw = try MoveCodec.decode(data)
            let payload = reconcile(payload: raw, with: gkMatch)
            return (MatchHandle(id: gkMatch.matchID, config: payload.config,
                                opponentDisplayName: opponentName), payload)
        }
        // Fresh match — we're the player who initiated it.
        guard let config = seedingIfEmpty else { throw MatchError.notSeeded }
        let players = mergeParticipants(into: [], from: gkMatch.participants, me: me)
        // Player A (the seeder) takes the first turn; GameKit's matchmaker
        // hands control to us right after creation.
        let payload = MatchPayload(config: config, players: players,
                                   createdAt: Date(),
                                   currentPlayer: me)
        let encoded = try MoveCodec.encode(payload)
        try await save(matchData: encoded, in: gkMatch, endTurn: false)
        return (MatchHandle(id: gkMatch.matchID, config: config,
                            opponentDisplayName: opponentName), payload)
    }

    public func payload(for handle: MatchHandle) async throws -> MatchPayload {
        let match = try await load(matchID: handle.id)
        let raw = try MoveCodec.decode(match.matchData ?? Data())
        return reconcile(payload: raw, with: match)
    }

    public func loadActiveMatchIDs() async throws -> [String] {
        guard isAuthenticated else { return [] }
        let matches = try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<[GKTurnBasedMatch], Error>) in
            GKTurnBasedMatch.loadMatches { matches, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: matches ?? [])
            }
        }
        // Filter to non-ended matches we haven't already quit/lost/won.
        // `participantQuitInTurn` marks OUR `matchOutcome = .quit` but
        // keeps the match `.open` so the opponent can finish, so naively
        // filtering by status alone makes quit matches reappear on
        // Home every launch. We additionally require our own
        // participant's `matchOutcome == .none` — i.e. we're still
        // actively part of this match. Sorted most-recently-active first
        // so the home screen surfaces what the user is most likely to
        // care about resuming.
        let me = GKLocalPlayer.local.gamePlayerID
        let active = matches.filter { m in
            guard m.status == .open || m.status == .matching else { return false }
            // If our slot hasn't been bound to `GKPlayer` yet (matchmaker
            // race), keep the match — `attach` will reconcile shortly.
            // If it's bound and the outcome is set (`.quit`, `.lost`,
            // etc.), the match is over for us even if the server still
            // shows it as `.open` so the opponent can finish.
            guard let mine = m.participants.first(where: {
                $0.player?.gamePlayerID == me
            }) else { return true }
            return mine.matchOutcome == .none
        }
        // `GKTurnBasedMatch` has no `lastTurnDate` directly — the most
        // recent activity is the latest `lastTurnDate` across its
        // participants, falling back to creationDate for brand-new
        // matches no participant has touched yet.
        func lastActivity(_ m: GKTurnBasedMatch) -> Date {
            let latest = m.participants
                .compactMap { $0.lastTurnDate }
                .max()
            return latest ?? m.creationDate
        }
        let sorted = active.sorted(by: { (a: GKTurnBasedMatch, b: GKTurnBasedMatch) -> Bool in
            lastActivity(a) > lastActivity(b)
        })
        return sorted.map { $0.matchID }
    }

    // MARK: - Submit / check / pass

    public func submit(_ move: Move, fills: [String: String],
                       in handle: MatchHandle) async throws {
        let match = try await load(matchID: handle.id)
        let payload = try MoveCodec.decode(match.matchData ?? Data())
        let me = GKLocalPlayer.local.gamePlayerID
        let refreshed = mergeParticipants(into: payload.players, from: match.participants, me: me)
        let updated = payload.with(moves: payload.moves + [move],
                                   players: refreshed,
                                   fills: fills)
        let data = try MoveCodec.encode(updated)
        // Letters within a turn do NOT advance the turn — only an explicit
        // Check, Pass, or signalDone does. saveCurrentTurn persists the
        // snapshot without notifying the opponent.
        try await save(matchData: data, in: match, endTurn: false)
    }

    public func check(locks: [CoordWire], clears: [CoordWire],
                      fills: [String: String], in handle: MatchHandle) async throws {
        let match = try await load(matchID: handle.id)
        let payload = try MoveCodec.decode(match.matchData ?? Data())
        let me = GKLocalPlayer.local.gamePlayerID
        let refreshed = mergeParticipants(into: payload.players, from: match.participants, me: me)
        guard let next = opponentID(in: match, players: refreshed, me: me) else {
            throw MatchError.opponentNotReady
        }
        // Fold any newly-locked cells into the cumulative lockedCells set.
        // Clears are reflected via the caller-supplied fills snapshot —
        // we don't track them separately.
        var lockedSet: [CoordWire] = payload.lockedCells
        for wire in locks where !lockedSet.contains(wire) {
            lockedSet.append(wire)
        }
        _ = clears  // reflected in fills; kept in the protocol for symmetry / future use
        let updated = payload.with(players: refreshed,
                                   currentPlayer: next,
                                   fills: fills,
                                   lockedCells: lockedSet)
        let data = try MoveCodec.encode(updated)
        try await save(matchData: data, in: match, endTurn: true)
    }

    public func signalDone(fills: [String: String], in handle: MatchHandle,
                           finalWinner: String?) async throws {
        let match = try await load(matchID: handle.id)
        let payload = try MoveCodec.decode(match.matchData ?? Data())
        let me = GKLocalPlayer.local.gamePlayerID
        let refreshed = mergeParticipants(into: payload.players, from: match.participants, me: me)
        guard let next = opponentID(in: match, players: refreshed, me: me) else {
            throw MatchError.opponentNotReady
        }
        let updated = payload.with(doneSignals: payload.doneSignals + [me],
                                   players: refreshed,
                                   currentPlayer: next,
                                   fills: fills)
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

    /// Atomic terminating write — folds the winning move (if any) and any
    /// new locks into the freshly-loaded payload, sets participant
    /// outcomes, and ends the match in a SINGLE `endMatchInTurn` call.
    /// Replaces the previous save-current-turn-then-end-match pair, which
    /// could race against the server and produce GKError 5003 /
    /// `current-turn-number value: -1` when the second write hit before
    /// the first had propagated.
    public func endMatch(move: Move?, locks: [CoordWire],
                         fills: [String: String], winnerPlayerID: String,
                         in handle: MatchHandle) async throws {
        let match = try await load(matchID: handle.id)
        if match.status == .ended { return }
        let payload = try MoveCodec.decode(match.matchData ?? Data())
        let me = GKLocalPlayer.local.gamePlayerID
        let refreshed = mergeParticipants(into: payload.players,
                                          from: match.participants, me: me)
        var lockedSet: [CoordWire] = payload.lockedCells
        for wire in locks where !lockedSet.contains(wire) {
            lockedSet.append(wire)
        }
        let appended = move.map { payload.moves + [$0] } ?? payload.moves
        let updated = payload.with(moves: appended,
                                   players: refreshed,
                                   fills: fills,
                                   lockedCells: lockedSet)
        let data = try MoveCodec.encode(updated)
        for participant in match.participants {
            guard let pid = participant.player?.gamePlayerID else { continue }
            participant.matchOutcome = (pid == winnerPlayerID) ? .won : .lost
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            match.endMatchInTurn(withMatch: data) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }

    public func quit(handle: MatchHandle) async throws {
        let match = try await load(matchID: handle.id)
        if match.status == .ended { return }
        let me = GKLocalPlayer.local.gamePlayerID
        // GameKit splits "quit" by turn ownership: out-of-turn just marks
        // our outcome and lets the opponent keep playing; in-turn requires
        // we name the next participant so the match can advance.
        let myTurn = match.currentParticipant?.player?.gamePlayerID == me
        if myTurn {
            // Same `.active`-only filter as `save(endTurn:)` — handing
            // off to an Inactive slot would be rejected with GKError
            // 22 / GKServerStatusCode=5097. When there's no active
            // opponent we end the match outright instead.
            let nextParticipants = match.participants.filter {
                $0 !== match.currentParticipant && $0.status == .active
            }
            let data = match.matchData ?? Data()
            if nextParticipants.isEmpty {
                for p in match.participants {
                    if p.player?.gamePlayerID == me {
                        p.matchOutcome = .quit
                    } else if p.matchOutcome == .none {
                        p.matchOutcome = .quit
                    }
                }
                try await withCheckedThrowingContinuation {
                    (c: CheckedContinuation<Void, Error>) in
                    match.endMatchInTurn(withMatch: data) { error in
                        if let error { c.resume(throwing: error) } else { c.resume() }
                    }
                }
                return
            }
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                match.participantQuitInTurn(with: .quit,
                                            nextParticipants: nextParticipants,
                                            turnTimeout: turnTimeout,
                                            match: data) { error in
                    if let error { c.resume(throwing: error) } else { c.resume() }
                }
            }
        } else {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                match.participantQuitOutOfTurn(with: .quit) { error in
                    if let error { c.resume(throwing: error) } else { c.resume() }
                }
            }
        }
    }

    public func reportLeaderboard(score: Int, to id: LeaderboardID) async throws {
        guard GKLocalPlayer.local.isAuthenticated else { return }
        try await GKLeaderboard.submitScore(score, context: 0,
                                            player: GKLocalPlayer.local,
                                            leaderboardIDs: [id.rawValue])
    }

    public func pass(revealing cell: CoordWire, fills: [String: String],
                     in handle: MatchHandle) async throws {
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
                                   currentPlayer: next,
                                   fills: fills)
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

        // Decode the AUTHORITATIVE matchData GameKit just handed us and
        // reconcile against the live participant list. Yield this directly
        // as `.turnReceived(payload)` — the view-model can apply it without
        // a second `GKTurnBasedMatch.load(withID:)` round trip, which on
        // TestFlight occasionally returned a stale snapshot after a few
        // turns and made the opponent's latest moves look like they had
        // never arrived.
        if let data = match.matchData, !data.isEmpty,
           let raw = try? MoveCodec.decode(data) {
            let reconciled = reconcile(payload: raw, with: match)
            continuation?.yield(.turnReceived(matchID: match.matchID,
                                              reconciled))
        }
        if match.status == .ended {
            let winner = match.participants.first { $0.matchOutcome == .won }?
                .player?.gamePlayerID
            continuation?.yield(.matchEnded(matchID: match.matchID,
                                            winner: winner))
        }
    }

    public func player(_ player: GKPlayer, matchEnded match: GKTurnBasedMatch) {
        let winner = match.participants.first { $0.matchOutcome == .won }?
            .player?.gamePlayerID
        continuation?.yield(.matchEnded(matchID: match.matchID,
                                        winner: winner))
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

    /// Best-effort opponent display name from GameKit's participant list.
    /// Returns nil while no opponent has had their `GKPlayer` bound yet —
    /// the view layer should fall back to a generic "Opponent" label.
    private func opponentDisplayName(in match: GKTurnBasedMatch, me: String) -> String? {
        for p in match.participants {
            guard let player = p.player else { continue }
            if player.gamePlayerID == me { continue }
            let name = player.displayName
            if !name.isEmpty { return name }
        }
        return nil
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
        // If the match already ended remotely (opponent won, opponent
        // quit, or both players signalled done), every write below
        // would be rejected by the server with GKError 5003 /
        // `current-turn-number value: -1 violated constraint`. Catch
        // the dead match locally so the UI can surface a clean message
        // and route home, rather than showing a raw GKErrorDomain alert.
        if match.status == .ended {
            throw MatchError.matchAlreadyEnded
        }
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
            //
            // ALSO filter by `.active` status: an opponent who never
            // accepted (`.invited` / `.matching`), declined, or quit
            // leaves the slot Inactive server-side, and `endTurn`
            // rejects it with GKError 22 / GKServerStatusCode=5097
            // ("Invalid slot state expectedSlotState='Active'
            // foundSlotState='Inactive'"). When no active opponent
            // remains, end the match with us as winner so the match
            // stops haunting `loadActiveMatchIDs` and the UI can
            // surface a clean "the other player has left" message.
            let nextParticipants = match.participants.filter {
                $0 !== match.currentParticipant && $0.status == .active
            }
            if nextParticipants.isEmpty {
                for p in match.participants {
                    if p.player?.gamePlayerID == me {
                        p.matchOutcome = .won
                    } else if p.matchOutcome == .none {
                        p.matchOutcome = .quit
                    }
                }
                try? await withCheckedThrowingContinuation {
                    (c: CheckedContinuation<Void, Error>) in
                    match.endMatchInTurn(withMatch: data) { error in
                        if let error { c.resume(throwing: error) } else { c.resume() }
                    }
                }
                throw MatchError.opponentLeft
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
        case matchAlreadyEnded
        case opponentLeft
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
            case .matchAlreadyEnded:
                return "This match has already ended. Returning to home…"
            case .opponentLeft:
                return "The other player has left the match. Returning to home…"
            }
        }
    }
}
#endif
