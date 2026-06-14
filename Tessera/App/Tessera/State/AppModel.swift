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

    /// Mirror of `GKLocalPlayer.local.isAuthenticated`, surfaced as an
    /// `@Observable` property so SwiftUI views (HomeView's Leaderboards
    /// button, MultiplayerView, etc.) re-render when Game Center finishes
    /// signing the user in. Reading
    /// `model.match_service.isAuthenticated` directly is a method call on
    /// a non-observable type and SwiftUI can't notice when GameKit flips
    /// it — that's why the Leaderboards button stayed disabled after a
    /// successful sandbox sign-in.
    var isGameCenterAuthenticated: Bool = false

    /// Filled by `MultiplayerView` right before it presents the matchmaker.
    /// When `newMatches` fires for a brand-new match we initiated, we use
    /// this to seed its `matchData`. Cleared once consumed.
    var pendingMatchConfig: PendingMatchConfig?

    struct PendingMatchConfig: Sendable {
        let languages: [Lang]
        let difficulty: Generator.Difficulty
        let themeSlug: String?
    }

    // MARK: - Leaderboard counters (persisted in UserDefaults)

    /// Total puzzles solved across solo + multiplayer. Apple's leaderboard
    /// replaces (doesn't accumulate) on submit, so we track the running
    /// total locally and report the full value each time.
    // Use the concrete type (not `Self`) for keys referenced in stored-
    // property initializers — Swift disallows covariant `Self` there.
    var puzzlesSolved: Int = UserDefaults.standard.integer(forKey: AppModel.kPuzzlesSolved) {
        didSet { UserDefaults.standard.set(puzzlesSolved, forKey: AppModel.kPuzzlesSolved) }
    }
    var multiplayerWins: Int = UserDefaults.standard.integer(forKey: AppModel.kMultiplayerWins) {
        didSet { UserDefaults.standard.set(multiplayerWins, forKey: AppModel.kMultiplayerWins) }
    }

    private static let kPuzzlesSolved   = "tessera.puzzlesSolved"
    private static let kMultiplayerWins = "tessera.multiplayerWins"

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
        // Best-effort GameKit auth in the background, then ask Game Center
        // for any active turn-based matches the local player is already in
        // so the home screen can show them without waiting for an opponent
        // turn event or a fresh invite tap.
        Task { [weak self] in
            try? await self?.signInToGameCenter()
            await self?.restoreActiveMatches()
        }
        // Listen for matchmaker-picked / friend-invite-arrived matches.
        Task { [weak self] in
            guard let stream = self?.match_service.newMatches else { return }
            for await matchID in stream {
                await self?.handleNewMatch(matchID: matchID)
            }
        }
    }

    /// After auth resolves, surface the local player's most recent
    /// non-ended match on Home so the user doesn't have to re-open via a
    /// notification or invite to see it. Cheap-and-correct: feed each
    /// match ID through the same `handleNewMatch` pipeline the listener
    /// uses; the existing duplicate-guard short-circuits if one is already
    /// loaded, and the first match that attaches wins our single
    /// `match` slot.
    private func restoreActiveMatches() async {
        guard match == nil else { return }
        guard let ids = try? await match_service.loadActiveMatchIDs() else { return }
        for id in ids {
            await handleNewMatch(matchID: id)
            if match != nil { break }
        }
    }

    /// Called when GameKit reports a match became active for us. Decides
    /// whether to attach (and surface it to the UI) using `pendingMatchConfig`
    /// if present — that's the player A path (we initiated). Otherwise it's
    /// player B (we accepted an invite) and the matchData already has the
    /// config player A seeded.
    func handleNewMatch(matchID: String) async {
        // If a match is already in play for this ID, ignore duplicate events.
        if let existing = match, existing.handle.id == matchID { return }

        let seedConfig: MatchConfig? = pendingMatchConfig.map { pc in
            MatchConfig(seed: UInt64.random(in: 1...UInt64.max),
                        languages: pc.languages,
                        difficulty: pc.difficulty,
                        themeSlug: pc.themeSlug)
        }
        pendingMatchConfig = nil

        do {
            let (handle, payload) = try await match_service.attach(
                matchID: matchID, seedingIfEmpty: seedConfig)
            guard let corpus else { return }
            let pool = try corpus.cluedPool(languages: handle.config.languages,
                                            themeSlug: handle.config.themeSlug,
                                            minLen: 3, maxLen: 11)
            let generator = Generator(pool: pool)
            let puzzle = generator.generate(seed: handle.config.seed)
            let vm = MatchViewModel(service: match_service, handle: handle,
                                    puzzle: puzzle, me: localPlayerID,
                                    payload: payload)
            vm.startListening()
            self.match = vm
        } catch {
            corpusError = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
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

    /// Drives Game Center sign-in and mirrors the result into observable
    /// properties so SwiftUI views re-render when auth finishes. Called
    /// from `bootstrap()` for the silent initial attempt and from
    /// `MultiplayerView` for the explicit "Sign in" button. Errors
    /// propagate so the multiplayer screen can surface them; the
    /// observable flag still reflects whatever state GameKit ended up in.
    func signInToGameCenter() async throws {
        defer {
            #if canImport(GameKit)
            localPlayerID = GKLocalPlayer.local.gamePlayerID
            isGameCenterAuthenticated = GKLocalPlayer.local.isAuthenticated
            #else
            isGameCenterAuthenticated = match_service.isAuthenticated
            #endif
        }
        try await match_service.authenticate()
    }

    // MARK: - Completion recording (fan out to leaderboards)

    func recordSoloCompletion() {
        puzzlesSolved += 1
        let total = puzzlesSolved
        Task { [match_service] in
            try? await match_service.reportLeaderboard(score: total, to: .puzzlesSolved)
        }
    }

    /// `didWin` is true on the client whose last move completed the puzzle.
    /// Both clients increment `puzzlesSolved` (they both participated); only
    /// the winner increments `multiplayerWins`.
    func recordMultiplayerCompletion(didWin: Bool) {
        puzzlesSolved += 1
        if didWin { multiplayerWins += 1 }
        let totals = (puzzlesSolved, multiplayerWins, didWin)
        Task { [match_service] in
            try? await match_service.reportLeaderboard(score: totals.0, to: .puzzlesSolved)
            if totals.2 {
                try? await match_service.reportLeaderboard(score: totals.1, to: .multiplayerWins)
            }
        }
    }
}
