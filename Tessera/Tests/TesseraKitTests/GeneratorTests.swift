import XCTest
@testable import TesseraKit

final class GeneratorTests: XCTestCase {
    /// A small synthetic clued pool — enough to interlock without depending
    /// on the bundled corpus. Words deliberately share letters.
    private static let pool: [Entry] = [
        ("DOG",   "dog"),
        ("CAT",   "cat"),
        ("ART",   "art"),
        ("STAR",  "star"),
        ("RAT",   "rat"),
        ("PAR",   "par"),
        ("PART",  "part"),
        ("PARK",  "park"),
        ("CARD",  "card"),
        ("DART",  "dart"),
        ("TRAP",  "trap"),
        ("RAP",   "rap"),
        ("APE",   "ape"),
        ("PAGE",  "page"),
        ("EDGE",  "edge"),
        ("GATE",  "gate"),
        ("LATE",  "late"),
        ("LANE",  "lane")
    ].map { Entry(gridForm: $0.0, surface: $0.1, language: .en, clue: "clue-\($0.1)") }

    func testIncidentalFreeAcrossManySeeds() {
        let generator = Generator(pool: Self.pool)
        var opt = Generator.Options(); opt.targetWords = 8; opt.maxDim = 12; opt.restarts = 40
        var totalPlaced = 0
        for seed: UInt64 in 1...10 {
            let puzzle = generator.generate(opt, seed: seed)
            XCTAssertGreaterThanOrEqual(puzzle.placed.count, 3, "seed=\(seed) under-filled")
            let bad = Generator.incidentalWords(in: puzzle)
            XCTAssertTrue(bad.isEmpty, "seed=\(seed) emitted incidental runs: \(bad)")
            totalPlaced += puzzle.placed.count
        }
        XCTAssertGreaterThan(totalPlaced, 30, "generator collapsed across many seeds")
    }

    func testDeterministicSeed() {
        let g = Generator(pool: Self.pool)
        var opt = Generator.Options(); opt.targetWords = 6; opt.maxDim = 10; opt.restarts = 20
        let a = g.generate(opt, seed: 42)
        let b = g.generate(opt, seed: 42)
        XCTAssertEqual(a.placed.map(\.entry.gridForm), b.placed.map(\.entry.gridForm))
        XCTAssertEqual(a.placed.map(\.origin), b.placed.map(\.origin))
        XCTAssertEqual(a.placed.map(\.orientation), b.placed.map(\.orientation))
    }

    func testAdaptiveTargetClampsSmallPools() {
        XCTAssertEqual(Generator.adaptiveTarget(poolSize: 6), 4)
        XCTAssertEqual(Generator.adaptiveTarget(poolSize: 10), 7)
        XCTAssertEqual(Generator.adaptiveTarget(poolSize: 40, requested: 28), 28)
        XCTAssertEqual(Generator.adaptiveTarget(poolSize: 1, requested: 28), 4)
    }

    func testEmptyPoolReturnsEmptyPuzzle() {
        let puzzle = Generator(pool: []).generate(seed: 1)
        XCTAssertTrue(puzzle.placed.isEmpty)
        XCTAssertTrue(puzzle.solution.isEmpty)
    }
}
