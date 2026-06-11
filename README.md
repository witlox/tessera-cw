# Tessera

A multilingual clued crossword game for iPhone and iPad. Mixed Latin-script
grids, asynchronous Game Center multiplayer with a 60-second shot clock and
reveal-on-pass, system-native SwiftUI shell. Free, no in-app purchases, no
ads, no tracking.

Six clued languages: English, Dutch, German, French, Spanish, Italian. Mix
up to three in a single grid; crossings match on the A–Z grid form so
*Straße* / *house* / *casa* interlock cleanly without losing display
diacritics.

This repo holds:
- the **content pipeline** (Python) that generates and validates the bundled
  word/clue corpus,
- **TesseraKit** (Swift package): folding rules, corpus reader, grid
  generator, game state, Move codec, Game Center match service,
- the **iOS app** target (SwiftUI), wired up via `xcodegen`.

---

## Layout

```
content/        Python content pipeline (corpus build + validator)
  tessera_content.py   GridForm folding, concat policy, clue validator (the IP)
  build_content.py     Assembles tessera.sqlite from wordfreq + seeds
  english_seed.py      Hand-authored English clue seed (42 themes)
  seeds_multi.py       Hand-authored multilingual clues (nl/de/fr/es/it × themes)
  schema.sql           Read-only SQLite schema
  tessera.sqlite       Built artifact (3.3 MB; 25,158 words, 3,116 validated clues)

engine/         Python prototype generator (proof-of-assembly; kept for reference)
pipeline/       LLM-driven clue generation against an OpenAI-compatible endpoint
                + a standalone harness auditor for clue regressions

Tessera/                  Swift app + library
  Package.swift           TesseraKit library (corpus, generator, game, services)
  Sources/TesseraKit/     library implementation
  Tests/TesseraKitTests/  XCTest (folding parity, generator determinism, codec, ...)
  App/Tessera/            iOS app target (SwiftUI)
  project.yml             xcodegen spec for the iOS app target
  SETUP.md                Apple Developer / Game Center / build steps
```

---

## Corpus

| Language | Clued words | Themes covered |
|----------|------------:|---------------:|
| en | 597 | 42 / 42 |
| nl | 503 | 42 / 42 |
| de | 504 | 42 / 42 |
| fr | 504 | 42 / 42 |
| es | 504 | 42 / 42 |
| it | 504 | 42 / 42 |
| **total** | **3,116** | **42** |

`words` covers 25,158 entries across the 6 languages from `wordfreq` filtered
through the A–Z fold; `clues` joins to a subset of those words with validator-
approved clues (`source ∈ {seed, llm}`, `validated = 1`).

The theme depth ranges from 6 clued words (cooking × it) at the floor to 21
(en × cinema) at the ceiling, median 12–14. The picker shows the effective
pool size up front; the generator scales its target word count to `min(28,
floor(pool × 0.7))` so small themed pools degrade to mini-puzzles instead of
failing.

### `grid_form` (the A–Z crossing key)

Display surfaces keep diacritics (`Straße`, `año`, `Þór`); the crossing key
is `STRASSE`, `ANO`, `THOR`. Folding is canonicalised in
`content/tessera_content.py:grid_form` and mirrored exactly in
`Tessera/Sources/TesseraKit/Model/Model.swift:GridForm.fold`. The Swift port
has XCTest parity vectors so the two implementations can't drift silently.

Documented casualty: Spanish ñ folds to N, so *año*/*ano* share the gridform
ANO. `BLOCKLIST_SURFACES` blocks the offensive surface "ano" while leaving
"año" playable — a gridform block would wrongly kill both.

---

## Game design (locked)

- **Clued crossword.** Free-form interlocking placement, every maximal run
  is an intentional clued entry (verified by `Generator.incidentalWords()`).
- **Mixed Latin-script grids.** Up to 3 of the 6 languages, chosen at puzzle
  setup. Crossings work on the gridform.
- **On-demand puzzles.** Player picks languages + difficulty + (optional)
  theme; tap "Start"; new grid.
- **Free, no IAP, no ads.** The original Pro tier and StoreKit machinery
  have been removed.
- **Async multiplayer.** Game Center turn-based match; the seed is shipped,
  both clients generate the identical board locally. Only moves and pass-
  reveals travel over the wire.
- **60-second shot clock once you engage.** Per turn. Voluntary or timed-out
  passes trigger reveal-on-pass: one untouched correct cell becomes visible
  to both players (chosen deterministically from the match seed).
- **Solo reveal menu.** Reveal letter / reveal word / reveal puzzle.

---

## Build

### Content pipeline (Python)

```bash
cd content
python3 build_content.py        # rebuilds tessera.sqlite from wordfreq + seeds

cd ../pipeline
export TESSERA_BASE_URL="http://localhost:30000/v1"
export TESSERA_MODEL="your-open-weight-model"
python3 generate_clues.py --lang nl --workers 16 --limit 500
python3 validate_clues.py --audit-db --lang en
```

Every generated clue goes through `validate_clue` before insertion. The
pipeline retries once with the rejection reason fed back to the model.

### iOS app

See [`Tessera/SETUP.md`](Tessera/SETUP.md). Short version:

```bash
brew install xcodegen
cd Tessera
xcodegen generate
open Tessera.xcodeproj
# In Xcode: set your team, build & run.
```

Multiplayer needs the App Store Connect record and a Game Center capability
on the App ID. Solo works without those.

### Library tests

```bash
cd Tessera
swift test
```

17 tests cover GridForm parity vs. Python, generator determinism (load-
bearing for fair multiplayer), incidental-free placement, codec roundtrips,
game-state semantics, and corpus integrity.

---

## What's intentionally *not* here

- StoreKit, Pro entitlement, language-cap gating. Removed — free game.
- Sound and haptics beyond the SwiftUI defaults.
- App Store screenshots and marketing copy.
- Localisation of the app UI (UI is English; clues are in their native
  language).
- Daily-puzzle mode. The brief was on-demand only.
