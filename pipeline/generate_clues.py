"""
generate_clues.py
Scales clues to the 100-group x 100-word target, per language, on YOUR endpoint.

This is the real "spawn subshells" lever: --workers fans out concurrent requests to
an OpenAI-compatible endpoint (SGLang/vLLM) so you saturate your GPUs. Every clue is
gated by tessera_content.validate_clue; rejects get ONE retry with the reason fed back.

  export TESSERA_BASE_URL="http://localhost:30000/v1"
  export TESSERA_MODEL="your-open-weight-model"
  export TESSERA_API_KEY=""        # blank for local SGLang

  python3 generate_clues.py --lang nl --workers 16 --limit 1000
  python3 generate_clues.py --lang de --theme cinema --workers 8
  python3 generate_clues.py --lang fr --dry-run
"""
from __future__ import annotations
import argparse, json, os, sqlite3, sys, urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "content"))  # share the one validator
from tessera_content import validate_clue

DB = os.path.join(HERE, "..", "content", "tessera.sqlite")
BASE_URL = os.environ.get("TESSERA_BASE_URL", "http://localhost:30000/v1")
MODEL    = os.environ.get("TESSERA_MODEL", "open-weight-model")
API_KEY  = os.environ.get("TESSERA_API_KEY", "")

LANG_NAME = {
    "en":"English","nl":"Dutch","de":"German","fr":"French","es":"Spanish","it":"Italian",
}

PROMPT = """You write crossword clues in {language}.
Rules, strictly:
- Write ONE clue for the answer word below, in {language}.
- The clue MUST NOT contain the answer, any part of it, or a close cognate.
- 3-12 words. A definition or description, not wordplay.
- No quotation marks, no trailing punctuation, no preamble.{feedback}
Answer: {word}
Clue:"""


def chat(prompt: str) -> str:
    body = json.dumps({
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0.7, "max_tokens": 60,
    }).encode()
    req = urllib.request.Request(BASE_URL.rstrip("/") + "/chat/completions",
                                data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    if API_KEY:
        req.add_header("Authorization", f"Bearer {API_KEY}")
    with urllib.request.urlopen(req, timeout=60) as r:
        data = json.loads(r.read())
    return data["choices"][0]["message"]["content"].strip()


def generate_one(wid: int, surface: str, language: str, lang_code: str):
    """Generate + validate, with one feedback retry. Returns (wid, clue) or None."""
    feedback = ""
    for attempt in range(2):
        try:
            raw = chat(PROMPT.format(language=language, word=surface, feedback=feedback))
        except Exception as e:
            sys.stderr.write(f"  endpoint error '{surface}': {e}\n")
            return None
        clue = raw.splitlines()[0].strip().strip('"').rstrip(".")
        verdict = validate_clue(surface, clue, lang_code)
        if verdict.ok:
            return (wid, clue)
        feedback = f"\n- Your previous try failed: {'; '.join(verdict.reasons)}. Fix it."
    return None


def words_needing_clues(con, lang, theme, limit):
    q = ("SELECT w.id, w.surface FROM words w WHERE w.language=? AND NOT EXISTS "
         "(SELECT 1 FROM clues c WHERE c.word_id=w.id AND c.validated=1)")
    args = [lang]
    if theme:
        q += (" AND w.id IN (SELECT word_id FROM word_groups wg JOIN groups g "
              "ON g.id=wg.group_id WHERE g.slug=?)")
        args.append(theme)
    q += " ORDER BY w.zipf DESC LIMIT ?"
    args.append(limit)
    return con.execute(q, args).fetchall()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lang", required=True)
    ap.add_argument("--theme", default=None)
    ap.add_argument("--limit", type=int, default=100)
    ap.add_argument("--workers", type=int, default=8, help="concurrent endpoint requests")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    language = LANG_NAME.get(a.lang, a.lang)
    con = sqlite3.connect(DB)
    todo = words_needing_clues(con, a.lang, a.theme, a.limit)
    print(f"{len(todo)} {language} words need a validated clue"
          + (f" in '{a.theme}'" if a.theme else "")
          + f"; fanning out across {a.workers} workers")
    if a.dry_run:
        print(f"[dry-run] endpoint={BASE_URL} model={MODEL}; nothing called/written.")
        return

    accepted = 0
    with ThreadPoolExecutor(max_workers=a.workers) as pool:
        futures = [pool.submit(generate_one, wid, surf, language, a.lang)
                   for wid, surf in todo]
        for fut in as_completed(futures):
            res = fut.result()
            if res:
                wid, clue = res
                con.execute("INSERT OR IGNORE INTO clues(word_id,language,text,source,validated)"
                            " VALUES (?,?,?,?,1)", (wid, a.lang, clue, "llm"))
                accepted += 1
    con.commit()
    total = len(todo)
    print(f"accepted {accepted}/{total} after retry "
          f"({100*accepted/max(1,total):.0f}% landed); rest need another pass or review")
    con.close()


if __name__ == "__main__":
    main()
