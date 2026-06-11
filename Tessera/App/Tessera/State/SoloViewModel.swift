import Foundation
import Observation
import TesseraKit

/// One in-progress solo puzzle. Owns the Puzzle (immutable solution) and a
/// mutable GameState (fills, reveals, selection). Persistence is just JSON.
@Observable
@MainActor
final class SoloViewModel {
    let puzzle: Puzzle
    let languages: [Lang]
    let difficulty: Generator.Difficulty
    let themeSlug: String?
    let startedAt: Date

    private(set) var state: GameState
    private(set) var lastTickAt: Date = Date()

    init(corpus: CorpusStore, puzzle: Puzzle, languages: [Lang],
         difficulty: Generator.Difficulty, themeSlug: String?) {
        self.puzzle = puzzle
        self.languages = languages
        self.difficulty = difficulty
        self.themeSlug = themeSlug
        self.startedAt = Date()
        // Default selection: first placed entry, its origin.
        if let first = puzzle.placed.first {
            self.state = GameState(selection: .init(origin: first.origin,
                                                    orientation: first.orientation))
        } else {
            self.state = GameState()
        }
    }

    init(corpus: CorpusStore, restored snap: SoloSnapshot) {
        self.puzzle = snap.puzzle
        self.languages = snap.languages
        self.difficulty = snap.difficulty
        self.themeSlug = snap.themeSlug
        self.startedAt = snap.startedAt
        self.state = snap.state
    }

    static func filterByDifficulty(_ pool: [Entry],
                                   difficulty: Generator.Difficulty) -> [Entry] {
        // Pool entries don't carry their difficulty tier today (Entry has
        // gridForm/surface/lang/clue). The corpus difficulty column is
        // exposed via SQL; for now treat all pools equally and rely on
        // length distribution. Hook left so a future Entry.difficulty
        // can plug in without churning callers.
        _ = difficulty
        return pool
    }

    // MARK: - Mutations driven by the BoardView/KeyboardView

    func select(_ origin: Coord, orientation: Orientation) {
        state.selection = .init(origin: origin, orientation: orientation)
        persist()
    }

    func toggleOrientation() {
        guard var sel = state.selection else { return }
        sel.orientation = sel.orientation == .across ? .down : .across
        state.selection = sel
        persist()
    }

    func place(_ letter: Character, at coord: Coord) {
        state.place(letter, at: coord, in: puzzle)
        advanceCursor()
        persist()
    }

    func backspace() {
        guard let sel = state.selection else { return }
        // If current cell has a fill, clear it; else move back one and clear.
        if state.fills[sel.origin] != nil {
            state.clear(at: sel.origin)
        } else {
            let prev = sel.origin.step(sel.orientation, -1)
            if puzzle.solution[prev] != nil {
                state.clear(at: prev)
                state.selection = .init(origin: prev, orientation: sel.orientation)
            }
        }
        persist()
    }

    private func advanceCursor() {
        guard var sel = state.selection else { return }
        let next = sel.origin.step(sel.orientation, 1)
        if puzzle.solution[next] != nil {
            sel.origin = next
            state.selection = sel
        }
    }

    // MARK: - Reveal menu

    func revealLetter() {
        guard let sel = state.selection else { return }
        state.revealCell(sel.origin, in: puzzle)
        persist()
    }

    func revealEntry() {
        guard let sel = state.selection,
              let placed = entryThrough(sel.origin, orientation: sel.orientation) else { return }
        state.revealEntry(placed, in: puzzle)
        persist()
    }

    func revealAll() {
        state.revealAll(in: puzzle)
        persist()
    }

    // MARK: - Helpers

    func entryThrough(_ coord: Coord, orientation: Orientation) -> PlacedEntry? {
        puzzle.placed.first { p in
            p.orientation == orientation && p.cells.contains(coord)
        }
    }

    func currentClue() -> (PlacedEntry)? {
        guard let sel = state.selection else { return nil }
        return entryThrough(sel.origin, orientation: sel.orientation)
            ?? entryThrough(sel.origin, orientation: sel.orientation == .across ? .down : .across)
    }

    var isComplete: Bool { state.isComplete(puzzle) }

    func tickElapsed() {
        let now = Date()
        state.elapsedSeconds += now.timeIntervalSince(lastTickAt)
        lastTickAt = now
    }

    func snapshot() -> SoloSnapshot {
        SoloSnapshot(puzzle: puzzle, languages: languages, difficulty: difficulty,
                     themeSlug: themeSlug, startedAt: startedAt, state: state)
    }

    private func persist() {
        SoloStore.save(snapshot())
    }
}
