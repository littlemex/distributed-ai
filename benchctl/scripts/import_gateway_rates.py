#!/usr/bin/env python3
"""Import the gateway's own rate card, so no layer's price is ever transcribed by hand again.

Every API layer's price in this harness was typed into a spec by hand, and where the rate was not known the
layer was marked `pricing_status: placeholder` and excluded from cost comparisons. Both of those were
avoidable: the gateway ships `defaults/pricing.json` alongside `defaults/models.json`, which together give a
per-token rate — input, output, cache read and cache write — for every model it serves, and the model
registry says which rate row each alias bills against.

Hand transcription cost real conclusions. `gemma-4` was entered at $0.30 input and $1.20 output against the
card's $5.00 and $25.00, so its measured cost was understated **17x**, and it was published as the layer "on
the frontier as the cheapest" in two families. `claude-opus-5` was overstated 3x in the other direction.
Neither error is visible by inspection: a price is a plausible-looking number whatever it says.

So the rates become an imported artifact with provenance, a layer names a `pricing_key` instead of numbers,
and `benchctl validate` refuses a layer whose literal rates disagree with the card. The failure mode this
closes is not "someone typed the wrong number" but "nobody could tell".
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def _git_describe(repo: Path) -> str | None:
    try:
        out = subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"],
                             capture_output=True, text=True, timeout=15)
        return out.stdout.strip() or None
    except Exception:                                            # noqa: BLE001
        return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--gateway-defaults", type=Path, required=True,
                    help="the gateway's backend/mvp/defaults directory")
    ap.add_argument("--out", type=Path, default=Path("specs/gateway-rates.json"))
    args = ap.parse_args()

    pricing_path = args.gateway_defaults / "pricing.json"
    models_path = args.gateway_defaults / "models.json"
    for path in (pricing_path, models_path):
        if not path.exists():
            print(f"not found: {path}", file=sys.stderr)
            return 2

    pricing_raw = pricing_path.read_bytes()
    models_raw = models_path.read_bytes()
    pricing = json.loads(pricing_raw)
    models = json.loads(models_raw)

    rates = {}
    for key, entry in pricing["rates"].items():
        rates[key] = {
            "input_usd_per_mtok": entry["input_per_mtok_microusd"] / 1e6,
            "output_usd_per_mtok": entry["output_per_mtok_microusd"] / 1e6,
            "cache_read_usd_per_mtok": entry["cache_read_per_mtok_microusd"] / 1e6,
            "cache_write_usd_per_mtok": entry["cache_write_per_mtok_microusd"] / 1e6,
        }

    # Alias to rate row. An alias is what a spec puts in `model:`, so this is the mapping a spec needs.
    aliases: dict[str, str] = {}
    for model in models["models"]:
        key = model.get("pricing_key", "default")
        for alias in model.get("aliases") or []:
            aliases[alias] = key

    document = {
        "provenance": {
            "imported_at": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
            "gateway_defaults": str(args.gateway_defaults),
            "gateway_commit": _git_describe(args.gateway_defaults),
            "pricing_schema_version": pricing.get("schema_version"),
            "models_schema_version": models.get("schema_version"),
            # So a later run can tell whether the card moved rather than guessing from the numbers.
            "pricing_sha256": hashlib.sha256(pricing_raw).hexdigest(),
            "models_sha256": hashlib.sha256(models_raw).hexdigest(),
        },
        "rates": rates,
        "aliases": aliases,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
    print(f"[OK] {args.out}: {len(rates)} rate rows, {len(aliases)} model aliases")
    for alias, key in sorted(aliases.items()):
        r = rates.get(key) or rates["default"]
        print(f"  {alias:24} -> {key:16} in ${r['input_usd_per_mtok']:6.2f} "
              f"out ${r['output_usd_per_mtok']:6.2f} cache_read ${r['cache_read_usd_per_mtok']:5.2f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
