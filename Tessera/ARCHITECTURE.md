# Tessera — backbone

Swift package `TesseraKit`: corpus → generator → game logic, with platform
services behind protocols. Compiles in Xcode/SwiftPM (GRDB dependency); it is
**not** built in the content sandbox.

## Module map
- `Model/`      core value types; `GridForm.fold` mirrors the Python `grid_form()` — keep folding rules in sync with `content/tessera_content.py`.
- `Corpus/`     `CorpusStore` protocol + GRDB reader over the bundled read-only `tessera.sqlite`. Clued-pool query mirrors the validated `engine/generate.py:load_pool`.
- `Generator/`  faithful port of the validated free-form interlocking generator + `incidentalWords` verifier. Seeded RNG → reproducible boards.
- `Services/`   seams only: `EntitlementStore` (StoreKit), `MatchService` (Game Center turn-based). Concrete conformances live in the app target, built live in Xcode.

## What the prototype PROVED (engine/generate.py, 80 grids)
- Clued-words-only assembly is reliable: 28/28 words, 15×15, ~0.1s, every seed.
- Correct: 0 incidental words — every maximal run is an intentional clued entry.
- Mixed-language interlocking works on `grid_form` (the Pro feature is viable).

## Open design questions the proof surfaced (decide before/with the build)
1. **Density model.** Output is free-form (0.39–0.46; some letters in one word
   only). American-style every-cell-checked grids need a stricter skeleton-first
   generator. Casual clued play probably doesn't — confirm before investing.
2. **Language balance.** Mixed grids skew to the largest pool / seed language.
   Pro "mix up to 3" needs a balancing knob (per-language quota, or weight
   candidate pick inversely to pool size). Not load-bearing; cosmetic-ish.
3. **Layout aesthetics.** Free-form interlock != pretty symmetric grid. If a
   particular look is wanted, that's separate work on top of the proven fill.

## Not built here (do in Xcode + Claude Code)
SwiftUI board/keyboard/clue UI; GameState (fills, reveal-on-pass, shot clock);
StoreKit2 + GameKit conformances; app icon. Seams above are the contracts.
