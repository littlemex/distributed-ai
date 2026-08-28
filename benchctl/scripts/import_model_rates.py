#!/usr/bin/env python3
"""Build the rate table this harness prices with, from AWS first and never from an over-charge default.

The resolution order, and the reason for each step:

1. **The AWS Price List API**, for models where AWS publishes an on-demand rate. This is the authority: these
   models are all served through Bedrock, so what AWS charges is what the bill says. Queried live, with the
   query and the response's own metadata recorded next to the numbers.
2. **`specs/vendor-rates.json`**, for models AWS does not publish — currently the Claude 4.x/5 family and the
   gpt-5.x family, which the Price List API has no products for in us-east-1. Every entry there carries a
   `source` string a reader can check.
3. **Unpriced.** A model that neither step can source is marked `placeholder`, and `benchctl` will compare it
   on quality and latency and refuse to compare it on cost.

The step that is deliberately *absent* is the one this script replaced. The gateway ships its own
`defaults/pricing.json`, and importing it wholesale looked like an obvious improvement over rates typed into
each run spec by hand. It was not, because five of its thirteen keys — `opus`, `gpt-5`, `gemma`, `nemotron`,
`qwen` — hold values identical to its `default` row, and the card says in as many words what that means:

    "A key absent from every layer falls back to 'default', which is Opus-priced: an unpriced model must
     over-charge, never under-charge."

Those are deliberate over-charges for models the card does not know, not prices. Importing them put `gemma-4`
at $5.00 input against AWS's published $0.14 — **36x** — and published it as the most expensive layer in a
family where it is the cheapest, having previously published it as the cheapest on a hand-typed $0.30. Three
numbers for one model, two of them wrong, and the wrongest one arrived by way of a source that looked
canonical.

So a distinct row in the gateway's card is usable evidence and is cited as such in `vendor-rates.json`; a row
equal to its default is refused here, loudly, by name.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

SERVICE = "AmazonBedrock"
# The Price List names on-demand token rates in several ways depending on how a model was onboarded.
INPUT_KINDS = ("Input tokens", "input_tokens_mantle", "Input Tokens")
OUTPUT_KINDS = ("Output tokens", "output_tokens_mantle", "Output Tokens")
CACHE_KINDS = ("Cache Read Input Tokens", "cache_read_input_tokens")


FIELD_BY_KIND = {
    "input": "input_usd_per_mtok",
    "output": "output_usd_per_mtok",
    "cache read": "cache_read_usd_per_mtok",
}


def _classify(attributes: dict) -> str | None:
    """Which of the three rates this product is, from whichever attribute the model was onboarded with."""
    label = (attributes.get("tokenType") or attributes.get("inferenceType") or "").lower()
    usage = (attributes.get("usagetype") or "").lower()
    text = f"{label} {usage}"
    if "cache" in text and "read" in text:
        return "cache read"
    if "output" in text:
        return "output"
    if "input" in text:
        return "input"
    return None


def aws_products_for_model(model: str, region: str) -> list[dict]:
    """Every on-demand product AWS publishes for one model in one region, paged to the end."""
    out: list[dict] = []
    token: str | None = None
    while True:
        cmd = ["aws", "pricing", "get-products", "--service-code", SERVICE, "--region", "us-east-1",
               "--max-results", "100", "--filters",
               f"Type=TERM_MATCH,Field=model,Value={model}",
               f"Type=TERM_MATCH,Field=regionCode,Value={region}"]
        if token:
            cmd += ["--next-token", token]
        run = subprocess.run(cmd, capture_output=True, text=True)
        if run.returncode != 0:
            print(f"  [{model} @ {region}] {run.stderr.strip()[:140]}", file=sys.stderr)
            return out
        payload = json.loads(run.stdout)
        out += [json.loads(s) for s in payload.get("PriceList") or []]
        token = payload.get("NextToken")
        if not token:
            return out


def aws_rate(model: str, region: str, tier: str) -> dict | None:
    """The published rate for one model, in the region it is served from, at one named service tier.

    Three things here are the difference between a price and a plausible number, and the first draft of this
    script got all three wrong:

    * **The region is the model's own.** Bedrock prices differ by region and this gateway serves different
      models from different ones — the Claude family from us-east-1, gemma-4 and the gpt-5.x family from
      us-east-2, grok-4.6 from us-west-2. Pricing everything at one region is pricing a deployment nobody runs.
    * **The tier is named, not inferred.** AWS publishes `standard`, `flex`, `priority`, `batch` and the
      `global-` variants for the same model, and they differ by up to 5x. `grok-4.6` alone has eighteen rows
      in one region.
    * **Nothing is minimised.** Taking the cheapest row silently selects a service level nobody asked for. If
      more than one distinct value survives the filters, this refuses to choose and says so.
    """
    values: dict[str, set[float]] = {}
    for product in aws_products_for_model(model, region):
        attributes = product["product"]["attributes"]
        if (attributes.get("service_tier") or "").lower() != tier:
            continue
        kind = _classify(attributes)
        if kind is None:
            continue
        for term in (product["terms"].get("OnDemand") or {}).values():
            for dimension in term["priceDimensions"].values():
                values.setdefault(kind, set()).add(
                    round(float(dimension["pricePerUnit"]["USD"]) * 1000, 6))
    if "input" not in values or "output" not in values:
        return None
    ambiguous = {k: sorted(v) for k, v in values.items() if len(v) > 1}
    if ambiguous:
        return {"status": "aws_ambiguous", "candidates": ambiguous, "region": region, "tier": tier,
                "source": f"AWS Price List API, {SERVICE}, model={model!r}, region={region}, "
                          f"service_tier={tier!r} — more than one price per field, so no price is taken"}
    entry = {"status": "aws_price_list", "region": region, "tier": tier,
             "source": f"AWS Price List API, {SERVICE}, model={model!r}, region={region}, "
                       f"service_tier={tier!r}"}
    for kind, field in FIELD_BY_KIND.items():
        if kind in values:
            entry[field] = next(iter(values[kind]))
    return entry


def gateway_default_keys(defaults: Path) -> set[str]:
    """The card's own rows that merely repeat its over-charge default, which are not prices."""
    path = defaults / "pricing.json"
    if not path.exists():
        return set()
    rates = json.loads(path.read_text())["rates"]
    default = rates.get("default")
    if not default:
        return set()
    return {key for key, row in rates.items()
            if key != "default" and row == default}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tier", default="standard",
                    help="the AWS service tier to price at; standard is what a plain request gets")
    ap.add_argument("--gateway-defaults", type=Path, default=None,
                    help="the gateway's backend/mvp/defaults, read only to name its unpriced keys")
    ap.add_argument("--vendor", type=Path, default=Path("specs/vendor-rates.json"))
    ap.add_argument("--models", type=Path, required=True,
                    help="the gateway's models.json: alias -> bedrock id and the region it is served from")
    ap.add_argument("--aliases", nargs="*", default=None,
                    help="only these aliases (default: every alias the run specs mention)")
    ap.add_argument("--out", type=Path, default=Path("specs/model-rates.json"))
    args = ap.parse_args()

    registry = json.loads(args.models.read_text())["models"]
    served: dict[str, tuple[str, str]] = {}
    for model in registry:
        bedrock_id, region = model.get("bedrock_model_id"), model.get("bedrock_region")
        if not (bedrock_id and region):
            continue
        for alias in model.get("aliases") or []:
            served[alias] = (bedrock_id, region)

    wanted = args.aliases or sorted(_aliases_used_by_specs() or served)
    vendor_doc = json.loads(args.vendor.read_text()) if args.vendor.exists() else {}
    vendor = vendor_doc.get("rates") or {}
    unpriced = dict(vendor_doc.get("unpriced") or {})

    resolved: dict[str, dict] = {}
    ambiguous: dict[str, dict] = {}
    for alias in wanted:
        if alias not in served:
            continue
        bedrock_id, region = served[alias]
        print(f"  {alias:22} {bedrock_id:44} {region} ... ", end="", flush=True)
        entry = aws_rate(bedrock_id, region, args.tier)
        if entry is None:
            print("AWS publishes nothing")
        elif entry["status"] == "aws_ambiguous":
            ambiguous[alias] = entry
            print(f"AMBIGUOUS {entry['candidates']}")
        else:
            resolved[alias] = dict(entry, bedrock_model_id=bedrock_id)
            print(f"in ${entry['input_usd_per_mtok']:.3f} out ${entry['output_usd_per_mtok']:.3f}")

    for alias, entry in vendor.items():
        if alias in resolved:
            continue
        bedrock_id, region = served.get(alias, (None, None))
        resolved[alias] = dict(entry, bedrock_model_id=bedrock_id, region=region)

    refused = sorted(gateway_default_keys(args.gateway_defaults)) if args.gateway_defaults else []
    document = {
        "provenance": {
            "built_at": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
            "aws_service_tier": args.tier,
            "priced_per_model_at_its_own_bedrock_region": True,
            "registry": str(args.models),
            "vendor_file": str(args.vendor),
            "gateway_keys_refused_as_over_charge_defaults": refused,
        },
        "rates": resolved,
        "ambiguous": ambiguous,
        "unpriced": unpriced,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")

    print(f"\n[OK] {args.out}: {len(resolved)} priced, {len(ambiguous)} ambiguous, "
          f"{len(unpriced)} unpriced")
    if refused:
        print(f"  refused as the gateway's over-charge default rather than a price: {', '.join(refused)}")
    for alias in sorted(resolved):
        e = resolved[alias]
        cache = e.get("cache_read_usd_per_mtok")
        print(f"  {alias:22} in ${e['input_usd_per_mtok']:7.3f} out ${e['output_usd_per_mtok']:7.3f} "
              f"cache_read {('$%.3f' % cache) if cache is not None else 'none published':>15}  "
              f"[{e['status']} {e.get('region') or ''}]")
    return 0


def _aliases_used_by_specs() -> list[str]:
    """Every model alias the run specs actually address, so nothing irrelevant is queried."""
    import re
    out: set[str] = set()
    for path in sorted(Path("specs/runs").glob("*.yaml")):
        for line in path.read_text().split("\n"):
            m = re.match(r"\s*model:\s*(\S+)", line)
            if m:
                out.add(m.group(1))
    return sorted(out)


if __name__ == "__main__":
    raise SystemExit(main())
