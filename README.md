# Tessera — content layer

*(working name; rename freely)*

A multilingual **clued crossword**: mixed Latin-script grids, A–Z crossing letters,
per-turn shot clock, reveal-on-pass, async multiplayer. **Free tier = English only.**
**Pro (£1.99) = up to 3 of ~19 Latin-script European languages, mixed grids.**

This package is the **content layer only** — the data format plus the generation/validation
pipeline. The Swift app (engine, UI, Game Center, StoreKit) is the next step.

---

## The honest boundary (read this first)

You asked to "generate word lists and hints for all languages." Here is exactly what is
real versus what is scaffolded, because the distinction is the whole ballgame:

| Dimension | Status | Source |
|-----------|--------|--------|
| **Words** (19 languages) | **Real** | `wordfreq` frequency data, folded to A–Z |
| **Hand-authored clues** | **Real, validated** | 42 themes × 6 languages, ~6 words/theme seeded, every clue passed the harness |
| **Deeper clues (toward each theme's cap)** | **Pipeline** | run `pipeline/generate_clues.py` on your endpoint |
| **Non-English theme membership** | **Not generated here** | upstream step — see below |

Hand-fabricating ~180k clues across ~18 languages (most low-resource) in one pass would
have produced exactly the unvalidated slop we agreed to avoid. The clue *validator* is the
real IP; the generator is commodity. So the validator is built and proven; generation is
wired to your own inference stack.

---

## Why SQLite ("native Xcode format")

One bundled, read-only `tessera.sqlite` ships in the app. Rationale over the alternatives:

- **JSON/plist** — no indexed query; loading 70k+ rows to filter by language/theme/difficulty
  is wasteful on device.
- **Prebuilt Core Data store** — version-brittle to ship; the model hash must match the binary.
- **SQLite** — indexed `(language, grid_len)` and `(language, difficulty)` lookups are exactly
  what the grid generator needs at runtime. Wrap it with **GRDB** (recommended) or point a
  Core Data store at it. Read-only, so concurrency is trivial.

Built artifact: `content/tessera.sqlite` — **74,188 words (19 languages), 1,641 hand-authored validated clues across 6 languages (en + nl/de/fr/es/it), 42 themes, ~8.5 MB.**

---

## Schema (`content/schema.sql`)

- `words(language, surface, grid_form, grid_len, zipf, difficulty, is_concat)` — `surface` keeps
  diacritics ("Straße"); `grid_form` is the A–Z crossing key ("STRASSE").
- `groups(slug, label_en)` — themes.
- `word_groups` — many-to-many (a word can sit in several themes).
- `clues(word_id, language, text, source, validated)` — clue language == word language; in a
  mixed grid the clue's language tells the solver which language the answer is in.

## gridForm normalization (`content/tessera_content.py`)

Explicit map for non-decomposable glyphs, then NFKD + strip marks, then keep A–Z:

| Glyph | → | | Glyph | → |
|---|---|---|---|---|
| ß | SS | | ø | O |
| ł | L  | | đ/ð | D |
| þ | TH | | æ | AE |
| œ | OE | | é,ü,ñ,… | E,U,N,… |

**Documented behaviour:** ñ folds to N, so *año*/*ano* share the gridform ANO. The
`surface` ("año") is preserved and displayed correctly; only the crossing key is folded.
`BLOCKLIST_SURFACES` blocks the offensive *surface* "ano" while leaving the innocent "año"
playable — a gridform block would wrongly kill both.

## Per-language concatenation (locked decision)

Germanic + Finno-Ugric compound natively (allow long concatenated entries); Romance uses
particles (concatenation reads unnatural → disallowed). Encoded in `CONCAT_POLICY` with a
per-language `max_grid_len`. Not a global rule.

---

## Run

```bash
cd content
python3 build_content.py          # rebuild tessera.sqlite (prints counts, no list dumps)

cd ../pipeline
python3 generate_clues.py --lang nl --dry-run     # see what would run
export TESSERA_BASE_URL="http://localhost:30000/v1"   # your SGLang/vLLM endpoint
export TESSERA_MODEL="your-open-weight-model"
python3 generate_clues.py --lang nl --limit 500   # generate -> VALIDATE -> write
python3 validate_clues.py --audit-db --lang en    # re-audit any clues in the DB
```

Every generated clue is forced through `validate_clue()` before insert. The obvious next
iteration is a retry-with-feedback loop (feed the rejection reason back to the model).

## Open upstream step: non-English theme membership

`word_groups` is populated for English only. Assigning the other languages' words to the 100
themes is its own task. Two viable routes, both better than hand-mapping:
1. Translate/expand the English theme anchors, then string-match.
2. Multilingual sentence embeddings → nearest-theme assignment with a confidence floor.

The `--theme` filter on the pipeline is optional; you can generate clues language-wide and
assign themes separately.

---

## What's intentionally NOT here yet

The Swift app: grid generator (backtracking CSP over `grid_form`), the play loop, Game Center
turn-based match with the 60s shot clock + reveal-on-pass, StoreKit 2 unlock, SwiftUI shell,
and graphics. That's the next build. `Tessera/` is an empty placeholder for it.

## Locked design decisions

- Clued crossword, mixed Latin-script grids, A–Z dual-form (surface + grid_form).
- Free = English only; Pro = ≤3 of 19 languages, mixed grids.
- Multiplayer: async turn-based, 60s shot clock once you engage, reveal-on-pass.
- Latin-only (Cyrillic/Greek excluded — they cannot cross Latin words).
- LLM clue-gen **plus** a mandatory validation harness; the harness is the IP.
