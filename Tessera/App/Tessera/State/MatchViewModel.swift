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
        // Build a hypothetical post-placement state so we can decide whether
        // the letter completes the puzzle (→ win) or completes a single
        // entry correctly (→ auto-pass).
        var after = state
        after.place(letter, at: coord, in: puzzle)

        // 1) Whole puzzle complete? Local optimistic apply, submit, then end.
        if after.isComplete(puzzle), !me.isEmpty {
            try await service.submit(move, in: handle)
            state = after
            didWin = true
            try? await service.endMatch(handle: handle, winnerPlayerID: me)
            return
        }

        // 2) An entry just transitioned from "not complete" to "complete and
        // all correct" — auto-pass to the opponent.
        if entryJustCompletedCorrectly(before: state, after: after, at: coord) != nil {
            try await service.submitClosing(move, in: handle)
            state = after
            await refreshPayloadAfterTurnEnd()
            return
        }

        // 3) Ordinary letter — saveCurrentTurn, keep playing.
        try await service.submit(move, in: handle)
        state = after
    }

    private func entryJustCompletedCorrectly(before: GameState, after: GameState,
                                             at coord: Coord) -> PlacedEntry? {
        for entry in puzzle.placed where entry.cells.contains(coord) {
            let wasCompleteBefore = entry.cells.allSatisfy { c in
                puzzle.solution[c] == before.effectiveLetter(c, in: puzzle)
            }
            if wasCompleteBefore { continue }
            let isCompleteAfter = entry.cells.allSatisfy { c in
                puzzle.solution[c] == after.effectiveLetter(c, in: puzzle)
            }
            if isCompleteAfter { return entry }
        }
        return nil
    }

    /// "I'm done" — irrevocable. If we're the second to signal, compute the
    /// winner by correct-letter count (tiebreak: first-done wins) and end
    /// the match in the same network call. Otherwise just hand the turn
    /// over; opponent plays freely until they also signal done.
    func signalDone() async throws {
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
            try await service.signalDone(in: handle, finalWinner: winner)
            // Match ended — the inbound `.matchEnded` event flips `didEnd`
            // and the view routes home; no payload refresh needed.
        } else {
            try await service.signalDone(in: handle, finalWinner: nil)
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
            // Nothing left to reveal — still hand turn over.
            try await service.pass(revealing: CoordWire(0, 0), in: handle)
            await refreshPayloadAfterTurnEnd()
            return
        }
        try await service.pass(revealing: CoordWire(coord), in: handle)
        state.revealedByOpponent.insert(coord)
        if let truth = puzzle.solution[coord] { state.fills[coord] = truth }
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

    /// Subscribe to `service.inbound`; on every event, reload the
    /// authoritative payload from the backing store and refresh state.
    /// Surfaces `.matchEnded` events via `didEnd` so the view can route out.
    func startListening() {
        Task { [service, handle, weak self] in
            for await event in service.inbound {
                guard let self else { break }
                if let fresh = try? await service.payload(for: handle) {
                    await MainActor.run { self.refresh(payload: fresh) }
                }
                if case .matchEnded = event {
                    await MainActor.run { self.didEnd = true }
                }
            }
        }
    }
}
