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


def cmd_run_local(args) -> int:
    """Run a quality cell from here rather than as a Job.

    Legitimate only for quality cells: they are deterministic and one request at a time, so where the
    client runs does not change the answer. A perf cell measures latency under load and must run in the
    cluster, next to nothing else — which is why this refuses one.
    """
    from . import runner
    from .tasks.classification_enum import ClassificationEnum
    from .tasks.longctx_mc import LongContextChoice
    from .tasks.ocr_vqa import OcrVqa

    PLUGINS = {ClassificationEnum.name: ClassificationEnum,
               LongContextChoice.name: LongContextChoice,
               OcrVqa.name: OcrVqa}

    run = spec.load_run(args.run)
    cells = [c for c in run.cells if c.id in args.cells] if args.cells else list(run.cells)
    root = args.artifact_root / "runs" / run.id
    root.mkdir(parents=True, exist_ok=True)
    (root / "manifest.json").write_text(json.dumps(run.manifest(), indent=2))

    summaries = {}
    for cell in cells:
        if cell.kind != "quality":
            print(f"[SKIP] {cell.id}: a {cell.kind} cell measures behaviour under load and has to run "
                  "in the cluster", file=sys.stderr)
            continue
        plugin = PLUGINS.get(cell.suite.task_plugin)
        if plugin is None:
            print(f"[SKIP] {cell.id}: no plugin for {cell.suite.task_plugin} yet", file=sys.stderr)
            continue
        items_path = (args.spec_root / cell.suite.items if not Path(cell.suite.items).is_absolute()
                      else Path(cell.suite.items))
        if plugin is ClassificationEnum:
            task = plugin(items_path=items_path, labels=tuple(args.labels.split(",")))
        elif plugin is OcrVqa:
            # Images live beside the manifest on the artifact volume, never in git: a few hundred
            # JPEGs in history would make every spec review a binary diff.
            task = plugin(manifest_path=items_path)
        else:
            task = plugin(items_path=items_path)
        print(f"[RUN] {cell.id} on {cell.layer.id} ({cell.layer.endpoint})")
        summary = runner.run_quality_cell(cell, task, root / cell.id, limit=args.limit)
        summaries[cell.id] = summary
        rate = f"{summary['rate']:.3f}" if summary["rate"] is not None else "n/a"
        money = (f"api ${summary['api_usd']:.5f}" if cell.layer.kind == "api"
                 else f"box ${summary['box_usd_at_full_utilisation']:.5f} at full occupancy "
                      f"({summary['box_seconds']:.1f} box-seconds)")
        print(f"      {summary['passed']}/{summary['scored']} = {rate}"
              f"  (excluded {summary['excluded_transport']})  {money}  {summary['wall_s']:.0f}s")

    box = next((c for c in cells if c.layer.kind == "self_hosted" and c.id in summaries), None)
    base = next((c for c in cells if c.layer.id == c.suite.baseline_layer and c.id in summaries), None)
    if box and base:
        floor = box.suite.floor
        # A failed comparison must not discard a finished run. Every cell's artifacts are already on
        # disk by this point, and the first OCR run exited non-zero here — the baseline had scored
        # nothing because the gateway rejected every image — which made a successful 278-item box cell
        # look like a crashed job.
        try:
            result = runner.compare(root / box.id, root / base.id,
                                    margin_pp=float(floor.get("margin_pp", 2.0)),
                                    confidence=float(floor.get("confidence", 0.80)))
        except ValueError as exc:
            print(f"\n[PAIRED] not computable: {exc}. Cell artifacts are written; "
                  f"check each cell's excluded_transport before reading anything into this.",
                  file=sys.stderr)
            return 0
        print(f"\n[PAIRED] {box.layer.id} vs {base.layer.id} on {result.n} shared items")
        print(f"  box {result.box_passed}/{result.n}, baseline {result.baseline_passed}/{result.n}")
        print(f"  only baseline {result.only_baseline}, only box {result.only_box}, "
              f"discordance {result.discordance:.2f}")
        print(f"  difference {result.difference_pp:+.1f} pp, one-sided {result.confidence:.0%} lower "
              f"bound {result.lcb_pp:+.1f} pp, margin -{result.margin_pp:.1f} pp")
        print(f"  McNemar exact p = "
              f"{result.mcnemar_p:.3f}" if result.mcnemar_p is not None else "  no discordant pairs")
        verdict = "non-inferior at this margin" if result.non_inferior else "NOT non-inferior"
        print(f"  -> {verdict}")
        (root / "paired.json").write_text(json.dumps(
            {k: v for k, v in result.__dict__.items()} | {"non_inferior": result.non_inferior},
            indent=2))
    return 0


def _not_yet(name: str):
    def inner(args) -> int:
        print(f"[TODO] {name} is not implemented yet; see benchctl/README.md for the order the "
              "families are being filled in", file=sys.stderr)
        return 2
    return inner


def cmd_table(args) -> int:
    """Merge measurements into the routing table, and print what it now says.

    The table is the artifact a router would actually read, and the reason it stores per-item verdicts
    rather than rates is written at the top of `routing_table.py`: four layers on OCRBench reported four
    rates over four different subsets, and only the paired intersections were comparable. Adding a model
    later means measuring it once against the same items and merging — every comparison against what is
    already in the table is then arithmetic, not another run.
    """
    from . import routing_table

    run = spec.load_run(args.run)
    existing = json.loads(args.out.read_text()) if args.out.exists() else None
    table = routing_table.merge(existing, run, args.run_dir, args.cells)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(table, indent=2, ensure_ascii=False))
    print(f"[OK] {args.out}  runs={len(table['runs'])}  suites={len(table['suites'])}")
    for suite_id, suite in table["suites"].items():
        rows = routing_table.frontier(suite)
        n = rows[0]["n_common"] if rows else 0
        print(f"\n{suite_id}  family={suite['family']}  layers={len(suite['layers'])}  common items={n}")
        for r in rows:
            mark = "*" if r["on_frontier"] else " "
            cost = f"${r['usd_per_item']*1000:.3f}/1k" if r["usd_per_item"] else "n/a"
            print(f"  {mark} {r['layer']:<22} {r['rate']:.3f}  {cost:>12}  "
                  f"p50 {r['latency_p50_s'] or 0:.2f}s"
                  + (f"  dominated by {', '.join(r['dominated_by'])}" if r["dominated_by"] else ""))
        for pair, d in (suite.get("pairs") or {}).items():
            if not d.get("n"):
                continue
            print(f"    {pair}: n={d['n']} diff {d['difference_pp']:+.1f}pp "
                  f"discordant {d['discordant']} p={d['mcnemar_exact_p']:.4f} "
                  f"{d['structure']} escalation_reaches_union={d['escalation_can_reach_union']}")
        for name, layer in suite["layers"].items():
            if layer["excluded_by_reason"]:
                print(f"    excluded on {name}: {layer['excluded_by_reason']}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="benchctl", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("validate", help="load a run spec and refuse anything undescribable")
    p.add_argument("run", type=Path)
    p.add_argument("--serving-root", type=Path, default=None,
                   help="where serving manifests live (default: skip the check)")
    p.set_defaults(func=cmd_validate)

    p = sub.add_parser("run-local", help="run this run's quality cells from here (not perf cells)")
    p.add_argument("run", type=Path)
    p.add_argument("--cells", nargs="*", default=None)
    p.add_argument("--limit", type=int, default=None)
    p.add_argument("--artifact-root", type=Path, default=Path("./artifacts"))
    p.add_argument("--spec-root", type=Path, default=Path("."))
    p.add_argument("--labels", default="ポジティブ,ニュートラル,ネガティブ")
    p.set_defaults(func=cmd_run_local)

    p = sub.add_parser("table", help="fold a run's quality cells into the accumulating routing table")
    p.add_argument("run", type=Path)
    p.add_argument("--run-dir", type=Path, required=True,
                   help="the run's artifact directory, e.g. /artifacts/runs/<run-id>")
    p.add_argument("--out", type=Path, required=True, help="routing table JSON, created or merged")
    p.add_argument("--cells", nargs="*", default=None)
    p.set_defaults(func=cmd_table)

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
