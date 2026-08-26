"""benchctl — the command line. Validation is real; submission and scoring are being filled in.

`validate` is complete and is the point of the boundary: a run that cannot be described honestly
should fail before a Job is created, not after a GPU has been paid for.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from . import spec

ARTIFACT_ROOT = Path("/artifacts")


def cmd_validate(args) -> int:
    run = spec.load_run(args.run)
    print(f"[OK] {run.id}: {len(run.cells)} cells")
    for cell in run.cells:
        price = (
            f"${cell.layer.input_usd_per_mtok}/${cell.layer.output_usd_per_mtok} per Mtok"
            if cell.layer.comparable_on_cost
            else "price is a placeholder — quality only"
        )
        print(f"  {cell.id:<28} {cell.kind:<8} c={cell.point.concurrency:<3} "
              f"{cell.layer.id:<22} {price}")
    if args.serving_root and run.serving_ref:
        manifest = spec.check_serving_manifest(run, args.serving_root)
        flags = manifest["engine_flags"]
        print(f"[OK] serving manifest {run.serving_ref}: {manifest['engine']} "
              f"{manifest['engine_version']}, prefix_caching={flags['enable_prefix_caching']}")
    return 0


def cmd_manifest(args) -> int:
    print(json.dumps(spec.load_run(args.run).manifest(), indent=2))
    return 0


def _not_yet(name: str):
    def inner(args) -> int:
        print(f"[TODO] {name} is not implemented yet; see benchctl/README.md for the order the "
              "families are being filled in", file=sys.stderr)
        return 2
    return inner


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="benchctl", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("validate", help="load a run spec and refuse anything undescribable")
    p.add_argument("run", type=Path)
    p.add_argument("--serving-root", type=Path, default=None,
                   help="where serving manifests live (default: skip the check)")
    p.set_defaults(func=cmd_validate)

    p = sub.add_parser("manifest", help="print the expanded, immutable run manifest")
    p.add_argument("run", type=Path)
    p.set_defaults(func=cmd_manifest)

    for name, help_text in (
        ("submit", "create one Job per cell"),
        ("collect", "copy artifacts off the shared volume and summarise"),
        ("score", "re-run a scorer over existing responses, without a GPU"),
        ("report", "join the quality and perf cells and print the operation-point table"),
    ):
        p = sub.add_parser(name, help=help_text)
        p.add_argument("run", type=Path, nargs="?")
        p.add_argument("--run-id", default=None)
        p.set_defaults(func=_not_yet(name))

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except spec.SpecError as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
