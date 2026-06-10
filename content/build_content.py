"""
build_content.py
Assembles tessera.sqlite:
  - real per-language word inventories from wordfreq (folded to A-Z gridForm)
  - the hand-authored, harness-validated English seed (themes + clues)

Run:  python3 build_content.py
Prints summary COUNTS only -- never dumps the lists themselves.
"""
from __future__ import annotations
import os, re, sqlite3, sys
from wordfreq import top_n_list, zipf_frequency, available_languages

from tessera_content import grid_form, difficulty_tier, policy_for, validate_clue
from english_seed import SEED
from seeds_multi import MULTI

HERE = os.path.dirname(os.path.abspath(__file__))
DB = os.path.join(HERE, "tessera.sqlite")
SCHEMA = os.path.join(HERE, "schema.sql")

# Latin-script European targets that wordfreq actually covers (probed earlier).
TARGET_LANGS = ["en","nl","de","fr","es","it","sv","da","nb","fi","is",
                "pl","cs","sk","hu","ro","sl","lv","lt"]
# Documented gaps (no wordfreq data): hr (Croatian), et (Estonian) -> pipeline-only.

CANDIDATES_PER_LANG = 4000   # pull this many, then filter
_LETTERS = re.compile(r"^[^\W\d_]+$", re.UNICODE)


def fresh_db() -> sqlite3.Connection:
    if os.path.exists(DB):
        os.remove(DB)
    con = sqlite3.connect(DB)
    with open(SCHEMA, encoding="utf-8") as f:
        con.executescript(f.read())
    return con


def load_word_inventories(con: sqlite3.Connection) -> dict[str, int]:
    counts = {}
    cur = con.cursor()
    avail = set(available_languages())
    for lang in TARGET_LANGS:
        if lang not in avail:
            counts[lang] = 0
            continue
        pol = policy_for(lang)
        seen = set()
        n = 0
        for tok in top_n_list(lang, CANDIDATES_PER_LANG):
            surf = tok.strip()
            if not surf or not _LETTERS.match(surf):
                continue
            gf = grid_form(surf)
            if not (3 <= len(gf) <= pol.max_grid_len):
                continue
            if surf in seen:
                continue
            seen.add(surf)
            z = zipf_frequency(surf, lang)
            diff = difficulty_tier(z, len(gf))
            try:
                cur.execute(
                    "INSERT OR IGNORE INTO words"
                    "(language,surface,grid_form,grid_len,zipf,difficulty,is_concat)"
                    " VALUES (?,?,?,?,?,?,0)",
                    (lang, surf, gf, len(gf), z, diff),
                )
                if cur.rowcount:
                    n += 1
            except sqlite3.Error as e:
                print(f"  ! {lang} {surf}: {e}", file=sys.stderr)
        counts[lang] = n
    con.commit()
    return counts


def load_multi_seed(con: sqlite3.Connection) -> dict[str, dict]:
    """Load natively-authored clue batches for nl/de/fr/es/it, theme-aligned with English."""
    cur = con.cursor()
    out = {}
    for lang, themes in MULTI.items():
        stats = {"words": 0, "clues_ok": 0, "clues_rejected": 0, "rejected": []}
        for slug, pairs in themes.items():
            cur.execute("INSERT OR IGNORE INTO groups(slug,label_en) VALUES (?,?)",
                        (slug, slug.title()))
            cur.execute("SELECT id FROM groups WHERE slug=?", (slug,))
            gid = cur.fetchone()[0]
            for surf, clue in pairs:
                gf = grid_form(surf)
                z = zipf_frequency(surf, lang)
                diff = difficulty_tier(z, len(gf))
                cur.execute(
                    "INSERT OR IGNORE INTO words"
                    "(language,surface,grid_form,grid_len,zipf,difficulty,is_concat)"
                    " VALUES (?,?,?,?,?,?,0)",
                    (lang, surf, gf, len(gf), z, diff))
                cur.execute("SELECT id FROM words WHERE language=? AND surface=?", (lang, surf))
                wid = cur.fetchone()[0]
                stats["words"] += 1
                cur.execute("INSERT OR IGNORE INTO word_groups(word_id,group_id) VALUES (?,?)",
                            (wid, gid))
                v = validate_clue(surf, clue, lang)
                if v.ok:
                    cur.execute(
                        "INSERT OR IGNORE INTO clues(word_id,language,text,source,validated)"
                        " VALUES (?,?,?,?,1)", (wid, lang, clue, "seed"))
                    stats["clues_ok"] += 1
                else:
                    stats["clues_rejected"] += 1
                    stats["rejected"].append((surf, "; ".join(v.reasons)))
        out[lang] = stats
    con.commit()
    any_rej = any(s["rejected"] for s in out.values())
    if any_rej:
        print("\n  Multi-seed clues rejected by harness (fix these):")
        for lang, s in out.items():
            for surf, why in s["rejected"]:
                print(f"    - [{lang}] {surf}: {why}")
    return out


def load_english_seed(con: sqlite3.Connection) -> dict[str, int]:
    cur = con.cursor()
    stats = {"groups": 0, "seed_words": 0, "clues_ok": 0, "clues_rejected": 0}
    rejected = []
    for slug, (label, pairs) in SEED.items():
        cur.execute("INSERT OR IGNORE INTO groups(slug,label_en) VALUES (?,?)", (slug, label))
        cur.execute("SELECT id FROM groups WHERE slug=?", (slug,))
        gid = cur.fetchone()[0]
        stats["groups"] += 1
        for surf, clue in pairs:
            gf = grid_form(surf)
            z = zipf_frequency(surf, "en")
            diff = difficulty_tier(z, len(gf))
            cur.execute(
                "INSERT OR IGNORE INTO words"
                "(language,surface,grid_form,grid_len,zipf,difficulty,is_concat)"
                " VALUES ('en',?,?,?,?,?,0)",
                (surf, gf, len(gf), z, diff),
            )
            cur.execute("SELECT id FROM words WHERE language='en' AND surface=?", (surf,))
            wid = cur.fetchone()[0]
            stats["seed_words"] += 1
            cur.execute("INSERT OR IGNORE INTO word_groups(word_id,group_id) VALUES (?,?)", (wid, gid))

            verdict = validate_clue(surf, clue, "en")
            if verdict.ok:
                cur.execute(
                    "INSERT OR IGNORE INTO clues(word_id,language,text,source,validated)"
                    " VALUES (?,?,?,?,1)", (wid, "en", clue, "seed"))
                stats["clues_ok"] += 1
            else:
                stats["clues_rejected"] += 1
                rejected.append((surf, "; ".join(verdict.reasons)))
    con.commit()
    if rejected:
        print("\n  Seed clues rejected by harness (fix these):")
        for surf, why in rejected:
            print(f"    - {surf}: {why}")
    return stats


def write_meta(con, inv_counts, seed_stats):
    cur = con.cursor()
    cur.execute("SELECT COUNT(*) FROM words"); total_words = cur.fetchone()[0]
    cur.execute("SELECT COUNT(*) FROM clues"); total_clues = cur.fetchone()[0]
    meta = {
        "schema_version": "1",
        "grid_alphabet": "A-Z",
        "languages": ",".join(l for l, c in inv_counts.items() if c),
        "languages_missing_in_wordfreq": "hr,et",
        "total_words": str(total_words),
        "total_clues": str(total_clues),
        "free_tier_language": "en",
    }
    for k, v in meta.items():
        cur.execute("INSERT OR REPLACE INTO meta(key,value) VALUES (?,?)", (k, v))
    con.commit()
    return total_words, total_clues


def main():
    con = fresh_db()
    print("Loading word inventories (wordfreq -> A-Z gridForm)...")
    inv = load_word_inventories(con)
    print("Loading validated English seed...")
    seed = load_english_seed(con)
    print("Loading validated multilingual seed (nl/de/fr/es/it)...")
    multi = load_multi_seed(con)
    tw, tc = write_meta(con, inv, seed)

    print("\n=== WORD INVENTORY (real, per language) ===")
    for lang in TARGET_LANGS:
        print(f"  {lang:3} {inv.get(lang,0):>6} words")
    print("  hr      0 words  (no wordfreq data -> pipeline only)")
    print("  et      0 words  (no wordfreq data -> pipeline only)")

    print("\n=== ENGLISH SEED (validated clues) ===")
    print(f"  themes           : {seed['groups']}")
    print(f"  seed words       : {seed['seed_words']}")
    print(f"  clues accepted   : {seed['clues_ok']}")
    print(f"  clues rejected   : {seed['clues_rejected']}")

    print(f"\n=== TOTALS ===\n  words: {tw}   clues: {tc}")
    print("  validated clues by language:")
    cur = con.execute("SELECT language, COUNT(*) FROM clues WHERE validated=1 "
                      "GROUP BY language ORDER BY COUNT(*) DESC")
    for lang, n in cur.fetchall():
        print(f"    {lang}: {n}")
    print(f"  db: {DB}  ({os.path.getsize(DB)//1024} KB)")
    con.close()


if __name__ == "__main__":
    main()
