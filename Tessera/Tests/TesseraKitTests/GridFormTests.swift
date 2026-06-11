import XCTest
@testable import TesseraKit

/// Parity vectors mirroring `content/tessera_content.py:grid_form` self-test.
/// If these drift, the on-device crossing key won't match the bundled corpus.
final class GridFormTests: XCTestCase {
    func testFoldingMatchesPython() {
        let cases: [(String, String)] = [
            ("Straße", "STRASSE"),
            ("Łódź", "LODZ"),
            ("Þór", "THOR"),
            ("cœur", "COEUR"),
            ("año", "ANO"),
            ("naïve", "NAIVE"),
            ("Reykjavík", "REYKJAVIK"),
            ("kärlek", "KARLEK"),
            ("piękny", "PIEKNY")
        ]
        for (surface, expected) in cases {
            XCTAssertEqual(GridForm.fold(surface), expected,
                           "fold('\(surface)') drifted from Python rules")
        }
    }

    func testStripsWhitespaceAndPunctuation() {
        XCTAssertEqual(GridForm.fold("New York"), "NEWYORK")
        XCTAssertEqual(GridForm.fold("co-op"), "COOP")
        XCTAssertEqual(GridForm.fold("don't"), "DONT")
    }

    func testEmptyAndDigits() {
        XCTAssertEqual(GridForm.fold(""), "")
        XCTAssertEqual(GridForm.fold("123"), "")
    }
}
