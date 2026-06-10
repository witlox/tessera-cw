"""
validate_clues.py
Run the harness as a standalone audit -- over the DB, or over a TSV of (word<TAB>clue).

  python3 validate_clues.py --audit-db --lang en
  python3 validate_clues.py --file my_clues.tsv --lang nl
"""
from __future__ import annotations
import argparse, os, sqlite3, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "content"))
from tessera_content import validate_clue

DB = os.path.join(HERE, "..", "content", "tessera.sqlite")


def audit_db(lang):
    con = sqlite3.connect(DB)
    rows = con.execute(
        "SELECT w.surface, c.text FROM clues c JOIN words w ON w.id=c.word_id "
        "WHERE c.language=?", (lang,)).fetchall()
    bad = 0
    for surf, clue in rows:
        v = validate_clue(surf, clue, lang)
        if not v.ok:
            bad += 1
            print(f"  FAIL {surf}: {'; '.join(v.reasons)}  ::  {clue}")
    print(f"audited {len(rows)} {lang} clues, {bad} would now fail the harness")
    con.close()


def audit_file(path, lang):
    ok = bad = 0
    with open(path, encoding="utf-8") as f:
        for line in f:
            if "\t" not in line:
                continue
            surf, clue = line.rstrip("\n").split("\t", 1)
            v = validate_clue(surf, clue, lang)
            if v.ok:
                ok += 1
            else:
                bad += 1
                print(f"  FAIL {surf}: {'; '.join(v.reasons)}")
    print(f"{ok} ok, {bad} failed")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--audit-db", action="store_true")
    ap.add_argument("--file")
    ap.add_argument("--lang", default="en")
    a = ap.parse_args()
    if a.audit_db:
        audit_db(a.lang)
    elif a.file:
        audit_file(a.file, a.lang)
    else:
        ap.error("give --audit-db or --file")


if __name__ == "__main__":
    main()
