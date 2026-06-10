"""
Tessera grid generator — proof-of-assembly prototype (Python).

Goal: prove that a *clued* crossword grid can be assembled drawing ONLY from
themed words that have a clue (no unclued wordfreq filler), with every maximal
letter-run being an intentional, clued entry. Crossings match on grid_form
(the A-Z canonical key), so mixed-language grids interlock naturally.

This is the load-bearing algorithm. It will later be ported to Swift; here it
is runnable so we can measure: does it fill, how dense, how fast, how brittle.

Approach: free-form interlocking placement with the standard no-incidental-word
rule (new non-crossing cells must have empty perpendicular neighbours; word ends
must be clear). Greedy placement maximising crossings, with random restarts;
keep the best grid. This is sufficient to demonstrate feasibility and measure
achievable density without solving the separate (and harder) symmetric-skeleton
aesthetic problem.
"""
import sqlite3, random, time, argparse
from collections import defaultdict

H, V = 0, 1  # orientations


def load_pool(conn, languages, min_len=3, max_len=11):
    """One clued entry per word_id: (grid_form, surface, language, clue)."""
    qmarks = ",".join("?" * len(languages))
    rows = conn.execute(f"""
        SELECT w.grid_form, w.surface, w.language, cl.text
        FROM words w
        JOIN clues cl ON cl.word_id = w.id
        WHERE w.language IN ({qmarks}) AND w.grid_len BETWEEN ? AND ?
        GROUP BY w.id
    """, (*languages, min_len, max_len)).fetchall()
    # de-dup by grid_form (a grid can't contain the same key twice); keep first
    seen, pool = set(), []
    for gf, surf, lang, clue in rows:
        if gf in seen:
            continue
        seen.add(gf)
        pool.append((gf, surf, lang, clue))
    return pool


class Grid:
    def __init__(self):
        self.cells = {}            # (r,c) -> letter
        self.entries = []          # dicts: gf, surface, language, clue, r, c, orient
        self.used_gf = set()

    def letter(self, r, c):
        return self.cells.get((r, c))

    def bounds(self):
        rs = [r for r, _ in self.cells]; cs = [c for _, c in self.cells]
        return min(rs), max(rs), min(cs), max(cs)

    def legal(self, gf, r, c, orient, max_dim):
        """Can word `gf` be placed starting at (r,c) in orient? Returns #crossings or -1."""
        dr, dc = (0, 1) if orient == H else (1, 0)
        pdr, pdc = (1, 0) if orient == H else (0, 1)  # perpendicular
        n = len(gf)
        cells = [(r + dr * i, c + dc * i) for i in range(n)]
        # cell before head and after tail must be empty (don't extend a word)
        before = (r - dr, c - dc); after = (r + dr * n, c + dc * n)
        if self.letter(*before) is not None: return -1
        if self.letter(*after) is not None: return -1
        crossings = 0
        for i, (rr, cc) in enumerate(cells):
            cur = self.letter(rr, cc)
            if cur is not None:
                if cur != gf[i]: return -1      # conflicting letter
                crossings += 1                   # valid crossing
            else:
                # non-crossing new cell: perpendicular neighbours must be empty
                if self.letter(rr + pdr, cc + pdc) is not None: return -1
                if self.letter(rr - pdr, cc - pdc) is not None: return -1
        if self.cells and crossings == 0: return -1   # must interlock
        # bounding-box / max dimension guard
        rs = [rr for rr, _ in cells] + [r0 for r0, _ in self.cells]
        cs = [cc for _, cc in cells] + [c0 for _, c0 in self.cells]
        if (max(rs) - min(rs)) >= max_dim or (max(cs) - min(cs)) >= max_dim:
            return -1
        return crossings

    def place(self, entry, r, c, orient):
        gf = entry[0]
        dr, dc = (0, 1) if orient == H else (1, 0)
        for i, ch in enumerate(gf):
            self.cells[(r + dr * i, c + dc * i)] = ch
        self.entries.append(dict(gf=gf, surface=entry[1], language=entry[2],
                                 clue=entry[3], r=r, c=c, orient=orient))
        self.used_gf.add(gf)


def build(pool, target_words, max_dim, rng, attempts_per_step=400):
    by_letter = defaultdict(list)  # letter -> list of (entry, pos)
    for e in pool:
        for pos, ch in enumerate(e[0]):
            by_letter[ch].append((e, pos))

    g = Grid()
    seed = rng.choice([e for e in pool if 5 <= len(e[0]) <= 7] or pool)
    g.place(seed, 0, 0, H)

    stalls = 0
    while len(g.entries) < target_words and stalls < 60:
        placed = False
        # candidate anchor cells in random order
        anchor_cells = list(g.cells.items()); rng.shuffle(anchor_cells)
        best = None  # (crossings, entry, r, c, orient)
        tried = 0
        for (ar, ac), aletter in anchor_cells:
            for entry, pos in by_letter.get(aletter, ()):
                if entry[0] in g.used_gf: continue
                tried += 1
                if tried > attempts_per_step: break
                for orient in (H, V):
                    dr, dc = (0, 1) if orient == H else (1, 0)
                    r, c = ar - dr * pos, ac - dc * pos
                    x = g.legal(entry[0], r, c, orient, max_dim)
                    if x > 0 and (best is None or x > best[0]):
                        best = (x, entry, r, c, orient)
            if tried > attempts_per_step: break
        if best:
            _, entry, r, c, orient = best
            g.place(entry, r, c, orient); placed = True
        if not placed:
            stalls += 1
        else:
            stalls = 0
    return g


def generate(conn, languages, target_words=28, max_dim=15, restarts=200, seed=None):
    pool = load_pool(conn, languages)
    rng = random.Random(seed)
    t0 = time.time()
    best = None
    for _ in range(restarts):
        g = build(pool, target_words, max_dim, rng)
        if best is None or len(g.entries) > len(best.entries):
            best = g
            if len(best.entries) >= target_words:
                break
    dt = time.time() - t0
    return best, pool, dt


def render(g):
    r0, r1, c0, c1 = g.bounds()
    out = []
    for r in range(r0, r1 + 1):
        out.append("".join((g.letter(r, c) or "·") for c in range(c0, c1 + 1)))
    return "\n".join(out)


def stats(g):
    r0, r1, c0, c1 = g.bounds()
    box = (r1 - r0 + 1) * (c1 - c0 + 1)
    langs = defaultdict(int)
    for e in g.entries: langs[e["language"]] += 1
    return dict(words=len(g.entries), rows=r1 - r0 + 1, cols=c1 - c0 + 1,
                filled=len(g.cells), box=box,
                density=round(len(g.cells) / box, 2), by_lang=dict(langs))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default="../content/tessera.sqlite")
    ap.add_argument("--langs", default="en")
    ap.add_argument("--target", type=int, default=28)
    ap.add_argument("--max-dim", type=int, default=15)
    ap.add_argument("--restarts", type=int, default=200)
    ap.add_argument("--seed", type=int, default=None)
    a = ap.parse_args()
    conn = sqlite3.connect(a.db)
    langs = a.langs.split(",")
    g, pool, dt = generate(conn, langs, a.target, a.max_dim, a.restarts, a.seed)
    s = stats(g)
    print(f"langs={langs} pool={len(pool)} time={dt:.2f}s")
    print(f"placed={s['words']}/{a.target}  grid={s['rows']}x{s['cols']}  "
          f"filled={s['filled']}  density={s['density']}  by_lang={s['by_lang']}")
    print(render(g))
    print("\nfirst 8 entries (clue -> answer [lang]):")
    for e in g.entries[:8]:
        d = "across" if e["orient"] == H else "down"
        print(f"  [{d:6}] {e['clue']}  ->  {e['surface']} [{e['language']}]")


def verify_no_incidental(g):
    """Every maximal run of >=2 cells (H and V) must be a placed entry's grid_form.
    Catches accidental unintended words — a silent correctness bug if present."""
    placed = {(e["r"], e["c"], e["orient"], e["gf"]) for e in g.entries}
    placed_gf = {e["gf"] for e in g.entries}
    bad = []
    r0, r1, c0, c1 = g.bounds()
    # horizontal runs
    for r in range(r0, r1 + 1):
        c = c0
        while c <= c1:
            if g.letter(r, c) is None:
                c += 1; continue
            s = c
            while c <= c1 and g.letter(r, c) is not None:
                c += 1
            run = "".join(g.letter(r, k) for k in range(s, c))
            if len(run) >= 2 and run not in placed_gf:
                bad.append(("H", r, s, run))
    # vertical runs
    for c in range(c0, c1 + 1):
        r = r0
        while r <= r1:
            if g.letter(r, c) is None:
                r += 1; continue
            s = r
            while r <= r1 and g.letter(r, c) is not None:
                r += 1
            run = "".join(g.letter(k, c) for k in range(s, r))
            if len(run) >= 2 and run not in placed_gf:
                bad.append(("V", s, c, run))
    return bad
