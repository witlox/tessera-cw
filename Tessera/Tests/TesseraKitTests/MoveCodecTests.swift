import XCTest
@testable import TesseraKit

final class MoveCodecTests: XCTestCase {
    func testRoundtripPayload() throws {
        let config = MatchConfig(seed: 12345, languages: [.en, .it],
                                 difficulty: .medium, themeSlug: "cinema")
        let moves = [
            Move(cell: CoordWire(0, 0), letter: "A", atTurnDeadline: Date(timeIntervalSince1970: 1000)),
            Move(cell: CoordWire(0, 1), letter: "B", atTurnDeadline: Date(timeIntervalSince1970: 1100))
        ]
        let reveals = [
            MatchPayload.PassReveal(by: "p1", revealed: CoordWire(3, 4),
                                    at: Date(timeIntervalSince1970: 1200))
        ]
        let payload = MatchPayload(config: config, moves: moves,
                                   passReveals: reveals,
                                   players: ["p1", "p2"],
                                   createdAt: Date(timeIntervalSince1970: 500))

        let data = try MoveCodec.encode(payload)
        let back = try MoveCodec.decode(data)
        XCTAssertEqual(back.config.seed, 12345)
        XCTAssertEqual(back.config.themeSlug, "cinema")
        XCTAssertEqual(back.moves.count, 2)
        XCTAssertEqual(back.moves[0].letter, "A")
        XCTAssertEqual(back.moves[1].cell.c, 1)
        XCTAssertEqual(back.passReveals.first?.by, "p1")
        XCTAssertEqual(back.players, ["p1", "p2"])
    }

    func testTurnOrderRotation() {
        let config = MatchConfig(seed: 1, languages: [.en], difficulty: .easy, themeSlug: nil)
        let players = ["p1", "p2"]
        var payload = MatchPayload(config: config, players: players, createdAt: Date())
        XCTAssertEqual(payload.currentTurnPlayer, "p1")

        payload = MatchPayload(config: config,
                               moves: [Move(cell: CoordWire(0,0), letter: "A", atTurnDeadline: Date())],
                               passReveals: [], players: players, createdAt: Date())
        XCTAssertEqual(payload.currentTurnPlayer, "p2")
    }
}
