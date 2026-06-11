import XCTest
@testable import TesseraKit

final class GameStateTests: XCTestCase {
    private func sample() -> Puzzle {
        let cat = Entry(gridForm: "CAT", surface: "cat", language: .en, clue: "feline")
        let cap = Entry(gridForm: "CAP", surface: "cap", language: .en, clue: "headwear")
        let placedCat = PlacedEntry(entry: cat, origin: Coord(0, 0), orientation: .across)
        let placedCap = PlacedEntry(entry: cap, origin: Coord(0, 0), orientation: .down)
        let solution: [Coord: Character] = [
            Coord(0,0): "C", Coord(0,1): "A", Coord(0,2): "T",
            Coord(1,0): "A", Coord(2,0): "P"
        ]
        return Puzzle(placed: [placedCat, placedCap], solution: solution, languages: [.en])
    }

    func testCompletionRequiresAllCorrect() {
        let p = sample()
        var s = GameState()
        XCTAssertFalse(s.isComplete(p))
        for (c, ch) in p.solution { s.place(ch, at: c, in: p) }
        XCTAssertTrue(s.isComplete(p))
    }

    func testWrongCellsTracksMistakes() {
        let p = sample()
        var s = GameState()
        s.place("X", at: Coord(0,0), in: p)
        XCTAssertEqual(s.wrongCells(p), [Coord(0,0)])
    }

    func testRevealOverridesFill() {
        let p = sample()
        var s = GameState()
        s.place("X", at: Coord(0,0), in: p)
        s.revealCell(Coord(0,0), in: p)
        XCTAssertEqual(s.effectiveLetter(Coord(0,0), in: p), "C")
        XCTAssertTrue(s.wrongCells(p).isEmpty,
                      "revealed cells must not count as wrong even if filled was wrong")
    }

    func testCodableRoundtrip() throws {
        let p = sample()
        var s = GameState()
        s.place("A", at: Coord(0,1), in: p)
        s.revealCell(Coord(0,0), in: p)
        s.revealedByOpponent.insert(Coord(2,0))
        s.selection = .init(origin: Coord(0,1), orientation: .across)
        s.elapsedSeconds = 42.5

        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(GameState.self, from: data)
        XCTAssertEqual(back.fills, s.fills)
        XCTAssertEqual(back.revealed, s.revealed)
        XCTAssertEqual(back.revealedByOpponent, s.revealedByOpponent)
        XCTAssertEqual(back.selection, s.selection)
        XCTAssertEqual(back.elapsedSeconds, s.elapsedSeconds, accuracy: 0.001)
    }
}
