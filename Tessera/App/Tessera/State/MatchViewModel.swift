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

    /// Returns the placed entry the cursor is on (across preferred).
    func currentClue(for selection: GameState.Selection) -> PlacedEntry? {
        puzzle.placed.first { p in
            p.orientation == selection.orientation && p.cells.contains(selection.origin)
        }
    }

    func submitLetter(_ letter: Character, at coord: Coord, deadline: Date) async throws {
        let move = Move(cell: CoordWire(coord), letter: letter, atTurnDeadline: deadline)
        try await service.submit(move, in: handle)
        // Local optimistic apply; opponent receives via GKLocalPlayerListener.
        state.place(letter, at: coord, in: puzzle)
    }

    /// Pick a deterministic untouched cell and pass. Seed is the match seed
    /// combined with the current pass index so successive passes reveal
    /// different cells; both clients compute the same coord from the same
    /// inputs and agree on the reveal.
    func pass() async throws {
        var rng = SeededRNG(handle.config.seed &+ UInt64(payload.passReveals.count) &+ 17)
        guard let coord = state.pickUntouchedCell(puzzle, rng: &rng) else {
            // Nothing left to reveal — still hand turn over.
            try await service.pass(revealing: CoordWire(0, 0), in: handle); return
        }
        try await service.pass(revealing: CoordWire(coord), in: handle)
        state.revealedByOpponent.insert(coord)
        if let truth = puzzle.solution[coord] { state.fills[coord] = truth }
    }

    /// Replay payload to refresh state after an inbound event.
    func refresh(payload: MatchPayload) {
        self.payload = payload
        self.state = payload.gameState(for: puzzle)
    }

    /// Subscribe to `service.inbound`; on every event, reload the
    /// authoritative payload from the backing store and refresh state.
    func startListening() {
        Task { [service, handle, weak self] in
            for await _ in service.inbound {
                guard let fresh = try? await service.payload(for: handle) else { continue }
                await MainActor.run { self?.refresh(payload: fresh) }
            }
        }
    }
}
