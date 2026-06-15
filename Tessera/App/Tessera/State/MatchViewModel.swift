import Foundation
import Observation
import TesseraKit

/// Active multiplayer match view-model. The puzzle is reproduced locally
/// from `config.seed` so the wire only carries moves.
@Observable
@MainActor
final class MatchViewModel {
    let handle: MatchHandle
    let puzzle: Puzzle
    let me: String
    var payload: MatchPayload
    var state: GameState
    /// Set when GameKit fires `.matchEnded` (opponent quit, timeout, etc.).
    /// The view shows a completion alert and routes back to Home.
    var didEnd: Bool = false
    /// True on the local client whose move completed the puzzle, OR when the
    /// both-done tiebreak put us on top. Drives the multiplayer-wins
    /// leaderboard increment.
    var didWin: Bool = false
    /// Toggle that flashes wrong cells red. Mirrors solo's `showErrors`;
    /// off by default. The puzzle solution is local on both clients anyway,
    /// so this is a self-help hint, not asymmetric information.
    var showErrors: Bool = false

    private let service: MatchService

    init(service: MatchService, handle: MatchHandle, puzzle: Puzzle,
         me: String, payload: MatchPayload) {
        self.service = service
        self.handle = handle
        self.puzzle = puzzle
        self.me = me
        self.payload = payload
        self.state = payload.gameState(for: puzzle)
    }

    var isMyTurn: Bool { payload.currentTurnPlayer == me }

    /// Whether the local player has already permanently signalled "I'm done".
    var iSignalledDone: Bool { payload.doneSignals.contains(me) }

    /// Whether the opponent has already signalled done.
    var opponentSignalledDone: Bool {
        guard let other = payload.other(than: me) else { return false }
        return payload.doneSignals.contains(other)
    }

    /// Returns the placed entry the cursor is on (across preferred).
    func currentClue(for selection: GameState.Selection) -> PlacedEntry? {
        puzzle.placed.first { p in
            p.orientation == selection.orientation && p.cells.contains(selection.origin)
        }
    }

    func submitLetter(_ letter: Character, at coord: Coord, deadline: Date) async throws {
        let move = Move(by: me, cell: CoordWire(coord), letter: letter,
                        atTurnDeadline: deadline)
        var after = state
        after.place(letter, at: coord, in: puzzle)

        // Whole puzzle complete? Local optimistic apply, submit, then end.
        // (No more auto-pass-on-word-complete — the player commits via the
        // explicit Check button or hands off via Pass.)
        if after.isComplete(puzzle), !me.isEmpty {
            try await service.submit(move, fills: fillsSnapshot(after.fills), in: handle)
            state = after
            didWin = true
            try? await service.endMatch(handle: handle, winnerPlayerID: me)
            return
        }

        // Ordinary letter — saveCurrentTurn, keep playing.
        try await service.submit(move, fills: fillsSnapshot(after.fills), in: handle)
        state = after
    }

    /// Verify the entry that contains `coord` (and matches `orientation`).
    /// All cells correct → lock the whole entry. Any wrong letter →
    /// clear the wrong cells (correct ones stay). Either outcome ends
    /// the turn.
    ///
    /// Returns `true` when the check passed (the player's words were all
    /// right), `false` when at least one cell was wrong / empty. The view
    /// layer can surface a flash or haptic off the return value.
    @discardableResult
    func checkEntry(_ entry: PlacedEntry) async throws -> Bool {
        var after = state
        let truth = puzzle.solution
        // Cells in the entry that aren't already locked, revealed by us,
        // or revealed by the opponent — those are the ones we judge.
        let editable = entry.cells.filter { c in
            !after.locked.contains(c)
                && !after.revealed.contains(c)
                && !after.revealedByOpponent.contains(c)
        }
        // Wrong = currently filled with a non-matching letter, or empty.
        // Either way, an "all correct" entry must have NO wrong cells.
        let wrong = editable.filter { c in
            guard let filled = after.fills[c] else { return true }
            return truth[c] != filled
        }
        if wrong.isEmpty {
            // PASS — lock the whole entry. Cells already locked stay
            // locked; new locks are the rest of the entry's cells.
            let newLocks = entry.cells.filter { !after.locked.contains($0) }
            for c in newLocks { after.locked.insert(c) }
            try await service.check(
                locks: newLocks.map(CoordWire.init),
                clears: [],
                fills: fillsSnapshot(after.fills),
                in: handle)
            state = after
            await refreshPayloadAfterTurnEnd()
            return true
        } else {
            // FAIL — clear only the wrong cells; correct user placements stay.
            for c in wrong { after.fills.removeValue(forKey: c) }
            try await service.check(
                locks: [],
                clears: wrong.map(CoordWire.init),
                fills: fillsSnapshot(after.fills),
                in: handle)
            state = after
            await refreshPayloadAfterTurnEnd()
            return false
        }
    }

    /// Encode the in-memory `fills` map as the wire snapshot.
    private func fillsSnapshot(_ map: [Coord: Character]) -> [String: String] {
        var out: [String: String] = [:]
        for (coord, ch) in map { out[coord.wireKey] = String(ch) }
        return out
    }

    /// "I'm done" — irrevocable. If we're the second to signal, compute the
    /// winner by correct-letter count (tiebreak: first-done wins) and end
    /// the match in the same network call. Otherwise just hand the turn
    /// over; opponent plays freely until they also signal done.
    func signalDone() async throws {
        let snapshot = fillsSnapshot(state.fills)
        if opponentSignalledDone {
            let myCount = payload.correctLetterCount(playerID: me, puzzle: puzzle)
            let opp = payload.other(than: me) ?? ""
            let oppCount = payload.correctLetterCount(playerID: opp, puzzle: puzzle)
            let winner: String
            if myCount > oppCount { winner = me }
            else if oppCount > myCount { winner = opp }
            else {
                // Tie: whoever signalled done first. opp is the first since
                // we're about to be the second.
                winner = opp
            }
            didWin = (winner == me)
            try await service.signalDone(fills: snapshot, in: handle, finalWinner: winner)
            // Match ended — the inbound `.matchEnded` event flips `didEnd`
            // and the view routes home; no payload refresh needed.
        } else {
            try await service.signalDone(fills: snapshot, in: handle, finalWinner: nil)
            await refreshPayloadAfterTurnEnd()
        }
    }

    /// Pick a deterministic untouched cell and pass. Seed is the match seed
    /// combined with the current pass index so successive passes reveal
    /// different cells; both clients compute the same coord from the same
    /// inputs and agree on the reveal.
    func pass() async throws {
        var rng = SeededRNG(handle.config.seed &+ UInt64(payload.passReveals.count) &+ 17)
        guard let coord = state.pickUntouchedCell(puzzle, rng: &rng) else {
            // Nothing left to reveal — still hand turn over with our snapshot.
            try await service.pass(revealing: CoordWire(0, 0),
                                   fills: fillsSnapshot(state.fills),
                                   in: handle)
            await refreshPayloadAfterTurnEnd()
            return
        }
        var after = state
        after.revealedByOpponent.insert(coord)
        if let truth = puzzle.solution[coord] { after.fills[coord] = truth }
        try await service.pass(revealing: CoordWire(coord),
                               fills: fillsSnapshot(after.fills),
                               in: handle)
        state = after
        await refreshPayloadAfterTurnEnd()
    }

    /// Pull the canonical payload from the service so `isMyTurn` flips
    /// immediately after a turn-ending write. The service-side
    /// `payload(for:)` reconciles against GameKit's `currentParticipant`,
    /// folds in any newly-bound opponent ID, and corrects a stale
    /// `currentPlayer` baked in by a previous write made before the
    /// opponent's `GKPlayer` was resolved. Without this, our local payload
    /// still says it's our turn after our own endTurn and the UI lets the
    /// user tap into a `GKError 23 / GKServerStatusCode 5102` rejection.
    private func refreshPayloadAfterTurnEnd() async {
        if let fresh = try? await service.payload(for: handle) {
            self.payload = fresh
        }
    }

    /// Replay payload to refresh state after an inbound event.
    func refresh(payload: MatchPayload) {
        self.payload = payload
        self.state = payload.gameState(for: puzzle)
    }

    /// Subscribe to `service.inbound`. The listener-fed `.turnReceived`
    /// event carries the freshly-decoded payload from GameKit's
    /// authoritative `matchData`, so we apply it directly — avoiding a
    /// `GKTurnBasedMatch.load(withID:)` round trip that on TestFlight
    /// sometimes returned a stale snapshot and made the opponent's latest
    /// moves look like they never arrived. `.matchEnded` falls back to a
    /// reload (the listener doesn't provide a payload in the
    /// `matchEnded` path) and flips `didEnd` so the view routes home.
    func startListening() {
        Task { [service, handle, weak self] in
            for await event in service.inbound {
                guard let self else { break }
                switch event {
                case .turnReceived(let payload):
                    await MainActor.run { self.refresh(payload: payload) }
                case .matchEnded:
                    if let fresh = try? await service.payload(for: handle) {
                        await MainActor.run { self.refresh(payload: fresh) }
                    }
                    await MainActor.run { self.didEnd = true }
                }
            }
        }
    }
}
