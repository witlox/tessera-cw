import Foundation
import Observation
import TesseraKit
#if canImport(GameKit)
import GameKit
#endif

/// Root state container. One `AppModel` lives for the app lifetime; views
/// observe sub-models off it (solo game, current match, etc.) via `@Bindable`.
@Observable
@MainActor
final class AppModel {
    var corpus: SQLiteCorpusStore?
    var themes: [Theme] = []
    var corpusError: String?

    /// Live solo game, if one is in progress.
    var solo: SoloViewModel?
    /// Live multiplayer match, if one is open.
    var match: MatchViewModel?

    let match_service: MatchService

    /// Local Game Center player ID; empty until auth resolves. The
    /// `MatchViewModel` uses this to attribute moves and decide whose turn
    /// is active.
    var localPlayerID: String = ""

    init() {
        #if canImport(GameKit)
        // GameKit works in the simulator with a Sandbox Game Center account
        // signed in via Settings. Auth failure is non-fatal — the UI shows
        // an empty state and the rest of the app keeps working.
        self.match_service = GameKitMatchService()
        #else
        self.match_service = StubMatchService()
        #endif
    }

    func bootstrap() async {
        do {
            let store = try SQLiteCorpusStore()
            self.corpus = store
            self.themes = (try? store.themes()) ?? []
        } catch {
            self.corpusError = String(describing: error)
        }
        // Restore in-progress solo game if any.
        if let saved = SoloStore.load(), let corpus {
            self.solo = SoloViewModel(corpus: corpus, restored: saved)
        }
        // Best-effort GameKit auth in the background.
        Task { [weak self] in
            try? await self?.match_service.authenticate()
            #if canImport(GameKit)
            await MainActor.run {
                self?.localPlayerID = GKLocalPlayer.local.gamePlayerID
            }
            #endif
        }
    }

    /// Build a fresh puzzle from the picker selection and hand control to a
    /// new SoloViewModel. Any previous solo game is discarded (single slot).
    func startSolo(languages: [Lang], difficulty: Generator.Difficulty,
                   themeSlug: String?) {
        guard let corpus else { return }
        let mix = LanguageMix(languages) ?? LanguageMix([.en])!
        do {
            let pool = try corpus.cluedPool(languages: mix.languages,
                                            themeSlug: themeSlug,
                                            minLen: 3, maxLen: 11)
            let filtered = SoloViewModel.filterByDifficulty(pool, difficulty: difficulty)
            let usePool = filtered.count >= 6 ? filtered : pool
            let generator = Generator(pool: usePool)
            let puzzle = generator.generate()
            self.solo = SoloViewModel(corpus: corpus, puzzle: puzzle,
                                      languages: mix.languages,
                                      difficulty: difficulty, themeSlug: themeSlug)
            SoloStore.save(self.solo!.snapshot())
        } catch {
            corpusError = String(describing: error)
        }
    }

    func endSolo() {
        SoloStore.clear()
        solo = nil
    }

    func endMatch() {
        match = nil
    }
}
