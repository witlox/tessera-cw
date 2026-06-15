import XCTest
@testable import TesseraKit

final class MoveCodecTests: XCTestCase {
    func testRoundtripPayload() throws {
        let config = MatchConfig(seed: 12345, languages: [.en, .it],
                                 difficulty: .medium, themeSlug: "cinema")
        let moves = [
            Move(by: "p1", cell: CoordWire(0, 0), letter: "A",
                 atTurnDeadline: Date(timeIntervalSince1970: 1000)),
            Move(by: "p2", cell: CoordWire(0, 1), letter: "B",
                 atTurnDeadline: Date(timeIntervalSince1970: 1100))
        ]
        let reveals = [
            MatchPayload.PassReveal(by: "p1", revealed: CoordWire(3, 4),
                                    at: Date(timeIntervalSince1970: 1200))
        ]
        let payload = MatchPayload(config: config, moves: moves,
                                   passReveals: reveals,
                                   doneSignals: ["p1"],
                                   players: ["p1", "p2"],
                                   createdAt: Date(timeIntervalSince1970: 500),
                                   currentPlayer: "p2")

        let data = try MoveCodec.encode(payload)
        let back = try MoveCodec.decode(data)
        XCTAssertEqual(back.config.seed, 12345)
        XCTAssertEqual(back.config.themeSlug, "cinema")
        XCTAssertEqual(back.moves.count, 2)
        XCTAssertEqual(back.moves[0].letter, "A")
        XCTAssertEqual(back.moves[0].by, "p1")
        XCTAssertEqual(back.moves[1].cell.c, 1)
        XCTAssertEqual(back.passReveals.first?.by, "p1")
        XCTAssertEqual(back.doneSignals, ["p1"])
        XCTAssertEqual(back.currentPlayer, "p2")
        XCTAssertEqual(back.players, ["p1", "p2"])
    }

    func testTurnDrivenByCurrentPlayer() {
        let config = MatchConfig(seed: 1, languages: [.en], difficulty: .easy, themeSlug: nil)
        let players = ["p1", "p2"]
        // Default (no explicit currentPlayer) falls back to first player.
        var payload = MatchPayload(config: config, players: players, createdAt: Date())
        XCTAssertEqual(payload.currentTurnPlayer, "p1")

        // Letters appended don't shift the turn — currentPlayer is authoritative.
        payload = MatchPayload(config: config,
                               moves: [
                                Move(by: "p1", cell: CoordWire(0,0), letter: "A", atTurnDeadline: Date()),
                                Move(by: "p1", cell: CoordWire(0,1), letter: "B", atTurnDeadline: Date())
                               ],
                               players: players, createdAt: Date(),
                               currentPlayer: "p1")
        XCTAssertEqual(payload.currentTurnPlayer, "p1")

        // After service flips currentPlayer (via pass or check), it's p2.
        payload = MatchPayload(config: config, players: players, createdAt: Date(),
                               currentPlayer: "p2")
        XCTAssertEqual(payload.currentTurnPlayer, "p2")
    }

    func testCorrectLetterCountAttribution() {
        let cat = Entry(gridForm: "CAT", surface: "cat", language: .en, clue: "feline")
        let placedCat = PlacedEntry(entry: cat, origin: Coord(0, 0), orientation: .across)
        let solution: [Coord: Character] = [
            Coord(0,0): "C", Coord(0,1): "A", Coord(0,2): "T"
        ]
        let puzzle = Puzzle(placed: [placedCat], solution: solution, languages: [.en])

        let config = MatchConfig(seed: 1, languages: [.en], difficulty: .easy, themeSlug: nil)
        let moves: [Move] = [
            Move(by: "p1", cell: CoordWire(0, 0), letter: "C", atTurnDeadline: Date()),
            Move(by: "p2", cell: CoordWire(0, 1), letter: "A", atTurnDeadline: Date()),
            Move(by: "p2", cell: CoordWire(0, 2), letter: "X", atTurnDeadline: Date()),
            // p1 overwrites p2's wrong letter with the correct one — last-wins
            // means this credits p1, not p2.
            Move(by: "p1", cell: CoordWire(0, 2), letter: "T", atTurnDeadline: Date())
        ]
        let payload = MatchPayload(config: config, moves: moves,
                                   players: ["p1", "p2"], createdAt: Date(),
                                   currentPlayer: "p1")

        XCTAssertEqual(payload.correctLetterCount(playerID: "p1", puzzle: puzzle), 2) // C, T
        XCTAssertEqual(payload.correctLetterCount(playerID: "p2", puzzle: puzzle), 1) // A
    }
}
