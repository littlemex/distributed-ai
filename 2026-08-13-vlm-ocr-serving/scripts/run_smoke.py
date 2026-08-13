#!/usr/bin/env python3
"""run_smoke.py — POST an image to one or more OCR/doc-VLM engines and compare their output.

Each engine speaks the same /extract contract, so this hits every --url, prints the grounded
tokens (text + pixel bbox + confidence), and shows a small cross-engine summary: token count
and latency per engine, and — with --find TEXT — which engines read that string and where.
That last check is the point of running several engines: an independent channel that DISAGREES
on a value is exactly the signal a verifier wants.

Standard library only (urllib); no third-party deps. Sends the image as a raw body, which the
serving harness accepts alongside multipart.

Usage:
  # one engine over a single port-forward
  python3 run_smoke.py receipt.png --url http://localhost:8000

  # several engines (forward each to a different local port first), find a value across them
  python3 run_smoke.py receipt.png \
    --url tesseract=http://localhost:8001 \
    --url paddleocr=http://localhost:8002 \
    --url dots-ocr=http://localhost:8003 \
    --find 12.000
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.request


def post_extract(base_url: str, image_bytes: bytes, timeout: float) -> dict:
    req = urllib.request.Request(
        base_url.rstrip("/") + "/extract",
        data=image_bytes,
        headers={"Content-Type": "application/octet-stream"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def parse_target(spec: str, index: int) -> tuple[str, str]:
    """'name=url' -> (name, url); bare 'url' -> ('engine<index>', url)."""
    if "=" in spec and spec.split("=", 1)[0] and not spec.startswith("http"):
        name, url = spec.split("=", 1)
        return name, url
    return f"engine{index}", spec


def main() -> int:
    ap = argparse.ArgumentParser(description="Smoke-test OCR/doc-VLM /extract engines.")
    ap.add_argument("image", help="path to the image to send")
    ap.add_argument(
        "--url",
        action="append",
        required=True,
        metavar="[NAME=]URL",
        help="engine base URL (repeatable); optional NAME= label, e.g. tesseract=http://localhost:8001",
    )
    ap.add_argument("--find", default=None, help="report which engines read this text and where")
    ap.add_argument("--max-tokens", type=int, default=20, help="max tokens to print per engine")
    ap.add_argument("--timeout", type=float, default=180.0, help="per-request timeout seconds")
    args = ap.parse_args()

    with open(args.image, "rb") as fh:
        image_bytes = fh.read()

    results: dict[str, dict] = {}
    for i, spec in enumerate(args.url):
        name, url = parse_target(spec, i)
        try:
            results[name] = post_extract(url, image_bytes, args.timeout)
        except Exception as exc:
            print(f"[{name}] request FAILED ({url}): {exc}", file=sys.stderr)
            results[name] = {"error": str(exc)}

    for name, res in results.items():
        print("=" * 72)
        if "error" in res:
            print(f"{name}: ERROR {res['error']}")
            continue
        toks = res.get("tokens", [])
        print(
            f"{name}: engine={res.get('engine')} version={res.get('engine_version')} "
            f"tokens={len(toks)} latency_ms={res.get('latency_ms')} "
            f"image={res.get('image')}"
        )
        for t in toks[: args.max_tokens]:
            bbox = [round(v, 1) for v in t["bbox"]]
            conf = t.get("confidence")
            conf_s = f"{conf:.3f}" if isinstance(conf, (int, float)) else "  -  "
            print(f"  conf={conf_s}  bbox={bbox}  {t['text']!r}")
        if len(toks) > args.max_tokens:
            print(f"  ... (+{len(toks) - args.max_tokens} more)")

    if args.find is not None:
        print("=" * 72)
        needle = args.find.strip().lower()
        print(f"--find {args.find!r}: which engines read it, and where")
        for name, res in results.items():
            if "error" in res:
                print(f"  {name}: (engine errored)")
                continue
            hits = [
                (t["text"], [round(v, 1) for v in t["bbox"]], t.get("confidence"))
                for t in res.get("tokens", [])
                if needle in (t["text"] or "").strip().lower()
            ]
            if hits:
                for text, bbox, conf in hits:
                    conf_s = f"{conf:.3f}" if isinstance(conf, (int, float)) else "-"
                    print(f"  {name}: FOUND {text!r} at bbox={bbox} conf={conf_s}")
            else:
                print(f"  {name}: not found")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
