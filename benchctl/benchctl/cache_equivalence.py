"""Does a cache hit give the same answer as a cache miss?

vLLM keeps prefix caching opt-in for hybrid attention models with the comment "while the feature
matures", and the reason it is hard is the reason it is worth checking: reusing a prefix on this
architecture means restoring a linear-attention layer's recurrent state at a block boundary, not just
re-reading paged KV. A wrong restore is silent — the request succeeds and the answer changes.

The test is exact output equality at temperature 0, and it is designed around the fact that bitwise
determinism is not guaranteed even without caching: FP8 kernels and batch-dependent reductions make
the same prompt occasionally produce a different continuation. So the run-to-run divergence with
caching disabled is measured first and used as the control. The question is not "is the cached answer
identical" but "does caching make answers diverge more than the engine already does on its own".

Multi-turn matters here more than length. A second turn's prompt is the first turn's prompt plus a
suffix, so it is the case where a partial prefix is restored mid-sequence, which is exactly the path
that a KV-only implementation would get wrong.
"""

from __future__ import annotations

import json
import os
import statistics
import time
import urllib.request
from pathlib import Path


def _chat(url: str, model: str, messages: list[dict], max_tokens: int) -> dict:
    body = json.dumps({"model": model, "messages": messages, "max_tokens": max_tokens,
                       "temperature": 0.0, "seed": 0}).encode()
    req = urllib.request.Request(url, data=body, headers={"content-type": "application/json"})
    started = time.perf_counter()
    with urllib.request.urlopen(req, timeout=1200) as r:
        payload = json.load(r)
    usage = payload.get("usage") or {}
    details = usage.get("prompt_tokens_details") or {}
    return {"text": payload["choices"][0]["message"].get("content") or "",
            "prompt_tokens": usage.get("prompt_tokens", 0),
            "cached_tokens": details.get("cached_tokens", 0),
            "latency_s": round(time.perf_counter() - started, 4)}


def _first_divergence(a: str, b: str) -> int | None:
    """Character index where two answers first differ, or None if identical."""
    if a == b:
        return None
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            return i
    return min(len(a), len(b))


def run(out_dir: Path) -> dict:
    url, model = os.environ["PERF_URL"], os.environ["PERF_MODEL"]
    turns = int(os.environ.get("TURNS", "4"))
    max_tokens = int(os.environ.get("MAX_TOKENS", "96"))
    lengths = [int(x) for x in os.environ.get("PREFIX_LENGTHS", "2000,8000,30000").split(",")]
    out_dir.mkdir(parents=True, exist_ok=True)

    words = [f"item{i}" for i in range(8192)]
    def filler(n, salt):
        return (f"[doc {salt}] " + " ".join(words[(i * 7 + salt) % len(words)]
                                            for i in range(max(1, n // 4))))

    cases, divergences, control_divergences = [], [], []
    for n in lengths:
        # A conversation grown one turn at a time. Turn k's prompt contains turn k-1's prompt, so
        # every turn after the first is a partial-prefix restore.
        for salt, bucket, label in ((1, divergences, "repeat"), (2, control_divergences, "control")):
            history: list[dict] = [{"role": "user", "content":
                                    filler(n, salt) + "\n\nこの文書の最初の語を答えてください。"}]
            for turn in range(turns):
                if turn:
                    history = history + [
                        {"role": "assistant", "content": f"turn {turn}"},
                        {"role": "user", "content": f"続けて、{turn} 番目の語を答えてください。"},
                    ]
                # First call may miss; the second call of the same prompt should hit for `repeat`.
                a = _chat(url, model, history, max_tokens)
                b = _chat(url, model, history, max_tokens)
                idx = _first_divergence(a["text"], b["text"])
                bucket.append(idx)
                cases.append({"prefix_tokens": n, "turn": turn, "arm": label,
                              "prompt_tokens": a["prompt_tokens"],
                              "cached_first": a["cached_tokens"], "cached_second": b["cached_tokens"],
                              "identical": idx is None, "first_divergence_char": idx,
                              "len_a": len(a["text"]), "len_b": len(b["text"]),
                              "latency_first_s": a["latency_s"], "latency_second_s": b["latency_s"]})
                print(f"  in~{n:>6} turn {turn}: prompt {a['prompt_tokens']:>7} tok, cached "
                      f"{a['cached_tokens']:>7}->{b['cached_tokens']:>7}, "
                      f"{'identical' if idx is None else f'DIVERGES at char {idx}'}, "
                      f"{a['latency_s']:.2f}s -> {b['latency_s']:.2f}s", flush=True)

    hit_pairs = [c for c in cases if c["cached_second"] > 0]
    summary = {
        "model": model, "turns": turns, "prefix_lengths": lengths, "max_tokens": max_tokens,
        "pairs": len(cases),
        "pairs_where_second_call_hit_cache": len(hit_pairs),
        "identical_all": sum(1 for c in cases if c["identical"]),
        "identical_when_cache_hit": sum(1 for c in hit_pairs if c["identical"]),
        "divergent_when_cache_hit": [c for c in hit_pairs if not c["identical"]],
        "speedup_when_cache_hit": (
            statistics.median(c["latency_first_s"] / c["latency_second_s"] for c in hit_pairs)
            if hit_pairs else None),
        "cases": cases,
    }
    (out_dir / "cache_equivalence.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False))
    print(f"\n[result] {summary['identical_when_cache_hit']}/{len(hit_pairs)} cache-hit pairs "
          f"identical; {summary['identical_all']}/{len(cases)} pairs identical overall; "
          f"median speedup on a hit {summary['speedup_when_cache_hit'] or float('nan'):.2f}x")
    return summary


if __name__ == "__main__":
    run(Path(os.environ.get("OUT_DIR", "/artifacts/cache-equivalence")))
