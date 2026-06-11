# Tessera — architecture

Two layers in this directory:

1. **TesseraKit** — Swift package, pure model / corpus / generator / game.
   Compiles with `swift build`; tests run with `swift test`. Has GRDB as its
   only external dependency.
2. **Tessera (app)** — SwiftUI iOS app target. Built by `xcodegen` from
   `project.yml`, depends on TesseraKit via local SwiftPM. Universal
   iPhone + iPad.

## TesseraKit modules

```
Model/        Lang, Coord, Orientation, GridForm.fold, Entry, PlacedEntry, Puzzle
Corpus/       CorpusStore protocol + SQLiteCorpusStore (GRDB reader over the
              bundled, read-only tessera.sqlite). Theme support, pool sizing.
Generator/    Free-form interlocking placement, greedy maximise-crossings with
              random restarts, deterministic via SeededRNG (xorshift), pool-
              size-aware target. Generator.incidentalWords() proves every
              maximal run is a placed entry.
Game/         GameState (fills, reveals, completion), MoveCodec (MatchPayload
              wire format for GKTurnBasedMatch.matchData), ShotClock (60s
              per-turn countdown).
Services/     MatchService protocol + LanguageMix picker constraint.
              GameKitMatchService (real Game Center conformance).
              StubMatchService (used when GameKit is unavailable / in tests).
```

## Cross-implementation invariants

- **GridForm folding** must match between Swift (`Model.swift:GridForm.fold`)
  and Python (`content/tessera_content.py:grid_form`). The Swift parity test
  covers the awkward cases — ß, ł, ø, þ, æ, œ, ñ, plus the accented vowels
  that decompose under NFKD. If you add a new ligature, add it to both.
- **Seeded generation** is the fair-multiplayer contract: both clients
  receive the same `MatchConfig.seed`, build the same pool from their local
  corpus, and run `Generator.generate(seed:)` — they MUST produce the
  identical Puzzle. `GeneratorTests.testDeterministicSeed` enforces this.
  Anything new in the generator must not introduce non-deterministic state
  (no `Dictionary` iteration without a sort, no `Date.now`).

## Generator properties (measured)

- 0 incidental words across 10+ seeds × the small synthetic pool used in
  tests. The same property holds on the real bundled corpus.
- Adaptive target: `min(opt.targetWords, floor(pool × 0.7))`, never below 4.
  A pool of 6 (cooking × it) yields a 4-entry mini-puzzle; a pool of 1,500+
  (unthemed full corpus) hits the requested 28.
- Free-form interlock density on the bundled corpus is ~0.39–0.46. Not
  symmetric / not American-style every-cell-checked. Casual clued play
  doesn't require that aesthetic.

## App seams

The view layer talks to TesseraKit through three @Observable models:
- `AppModel` — corpus handle, themes, current solo / current match.
- `SoloViewModel` — owns one in-progress Puzzle and its GameState.
- `MatchViewModel` — wraps a `MatchHandle` + decoded payload; replays moves
  to derive `GameState` so receivers can drop straight into the right view.

Matchmaking is programmatic (`GKTurnBasedMatch.find(for:)`) so we don't ship
UIKit out of TesseraKit. The SwiftUI `MultiplayerView` calls the service
and routes the resolved handle into `AppModel.match`.
