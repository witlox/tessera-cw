"""
tessera_content.py
Shared content-layer logic for Tessera (a multilingual clued-crossword game).

This module is the single source of truth for:
  - gridForm normalization (any Latin-script European word -> A-Z grid letters)
  - per-language concatenation policy
  - difficulty estimation
  - the clue VALIDATION HARNESS (the real IP: leakage / triviality / uniqueness checks)

Both the content builder and the LLM clue pipeline import from here so the rules
that govern on-device grids and the rules that govern generated clues can never drift.
"""

from __future__ import annotations
import unicodedata
import re
from dataclasses import dataclass, field
from typing import Optional

# ---------------------------------------------------------------------------
# 1. gridForm normalization  (surface spelling -> A-Z crossing letters)
# ---------------------------------------------------------------------------
# Letters that do NOT decompose under NFKD must be mapped explicitly.
# These are the genuinely awkward ones across the Latin-script European set.
_EXPLICIT_MAP = {
    "ß": "SS", "ẞ": "SS",
    "ł": "L",  "Ł": "L",
    "ø": "O",  "Ø": "O",
    "đ": "D",  "Đ": "D",
    "ð": "D",  "Ð": "D",
    "þ": "TH", "Þ": "TH",   # Icelandic thorn
    "æ": "AE", "Æ": "AE",
    "œ": "OE", "Œ": "OE",
    "ı": "I",                # dotless i (not in target set, defensive)
}


def grid_form(surface: str) -> str:
    """Fold a surface word to its A-Z grid representation.

    Strategy: explicit map for non-decomposable glyphs, then NFKD + strip combining
    marks for the accented-vowel majority, then uppercase, then keep only A-Z.

    Note the deliberate, documented casualty: Spanish n-tilde folds to N, so
    'ano'/'ano' (year / anus) collide. Accepted for casual play; see BLOCKLIST hook.
    """
    out = []
    for ch in surface:
        if ch in _EXPLICIT_MAP:
            out.append(_EXPLICIT_MAP[ch])
        else:
            out.append(ch)
    s = "".join(out)
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c))
    s = s.upper()
    s = re.sub(r"[^A-Z]", "", s)
    return s


# ---------------------------------------------------------------------------
# 2. Per-language concatenation policy
# ---------------------------------------------------------------------------
# Whether forced 2-word concatenation reads naturally, plus a sane max grid length.
# Germanic + Finno-Ugric compound natively; Romance does not.
@dataclass(frozen=True)
class ConcatPolicy:
    allow_concat: bool
    max_grid_len: int
    note: str


CONCAT_POLICY: dict[str, ConcatPolicy] = {
    # Germanic / Nordic: native compounding, allow long entries
    "en": ConcatPolicy(True, 15, "compounds common"),
    "nl": ConcatPolicy(True, 18, "native compounding (woordsamenstelling)"),
    "de": ConcatPolicy(True, 22, "heavy native compounding"),
    "sv": ConcatPolicy(True, 18, "native compounding"),
    "da": ConcatPolicy(True, 18, "native compounding"),
    "nb": ConcatPolicy(True, 18, "native compounding"),
    "is": ConcatPolicy(True, 18, "native compounding"),
    # Finno-Ugric: agglutinative, long words natural
    "fi": ConcatPolicy(True, 24, "agglutinative; very long forms natural"),
    "hu": ConcatPolicy(True, 22, "agglutinative; long forms natural"),
    # Romance: particle constructions, concatenation reads unnatural -> restrict
    "fr": ConcatPolicy(False, 13, "uses particles; avoid forced concat"),
    "es": ConcatPolicy(False, 13, "uses particles; avoid forced concat"),
    "it": ConcatPolicy(False, 13, "uses particles; avoid forced concat"),
    "ro": ConcatPolicy(False, 14, "uses particles; avoid forced concat"),
    # Slavic + Baltic (Latin-script): moderate; allow but conservative length
    "pl": ConcatPolicy(False, 15, "limited productive compounding"),
    "cs": ConcatPolicy(False, 15, "limited productive compounding"),
    "sk": ConcatPolicy(False, 15, "limited productive compounding"),
    "sl": ConcatPolicy(False, 15, "limited productive compounding"),
    "lv": ConcatPolicy(False, 15, "limited productive compounding"),
    "lt": ConcatPolicy(False, 16, "limited productive compounding"),
}


def policy_for(lang: str) -> ConcatPolicy:
    return CONCAT_POLICY.get(lang, ConcatPolicy(False, 14, "default conservative"))


# ---------------------------------------------------------------------------
# 3. Difficulty estimation  (frequency + length -> tier)
# ---------------------------------------------------------------------------
def difficulty_tier(zipf: float, grid_len: int) -> str:
    """Rough, intentionally simple. zipf: ~7 very common, ~3 rare.
    Real grading needs solve-time telemetry; this is a defensible cold-start prior."""
    score = (7.0 - zipf) + max(0, grid_len - 5) * 0.4
    if score < 2.0:
        return "easy"
    if score < 4.0:
        return "medium"
    return "hard"


# ---------------------------------------------------------------------------
# 4. CLUE VALIDATION HARNESS  -- the part that actually determines quality
# ---------------------------------------------------------------------------
@dataclass
class ClueVerdict:
    ok: bool
    reasons: list[str] = field(default_factory=list)

    def fail(self, r: str) -> "ClueVerdict":
        self.ok = False
        self.reasons.append(r)
        return self


# Offensive SURFACES we won't include as answers (extend per language).
# NB: block the surface, not the gridform -- folding 'año'(year) and 'ano'(anus) both
# give ANO, so a gridform block would wrongly kill the common, innocent 'año'.
BLOCKLIST_SURFACES = {"ano"}

_STOPWORDS = {
    "the", "a", "an", "of", "to", "in", "on", "for", "and", "or", "is", "it",
    "that", "this", "with", "as", "by", "at", "from",
}


def validate_clue(answer_surface: str, clue: str, lang: str,
                  min_words: int = 1, max_words: int = 18) -> ClueVerdict:
    """Reject the failure modes flagged in design: leakage, triviality, blocklist.

    NOT a uniqueness oracle -- true uniqueness needs a grid-aware solver pass.
    This catches the cheap, high-frequency LLM failures before human/solver review.
    """
    v = ClueVerdict(ok=True)
    ans = answer_surface.strip()
    if not clue or not clue.strip():
        return v.fail("empty clue")

    clue_norm = grid_form(clue)
    ans_grid = grid_form(ans)

    # blocklist (offensive surfaces only -- never block an innocent homograph)
    if ans.lower() in BLOCKLIST_SURFACES:
        v.fail(f"answer surface '{ans}' on blocklist")

    # exact echo
    if clue.strip().lower() == ans.lower():
        v.fail("clue equals answer")

    # direct leakage: answer (folded) appears inside clue (folded)
    if ans_grid and ans_grid in clue_norm:
        v.fail("answer string leaks into clue")

    # stem leakage: shared >=4-char prefix between answer and any clue token
    tokens = re.findall(r"[^\W\d_]+", clue.lower(), flags=re.UNICODE)
    ans_low = ans.lower()
    for t in tokens:
        tg, ag = grid_form(t), grid_form(ans_low)
        if len(tg) >= 4 and len(ag) >= 4:
            common = _common_prefix(tg, ag)
            if common >= 4 and (common >= 0.6 * len(ag)):
                v.fail(f"stem leakage via '{t}'")
                break

    # word-count sanity
    wc = len(tokens)
    if wc < min_words:
        v.fail("clue too short")
    if wc > max_words:
        v.fail("clue too long")

    # triviality: clue is a single stopword / trivial pointer
    if wc == 1 and tokens and tokens[0] in _STOPWORDS:
        v.fail("trivial single-stopword clue")

    return v


def _common_prefix(a: str, b: str) -> int:
    n = 0
    for x, y in zip(a, b):
        if x != y:
            break
        n += 1
    return n


if __name__ == "__main__":
    # quick self-test of the normalizer across the awkward cases
    cases = [
        ("Straße", "STRASSE"), ("Łódź", "LODZ"), ("Þór", "THOR"),
        ("cœur", "COEUR"), ("año", "ANO"), ("naïve", "NAIVE"),
        ("Reykjavík", "REYKJAVIK"), ("kärlek", "KARLEK"), ("piękny", "PIEKNY"),
    ]
    for surf, exp in cases:
        got = grid_form(surf)
        print(f"{surf:12} -> {got:10} {'OK' if got==exp else 'EXPECTED '+exp}")
