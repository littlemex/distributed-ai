"""How long does a conversation's prefix survive in the cache, as a function of load?

The hit rate is not a property of a request. It is the probability that the blocks a request wants are
still resident when it arrives, which makes it a property of the *system* — how many other conversations
wrote to the cache in the meantime. So the quantity to measure is a survival curve `S(gap | C)`: given C
conversations competing, what fraction of a prefix is still cached after `gap` seconds of other traffic.

Design notes, because two of them override advice this was built from.

The corpus cannot supply content. Inspecting `traces.jsonl` shows the traces are anonymised as block-hash
sequences plus token counts and timings — `block_size: 64`, `hash_ids: [10, 11, 12, ...]` — not text. So
"real content versus synthetic content" is a distinction that does not exist here: AIPerf reconstructs
token sequences that reproduce the hash structure, and anything else does the same. What the corpus does
supply is the *weights*: over 252 main-turn transitions, the inter-turn gap is 19.8 s at p50 and 259.7 s
at p90, 66.3% of turns return within a minute, and a new prompt shares 98.6% of itself with the previous
one at the median.

And the gap must be swept, not preserved. One trace's 66 requests span 26 hours, so replaying native gaps
is not an experiment that finishes. More importantly, a survival curve's independent variable *is* the
gap; holding it at its native distribution would give one blended point instead of the curve. The native
distribution comes back at the end, to weight the curve into an expected hit rate for real traffic.

What this reports per turn is the engine's own `usage.prompt_tokens_details.cached_tokens`, which is
ground truth rather than an aggregate: paired with the gap that preceded it, every turn is one sample of
the survival curve.
"""

from __future__ import annotations

import json
import os
import random
import statistics
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

BLOCK = 64          # vLLM's block size for this model, and the corpus's own block_size


def _turn(url: str, model: str, prompt: str, max_tokens: int, corr: str) -> dict:
    body = json.dumps({"model": model, "messages": [{"role": "user", "content": prompt}],
                       "max_tokens": max_tokens, "temperature": 0.0}).encode()
    req = urllib.request.Request(url, data=body, headers={
        "content-type": "application/json", "x-correlation-id": corr})
    started = time.perf_counter()
    with urllib.request.urlopen(req, timeout=1800) as r:
        payload = json.load(r)
    usage = payload.get("usage") or {}
    details = usage.get("prompt_tokens_details") or {}
    return {"prompt_tokens": usage.get("prompt_tokens", 0),
            "cached_tokens": details.get("cached_tokens", 0),
            "completion_tokens": usage.get("completion_tokens", 0),
            "latency_s": time.perf_counter() - started}


class Conversation:
    """One conversation with a stable, unique prefix that grows by a small suffix each turn.

    The prefix is unique per conversation on purpose. Sharing it would let conversations hit each other's
    blocks and report a hit rate that has nothing to do with a conversation's own prefix surviving —
    which is the one thing being measured.
    """

    def __init__(self, index: int, prefix_tokens: int, seed: int) -> None:
        rng = random.Random(seed * 100003 + index)
        vocab = [f"w{rng.randrange(10**6)}" for _ in range(2048)]
        self.id = f"conv-{seed}-{index:04d}"
        self.prefix = (f"[session {self.id}] "
                       + " ".join(vocab[rng.randrange(len(vocab))]
                                  for _ in range(max(1, prefix_tokens // 4))))
        self.turn = 0
        self.last_sent: float | None = None

    def next_prompt(self) -> str:
        self.turn += 1
        return f"{self.prefix}\n\n[turn {self.turn}] 直前の語を 1 つだけ答えてください。"


def run(out_dir: Path) -> dict:
    url, model = os.environ["PERF_URL"], os.environ["PERF_MODEL"]
    prefix_tokens = int(os.environ.get("PREFIX_TOKENS", "60000"))
    max_tokens = int(os.environ.get("MAX_TOKENS", "8"))
    seed = int(os.environ.get("SEED", "20260828"))
    rounds = int(os.environ.get("ROUNDS", "4"))
    counts = [int(x) for x in os.environ.get("CONVERSATION_COUNTS", "2,6,12,20,32").split(",")]
    inject_gap = float(os.environ.get("INJECT_GAP_S", "0"))
    out_dir.mkdir(parents=True, exist_ok=True)

    cells = []
    for c in counts:
        convs = [Conversation(i, prefix_tokens, seed) for i in range(c)]
        # Warm every prefix once, then walk the ring `rounds` more times. A turn's gap is the wall time
        # since that same conversation's previous turn, which is what the ring's size sets.
        samples = []
        started = time.perf_counter()
        for r in range(rounds + 1):
            with ThreadPoolExecutor(max_workers=min(c, 8)) as pool:
                def touch(conv: Conversation) -> dict:
                    # An explicit gap separates the two things `C` confounds. Raising C raises both the
                    # working set and the time before a conversation comes round again, so a collapse at
                    # high C could be capacity or age. Holding C low and injecting the gap tests age with
                    # the working set fixed; shrinking the prefix at high C tests capacity with the gap
                    # roughly fixed.
                    if inject_gap:
                        time.sleep(inject_gap)
                    now = time.perf_counter()
                    gap = None if conv.last_sent is None else now - conv.last_sent
                    res = _turn(url, model, conv.next_prompt(), max_tokens, conv.id)
                    conv.last_sent = now
                    frac = (res["cached_tokens"] / res["prompt_tokens"]
                            if res["prompt_tokens"] else None)
                    return {"conversation": conv.id, "round": r, "gap_s": gap,
                            "cached_frac": frac, **res}
                for row in pool.map(touch, convs):
                    if row["round"] > 0:      # round 0 is the warm-up write, never a hit
                        samples.append(row)
        wall = time.perf_counter() - started
        warm = [s for s in samples if s["gap_s"] is not None]
        fracs = [s["cached_frac"] for s in warm if s["cached_frac"] is not None]
        gaps = [s["gap_s"] for s in warm]
        resident = c * prefix_tokens
        cells.append({
            "conversations": c, "prefix_tokens": prefix_tokens,
            "nominal_resident_tokens": resident,
            "turns_measured": len(warm), "wall_s": wall,
            "cached_frac_mean": statistics.mean(fracs) if fracs else None,
            "cached_frac_median": statistics.median(fracs) if fracs else None,
            "cached_frac_min": min(fracs) if fracs else None,
            "full_hits": sum(1 for f in fracs if f >= 0.99),
            "partial_hits": sum(1 for f in fracs if 0.01 < f < 0.99),
            "misses": sum(1 for f in fracs if f <= 0.01),
            "gap_median_s": statistics.median(gaps) if gaps else None,
            "gap_max_s": max(gaps) if gaps else None,
            "samples": warm,
        })
        cell = cells[-1]
        print(f"C={c:>3} ({resident:>9,} tokens nominally resident): cached "
              f"mean {(cell['cached_frac_mean'] or 0)*100:5.1f}% median "
              f"{(cell['cached_frac_median'] or 0)*100:5.1f}% min "
              f"{(cell['cached_frac_min'] or 0)*100:5.1f}% | full {cell['full_hits']:>3} "
              f"partial {cell['partial_hits']:>3} miss {cell['misses']:>3} | gap median "
              f"{cell['gap_median_s'] or 0:6.1f}s", flush=True)

    # The corpus's own gap distribution, from 252 main-turn transitions, used to turn the curve into an
    # expected hit rate rather than leaving it as a shape.
    corpus_gap_quantiles = {"p10": 5.7, "p25": 9.0, "p50": 19.8, "p75": 81.5,
                            "p90": 259.7, "p95": 539.1, "p99": 6391.2}
    summary = {"model": model, "prefix_tokens": prefix_tokens, "rounds": rounds, "seed": seed,
               "injected_gap_s": inject_gap,
               "kv_pool_tokens_per_replica": 2042667,
               "note": "prompt_tokens is measured, not assumed: the filler tokenises to ~7 tokens a word, so PREFIX_TOKENS is a request and the samples carry the truth.",
               "corpus_gap_quantiles_s": corpus_gap_quantiles,
               "corpus_prefix_share_median": 0.986,
               "cells": cells}
    (out_dir / "survival.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False))
    print(f"\n[OK] wrote {out_dir}/survival.json")
    return summary


if __name__ == "__main__":
    run(Path(os.environ.get("OUT_DIR", "/artifacts/prefix-survival")))
