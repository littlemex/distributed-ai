#!/usr/bin/env python3
"""Which layers on this gateway get a prompt-cache discount, from what prefix length, and asked how.

The agentic family turned a 3.04x loss into a 1.76x one on the strength of prompt caching, which makes the
discount the single biggest term in this project's routing arithmetic. It had never been measured per layer.
It should have been, because it is not uniform: on this gateway one Claude model caches automatically and
another never caches at all, whether or not it is asked, through either route the gateway offers.

That asymmetry breaks a habit of reasoning worth naming. "The API gets a cache discount and the box does
not" is not a fact about APIs; it is a fact about one model behind one gateway. A layer that cannot cache is
competing with the box on full price for every request, no matter how much prefix its traffic shares.

What this measures, per layer:

* **Whether a shared prefix is discounted at all**, by sending the same preamble twice back to back and
  reading the provider's own cached-token count. Nothing here trusts a published policy.
* **Whether it has to be asked.** Anthropic's own API needs an explicit `cache_control` breakpoint, so a
  gateway may require one, pass one through, ignore one, or cache without any. All four are possible and the
  difference decides whether `benchctl`'s client is leaving a discount on the table.
* **The shortest prefix that earns it.** Caching has a minimum cacheable prefix, so the discount is not
  available to short-prompt traffic at any hit rate. Where that minimum sits decides which families can ever
  benefit, and a family below it can stop asking.
* **The tokeniser ratio.** Identical text, billed per each vendor's own tokeniser. A layer that reads the
  same document as twice as many tokens is twice as expensive per document at the same posted price, and
  posted prices are what get compared.

Run it before quoting a per-token price comparison, and again when a model is added.
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

# One clause repeated, so prefix length is controllable and the text carries no task the model might answer
# differently at different lengths.
CLAUSE = "Reference clause for context. "
LEAD = ("You are a careful assistant. The following reference material is provided for context and is "
        "identical on every request. ")
ASK = "\nReply with the single word OK."


def _post(url: str, body: dict, key: str, timeout: float = 180.0) -> tuple[dict | None, str | None]:
    request = urllib.request.Request(
        url, data=json.dumps(body).encode(),
        headers={"content-type": "application/json", "authorization": f"Bearer {key}",
                 "anthropic-version": "2023-06-01"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as reply:
            return json.loads(reply.read()), None
    except urllib.error.HTTPError as exc:
        return None, f"HTTP {exc.code}: {exc.read()[:160].decode('utf-8', 'replace')}"
    except Exception as exc:                                    # noqa: BLE001
        return None, f"{type(exc).__name__}: {exc}"


def _usage(payload: dict) -> tuple[int, int]:
    """Input tokens and cached input tokens, under every name these providers use for them."""
    usage = payload.get("usage") or {}
    total = int(usage.get("input_tokens") or usage.get("prompt_tokens") or 0)
    cached = int(usage.get("cache_read_input_tokens") or usage.get("cache_read_tokens")
                 or (usage.get("prompt_tokens_details") or {}).get("cached_tokens") or 0)
    return total, cached


def _body(model: str, preamble: str, *, marked: bool) -> dict:
    """The same request twice over, once with Anthropic's breakpoint and once without it."""
    if marked:
        content = [{"type": "text", "text": preamble, "cache_control": {"type": "ephemeral"}},
                   {"type": "text", "text": ASK}]
    else:
        content = preamble + ASK
    return {"model": model, "max_tokens": 16, "messages": [{"role": "user", "content": content}]}


def probe_pair(url: str, model: str, preamble: str, key: str, *, marked: bool,
               gap_s: float = 1.0) -> dict:
    """Two identical requests back to back. The second one is the measurement."""
    first, error = _post(url, _body(model, preamble, marked=marked), key)
    if error:
        return {"error": error}
    time.sleep(gap_s)
    second, error = _post(url, _body(model, preamble, marked=marked), key)
    if error:
        return {"error": error}
    total, cached = _usage(second)
    first_total, first_cached = _usage(first)
    return {"input_tokens": total, "cached": cached,
            "cached_share": (cached / total) if total else 0.0,
            "first_cached": first_cached, "first_input_tokens": first_total}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--endpoint", default="https://d8b03j8erit4k.cloudfront.net/v1/chat/completions")
    ap.add_argument("--models", nargs="+", required=True)
    ap.add_argument("--clauses", type=int, nargs="+", default=[900],
                   help="preamble lengths, in repetitions of one clause")
    ap.add_argument("--ladder", action="store_true",
                   help="sweep the lengths to find the shortest prefix that is discounted")
    ap.add_argument("--json-out", type=Path, default=None)
    args = ap.parse_args()

    key = os.environ.get("BENCHCTL_API_KEY")
    if not key:
        print("BENCHCTL_API_KEY is not set", file=sys.stderr)
        return 2

    longest = max(args.clauses)
    results: dict[str, dict] = {}

    print(f"{'model':22} {'asked?':>8} {'input':>7} {'cached':>7} {'share':>7}  verdict")
    for model in args.models:
        preamble = LEAD + CLAUSE * longest
        row: dict = {"clauses": longest}
        for marked in (False, True):
            outcome = probe_pair(args.endpoint, model, preamble, key, marked=marked)
            row["marked" if marked else "plain"] = outcome
            label = "yes" if marked else "no"
            if "error" in outcome:
                print(f"{model:22} {label:>8} {'':>7} {'':>7} {'':>7}  {outcome['error']}")
                continue
            verdict = "discounted" if outcome["cached_share"] > 0.5 else "no discount"
            print(f"{model:22} {label:>8} {outcome['input_tokens']:7d} {outcome['cached']:7d} "
                  f"{outcome['cached_share']:6.1%}  {verdict}")
        results[model] = row

        caches = any(row.get(k, {}).get("cached_share", 0) > 0.5 for k in ("plain", "marked"))
        if args.ladder and caches:
            # Only worth sweeping a layer that caches at all. The shortest prefix that earns the discount is
            # what tells a short-prompt family to stop asking.
            needs_mark = (row.get("plain", {}).get("cached_share", 0) <= 0.5)
            floor = None
            for clauses in sorted(args.clauses):
                outcome = probe_pair(args.endpoint, model, LEAD + CLAUSE * clauses, key,
                                     marked=needs_mark)
                share = outcome.get("cached_share", 0.0)
                tokens = outcome.get("input_tokens", 0)
                hit = share > 0.5
                print(f"{'':22} {'ladder':>8} {tokens:7d} {outcome.get('cached', 0):7d} "
                      f"{share:6.1%}  {clauses} clauses")
                if hit and floor is None:
                    floor = tokens
            row["minimum_discounted_input_tokens"] = floor

    # Identical text, so the token counts across layers are the tokeniser ratio and nothing else.
    counts = {m: r.get("plain", {}).get("input_tokens") or r.get("marked", {}).get("input_tokens")
              for m, r in results.items()}
    counts = {m: n for m, n in counts.items() if n}
    if len(counts) > 1:
        cheapest = min(counts.values())
        print(f"\ntokeniser ratio on identical text, against the most compact layer:")
        for model, n in sorted(counts.items(), key=lambda kv: kv[1]):
            print(f"  {model:22} {n:7d} tokens  x{n / cheapest:.2f}")
        print("  A layer that reads the same text as more tokens is more expensive per document at the "
              "same posted price.")

    if args.json_out:
        args.json_out.write_text(json.dumps(results, indent=2))
        print(f"\n[OK] wrote {args.json_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
