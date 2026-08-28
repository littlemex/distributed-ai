#!/usr/bin/env python3
"""Pin the summarisation metric's thresholds to controls, and refuse a metric that cannot separate them.

The first version of this family's scorer was inverted: the document's own opening scored higher than the
human reference summary, because the way to pass was to write no numbers of your own. A layer scored 0.887
on it. Nothing in the code was broken — the thresholds had simply never been asked whether the best
possible answer could satisfy them.

So this is the gate the family's thresholds have to pass, and it runs on the real items rather than a
fixture, because the reference summaries' habit of rounding figures is the thing that broke v1 and a
synthetic document does not have that habit.

The controls, and what each one is for:

* `ceiling_gold_300w` — the reference cut to the 300 words the prompt asks for. The best answer that
  exists under the instruction given, so it is the metric's headroom. Must mostly pass.
* `ceiling_gold_full` — the whole reference, which is longer than the instruction allows.
* `ceiling_best_300w` — reference sentences greedily chosen to maximise atom coverage in 300 words. The
  *best achievable* selection rather than a truncation policy, so it separates "the floor is too high"
  from "the reference happens not to front-load".
* `diag_gold_last300w` — the reference's closing 300 words, which quantifies how much a valid but
  back-loading selection is penalised by a floor calibrated on a front-loading one.
* `diag_paraphrase` — the ceiling with entities written in the form the document declared equal
  ("DHS" for "Department of Homeland Security") and figures rescaled ("$1.4 billion" for "1,432 million").
  An abstractive layer does this, so a drop here is the matcher being string-brittle, which is the exact
  defect the numeric tolerance was added to fix. Must stay level with the ceiling.
* `neg_lead_300w` — the document's first 300 words. Extractive, not a summary. Must mostly fail.
* `neg_fabricated` — the ceiling with every figure multiplied by 1.07. As fluent and as complete as the
  ceiling, and differs only in being false. Must mostly fail.
* `neg_wrong_document` — another report's reference summary. Must fail almost always; if it passes, the
  metric is recognising the genre rather than the document.
* `neg_atom_soup` — the document's own atoms listed without prose. Tests whether coverage alone passes.
* `neg_number_shuffle` — the ceiling with its figures permuted among their slots. Every figure is
  supported, every atom present, and every claim wrong. **This is a measurement, not a gate**: a
  bag-of-atoms metric cannot fail it, and both advisors said so independently. It is here to keep the size
  of that blind spot in the record instead of in a footnote.
"""

from __future__ import annotations

import argparse
import json
import random
import re
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from benchctl.tasks.summarise_facts import (  # noqa: E402
    _ALIAS_DEF, _NUM, _atoms, _norm_number, Item, SummariseFacts,
)

# A gate is a control whose rate the thresholds are answerable for. Blind spots are reported, not gated.
#
# The ceiling that binds is the *best achievable* 300-word selection, not the reference truncated at 300
# words: truncation is a policy a good summariser would not use, and gating on it at 0.85 left exactly two
# admissible cells in the whole threshold grid — which is a metric balanced on a point. The truncation is
# still gated, lower, because a plain truncation of the human summary failing outright would mean the floor
# had stopped being about content.
GATES = {
    "ceiling_best_300w": (0.85, 1.00),
    "ceiling_gold_300w": (0.75, 1.00),
    "neg_lead_300w": (0.00, 0.20),
    "neg_fabricated": (0.00, 0.20),
    "neg_wrong_document": (0.00, 0.10),
}

# The region lives on the task, not here: it is a property of the calibrated metric, and `benchctl score`
# needs it too. This script is what proves the region is admissible; the metric is what carries it.
ADMISSIBLE = SummariseFacts.admissible_thresholds
REPORT_ONLY = ("ceiling_gold_full", "diag_gold_last300w", "diag_paraphrase",
               "neg_atom_soup", "neg_number_shuffle", "neg_random_window",
               "probe_random_numbers", "edge_empty", "edge_terse_50w")


def _words(text: str, n: int, *, last: bool = False) -> str:
    parts = text.split()
    return " ".join(parts[-n:] if last else parts[:n])


def _sentences(text: str) -> list[str]:
    return [s.strip() for s in re.split(r"(?<=[.!?])\s+", text) if s.strip()]


def _best_300(reference: str) -> str:
    """Reference sentences greedily chosen for atom coverage within the word budget.

    Sentences are kept in their original order once chosen, so the result reads as prose rather than as a
    ranking — the point of this control is a *better selection*, not a different genre.
    """
    def atom_set(text: str) -> set[str]:
        a = _atoms(text)
        return set(a["numbers"]) | set(a["acronyms"]) | set(a["proper"])

    wanted = atom_set(reference)
    sentences = _sentences(reference)
    chosen: list[int] = []
    covered: set[str] = set()
    budget = 300
    while True:
        best, best_key = None, (0, 0.0)
        for i, s in enumerate(sentences):
            if i in chosen:
                continue
            length = len(s.split())
            if length > budget or length == 0:
                continue
            new = len(atom_set(s) & wanted - covered)
            # Density, so a long sentence has to earn its words rather than win on volume alone.
            key = (new, new / length)
            if new > 0 and key > best_key:
                best, best_key = i, key
        if best is None:
            break
        chosen.append(best)
        covered |= atom_set(sentences[best]) & wanted
        budget -= len(sentences[best].split())
    if not chosen:
        return _words(reference, 300)
    return " ".join(sentences[i] for i in sorted(chosen))


def _scale_numbers(text: str) -> str:
    """Rewrite figures the way an abstractive summary does: fewer digits, a unit word."""
    def rep(match: re.Match) -> str:
        try:
            value = float(_norm_number(match.group(0)))
        except ValueError:
            return match.group(0)
        for size, unit in ((1e9, "billion"), (1e6, "million"), (1e3, "thousand")):
            if abs(value) >= size:
                return f"{value / size:.1f} {unit}"
        return match.group(0)
    return _NUM.sub(rep, text)


def _swap_entities(text: str, document: str) -> str:
    """Use the other surface form for every entity the document itself defined."""
    out = text
    for expansion, acronym in _ALIAS_DEF.findall(document):
        expansion = expansion.strip()
        if len(expansion) < 4:
            continue
        out = re.sub(re.escape(expansion), acronym, out)
    return out


def _perturb(text: str, factor: float = 1.07) -> str:
    def rep(match: re.Match) -> str:
        try:
            value = float(_norm_number(match.group(0)))
        except ValueError:
            return match.group(0)
        return f"{value * factor:.4g}"
    return _NUM.sub(rep, text)


def _shuffle_numbers(text: str, rng: random.Random) -> str:
    found = _NUM.findall(text)
    if len(found) < 2:
        return text
    pool = found[:]
    rng.shuffle(pool)
    it = iter(pool)
    return _NUM.sub(lambda m: next(it, m.group(0)), text)


def _random_numbers(text: str, rng: random.Random) -> str:
    """Every figure replaced by an unrelated one, at a magnitude drawn independently.

    The probe that bounds the fabrication check: the support rule allows any document number under any of
    nine rescalings, rounded to the candidate's own precision, so a candidate writing "about 3" is supported
    by a document containing 0.31, 29 or 3,100. The fraction of *random* numbers this rule accepts is the
    matcher's false-support rate, and no fabrication the rule can catch is smaller than it.
    """
    def rep(match: re.Match) -> str:
        magnitude = rng.choice((1, 10, 100, 1_000, 100_000, 10_000_000))
        return f"{rng.uniform(1, 9.99) * magnitude:.4g}"
    return _NUM.sub(rep, text)


def _mid_window(document: str, words: int = 300) -> str:
    """A contiguous window from the middle, because a report's first 300 words are its own summary."""
    parts = document.split()
    start = max(0, len(parts) // 2 - words // 2)
    return " ".join(parts[start:start + words])


def _atom_soup(document: str) -> str:
    a = _atoms(document)
    parts = a["proper"][:120] + a["acronyms"][:40] + a["numbers"][:120]
    return _words("; ".join(parts), 300)


def build_controls(rows: list[dict], rng: random.Random) -> dict[str, list[str]]:
    out: dict[str, list[str]] = {}
    out["ceiling_gold_full"] = [r["reference"] for r in rows]
    out["ceiling_gold_300w"] = [_words(r["reference"], 300) for r in rows]
    out["ceiling_best_300w"] = [_best_300(r["reference"]) for r in rows]
    out["diag_gold_last300w"] = [_words(r["reference"], 300, last=True) for r in rows]
    out["diag_paraphrase"] = [_scale_numbers(_swap_entities(_words(r["reference"], 300), r["document"]))
                              for r in rows]
    out["neg_lead_300w"] = [_words(r["document"], 300) for r in rows]
    out["neg_fabricated"] = [_perturb(_words(r["reference"], 300)) for r in rows]
    out["neg_wrong_document"] = [_words(rows[(i + 1) % len(rows)]["reference"], 300)
                                 for i, _ in enumerate(rows)]
    out["neg_atom_soup"] = [_atom_soup(r["document"]) for r in rows]
    out["neg_number_shuffle"] = [_shuffle_numbers(_words(r["reference"], 300), rng) for r in rows]
    out["neg_random_window"] = [_mid_window(r["document"]) for r in rows]
    out["probe_random_numbers"] = [_random_numbers(_words(r["reference"], 300), rng) for r in rows]
    out["edge_empty"] = ["" for _ in rows]
    out["edge_terse_50w"] = [_words(r["reference"], 50) for r in rows]
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--items", type=Path, required=True)
    ap.add_argument("--limit", type=int, default=None)
    ap.add_argument("--seed", type=int, default=20260828)
    ap.add_argument("--band", action="store_true",
                    help="also sweep a band of thresholds, to show whether the decision is a point")
    ap.add_argument("--json-out", type=Path, default=None)
    a = ap.parse_args()

    rows = [json.loads(line) for line in a.items.read_text().split("\n") if line.strip()]
    if a.limit:
        rows = rows[: a.limit]
    items = [Item(id=str(r["id"]), document=r["document"], reference=r["reference"],
                  doc_chars=len(r["document"]), length_bin=r.get("length_bin")) for r in rows]

    task = SummariseFacts.__new__(SummariseFacts)
    controls = build_controls(rows, random.Random(a.seed))

    # Measure once per control, threshold many times: the thresholds are what is under test.
    measured = {name: [task.measure(item, cand) for item, cand in zip(items, cands)]
                for name, cands in controls.items()}

    def rate(ms: list[dict]) -> float:
        return sum(1 for m in ms if not task.verdict_reasons(m) and m["key_fact_recall"] is not None) / len(ms)

    print(f"items {len(items)}   thresholds: recall >= {task.recall_floor}, unsupported share <= "
          f"{task.unsupported_share:g} once {task.unsupported_dense_n}+ written "
          f"({task.unsupported_grace} forgiven), "
          f"compression <= {task.max_compression}\n")
    print(f"{'control':22} {'pass':>6} {'recall':>7} {'numeric':>8} {'unsup':>6} {'written':>8} "
          f"{'compress':>9} {'prose':>6}  verdict")
    results, failures = {}, []
    for name in list(GATES) + list(REPORT_ONLY):
        ms = measured[name]
        r = rate(ms)
        results[name] = r
        med = lambda k: statistics.median((m[k] or 0) for m in ms)  # noqa: E731
        verdict = ""
        if name in GATES:
            lo, hi = GATES[name]
            ok = lo <= r <= hi
            verdict = "OK" if ok else f"OUT of [{lo:.2f}, {hi:.2f}]"
            if not ok:
                failures.append(f"{name} = {r:.2f}, required in [{lo:.2f}, {hi:.2f}]")
        else:
            verdict = "reported, not gated"
        print(f"{name:22} {r:6.2f} {med('key_fact_recall'):7.3f} {med('numeric_recall'):8.3f} "
              f"{med('unsupported_count'):6.0f} {med('numbers_emitted'):8.0f} "
              f"{med('compression'):9.3f} {med('function_word_rate'):6.2f}  {verdict}")

    def unsupported_share(ms: list[dict]) -> list[float]:
        return [m["unsupported_count"] / m["numbers_emitted"]
                for m in ms if m["numbers_emitted"] >= 4]

    print("\nunsupported share U/N, which is what the fabrication budget is a threshold on:")
    for name in ("ceiling_gold_300w", "ceiling_best_300w", "neg_fabricated", "probe_random_numbers"):
        shares = sorted(unsupported_share(measured[name]))
        if not shares:
            continue
        pct = lambda q: shares[min(len(shares) - 1, int(q * len(shares)))]  # noqa: E731
        print(f"  {name:22} n={len(shares):3d}  median {statistics.median(shares):.3f}  "
              f"p05 {pct(0.05):.3f}  p95 {pct(0.95):.3f}")
    g95 = sorted(unsupported_share(measured["ceiling_gold_300w"]))
    f05 = sorted(unsupported_share(measured["neg_fabricated"]))
    if g95 and f05:
        lo = g95[min(len(g95) - 1, int(0.95 * len(g95)))]
        hi = f05[min(len(f05) - 1, int(0.05 * len(f05)))]
        verdict = "a rate threshold exists in between" if lo < hi else \
            "EMPTY: the matcher's false flags overlap its detections, so no rate rescues it"
        print(f"  ceiling p95 = {lo:.3f}, fabricated p05 = {hi:.3f} -> {verdict}")

    separation = results["ceiling_gold_300w"] - max(
        results["neg_lead_300w"], results["neg_fabricated"], results["neg_wrong_document"])
    print(f"\nseparation (ceiling minus worst negative): {separation:+.2f}")

    if a.band:
        print("\nband: is the decision a point or a region?")
        print(f"{'floor':>6} {'grace':>12} {'share':>6} | "
              + " ".join(f"{k.split('_', 1)[1][:9]:>9}" for k in list(GATES)))
        for floor in (0.40, 0.45, 0.50, 0.55, 0.60):
            for uf, ur in ((1, 0.35), (1, 0.40), (2, 0.50), (1, 0.60)):
                task.recall_floor, task.unsupported_grace, task.unsupported_share = floor, uf, ur
                cells = [rate(measured[k]) for k in GATES]
                flag = "" if all(GATES[k][0] <= v <= GATES[k][1] for k, v in zip(GATES, cells)) else "  <- out"
                print(f"{floor:6.2f} {uf:12d} {ur:6.2f} | " + " ".join(f"{v:9.2f}" for v in cells) + flag)
        task.recall_floor = SummariseFacts.recall_floor
        task.unsupported_grace = SummariseFacts.unsupported_grace
        task.unsupported_share = SummariseFacts.unsupported_share

    if a.json_out:
        a.json_out.write_text(json.dumps(
            {"items": len(items), "thresholds": {"recall_floor": task.recall_floor,
                                                 "unsupported_grace": task.unsupported_grace,
                                                 "unsupported_share": task.unsupported_share,
                                                 "max_compression": task.max_compression},
             "controls": results, "separation": separation, "failures": failures}, indent=2))

    if failures:
        print("\n[FAIL] the thresholds cannot be answered for:", file=sys.stderr)
        for f in failures:
            print(f"  {f}", file=sys.stderr)
        return 1
    print("\n[OK] every gated control is where it has to be")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
