import XCTest
@testable import TesseraKit

/// Integration tests against the bundled `tessera.sqlite`. They verify the
/// claims used by the picker (themes available, pool counts ≥ floor) so a
/// stale corpus update can't silently ship.
final class CorpusStoreTests: XCTestCase {
    private var corpus: SQLiteCorpusStore!

    override func setUpWithError() throws {
        corpus = try SQLiteCorpusStore()
    }

    func testAllSixLanguagesYieldClues() throws {
        for lang in Lang.allCases {
            let pool = try corpus.cluedPool(languages: [lang], themeSlug: nil,
                                            minLen: 3, maxLen: 11)
            XCTAssertGreaterThan(pool.count, 200,
                                 "pool for \(lang) was \(pool.count); corpus regressed?")
        }
    }

    func testThemesCoverAllLanguages() throws {
        let themes = try corpus.themes()
        XCTAssertGreaterThanOrEqual(themes.count, 40,
                                    "expected ≥40 themes, got \(themes.count)")
        for t in themes {
            for lang in Lang.allCases {
                let count = t.counts[lang.rawValue] ?? 0
                XCTAssertGreaterThanOrEqual(count, 5,
                    "theme '\(t.slug)' × \(lang.rawValue) only has \(count) clued words")
            }
        }
    }

    func testThemeFilterScopesPool() throws {
        let any = try corpus.poolCount(languages: [.en], themeSlug: nil,
                                       minLen: 3, maxLen: 11)
        let cinema = try corpus.poolCount(languages: [.en], themeSlug: "cinema",
                                          minLen: 3, maxLen: 11)
        XCTAssertGreaterThan(any, cinema)
        XCTAssertGreaterThan(cinema, 5)
    }

    func testMultiLanguagePoolUnionGrows() throws {
        let en = try corpus.poolCount(languages: [.en], themeSlug: nil,
                                      minLen: 3, maxLen: 11)
        let enIt = try corpus.poolCount(languages: [.en, .it], themeSlug: nil,
                                        minLen: 3, maxLen: 11)
        XCTAssertGreaterThan(enIt, en)
    }
}
