"""benchctl — the command line. Validation is real; submission and scoring are being filled in.

`validate` is complete and is the point of the boundary: a run that cannot be described honestly
should fail before a Job is created, not after a GPU has been paid for.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict
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


def _plugins() -> dict:
    """The families that exist. One registry, because `run-local` and `score` must agree on it."""
    from .tasks.classification_enum import ClassificationEnum
    from .tasks.longctx_mc import LongContextChoice
    from .tasks.ocr_vqa import OcrVqa
    from .tasks.summarise_facts import SummariseFacts

    return {ClassificationEnum.name: ClassificationEnum,
            LongContextChoice.name: LongContextChoice,
            OcrVqa.name: OcrVqa,
            SummariseFacts.name: SummariseFacts}


def _build_task(plugin, items_path: Path, args):
    """Instantiate a family's task, which differ in what they need pointed at."""
    from .tasks.classification_enum import ClassificationEnum
    from .tasks.ocr_vqa import OcrVqa

    if plugin is ClassificationEnum:
        return plugin(items_path=items_path, labels=tuple(args.labels.split(",")))
    if plugin is OcrVqa:
        # Images live beside the manifest on the artifact volume, never in git: a few hundred JPEGs in
        # history would make every spec review a binary diff.
        return plugin(manifest_path=items_path)
    return plugin(items_path=items_path)


def _items_path(cell, args) -> Path:
    return (args.spec_root / cell.suite.items if not Path(cell.suite.items).is_absolute()
            else Path(cell.suite.items))


def cmd_run_local(args) -> int:
    """Run a quality cell from here rather than as a Job.

    Legitimate only for quality cells: they are deterministic and one request at a time, so where the
    client runs does not change the answer. A perf cell measures latency under load and must run in the
    cluster, next to nothing else — which is why this refuses one.
    """
    from . import runner

    PLUGINS = _plugins()
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
        task = _build_task(plugin, _items_path(cell, args), args)
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


def cmd_score(args) -> int:
    """Re-run a scorer over responses already on disk, at a new score version.

    The artifacts were split into `response` and `score` precisely so this could exist: what happened never
    changes, and what it is worth is an opinion that can be corrected without spending a GPU or an API
    again. The summarisation family needed it on its first run — its v1 thresholds turned out to rank the
    document's own opening above the human reference summary — and re-scoring stored replies is the honest
    repair, because the replies are not a function of the scorer.

    That last claim is load-bearing, so it is worth saying where it comes from rather than asserting it:
    nothing in `runner.run_quality_cell` branches on a verdict. There is one request per item, no retry on
    a failed score, no sampling and selecting, and the excluded set is decided by whether the transport
    returned text — not by whether the answer was any good. So a corrected scorer sees exactly the replies
    the layers gave.

    Two things this prints that a single run does not. A **band**: when a family declares the region of its
    threshold grid where every calibration control still holds, the admission decision is reported at every
    cell of it, because a decision that flips inside the region the calibration could not distinguish is
    not a decision. And the **resolution**: the tightest margin this many paired items could certify at
    all, so a margin the design could never have refused is not quoted as if it had been tested.
    """
    from . import runner, scorers

    PLUGINS = _plugins()
    run = spec.load_run(args.run)
    cells = [c for c in run.cells if c.id in args.cells] if args.cells else list(run.cells)
    version = args.score_version

    scored_cells: dict[str, dict] = {}
    for cell in cells:
        if cell.kind != "quality":
            continue
        plugin = PLUGINS.get(cell.suite.task_plugin)
        if plugin is None:
            print(f"[SKIP] {cell.id}: no plugin for {cell.suite.task_plugin}", file=sys.stderr)
            continue
        out_dir = args.run_dir / cell.id
        replies_path = out_dir / "response.jsonl"
        if not replies_path.exists():
            print(f"[SKIP] {cell.id}: no response.jsonl to re-score", file=sys.stderr)
            continue

        task = _build_task(plugin, _items_path(cell, args), args)
        replies = {}
        for line in replies_path.read_text().split("\n"):
            if line.strip():
                row = json.loads(line)
                replies[row["item_id"]] = row

        measures: dict[str, dict | None] = {}
        verdicts, missing = [], 0
        for item in task.load(limit=args.limit):
            reply = replies.get(item.id)
            if reply is None:
                missing += 1
                continue
            # The same rule the run used: text present and no transport error. Re-deriving it here rather
            # than trusting a stored verdict keeps the excluded set independent of any scorer.
            if not reply.get("text") or reply.get("error"):
                measures[item.id] = None
                verdicts.append({"item_id": item.id, "cell_id": cell.id, "layer": cell.layer.id,
                                 "passed": None, "excluded": "transport",
                                 "detail": reply.get("error") or "no answer"})
                continue
            verdict = task.score(item, reply["text"])
            measures[item.id] = (task.measure(item, reply["text"])
                                 if hasattr(task, "measure") else None)
            verdicts.append({"item_id": item.id, "cell_id": cell.id, "layer": cell.layer.id,
                             **{k: v for k, v in asdict(verdict).items() if k != "item_id"},
                             "excluded": None})

        (out_dir / f"score.{version}.jsonl").write_text(
            "".join(json.dumps(v, ensure_ascii=False) + "\n" for v in verdicts))
        graded = [v for v in verdicts if v["excluded"] is None]
        passed = sum(1 for v in graded if v["passed"])
        summary = {"cell_id": cell.id, "layer": cell.layer.id, "family": cell.suite.family,
                   "score_version": version, "items": len(verdicts), "scored": len(graded),
                   "excluded_transport": len(verdicts) - len(graded), "missing_responses": missing,
                   "passed": passed,
                   "rate": passed / len(graded) if graded else None,
                   "wilson_lower_80": (scorers.wilson_lower(passed, len(graded), 0.80)
                                       if graded else None)}
        (out_dir / f"summary.{version}.json").write_text(json.dumps(summary, indent=2))
        scored_cells[cell.id] = {"cell": cell, "measures": measures, "task": task,
                                 "summary": summary}
        rate = f"{summary['rate']:.3f}" if summary["rate"] is not None else "n/a"
        print(f"[{version}] {cell.id:<22} {passed}/{len(graded)} = {rate}"
              f"  (excluded {summary['excluded_transport']}, missing {missing})")

    box = next((v for v in scored_cells.values() if v["cell"].layer.kind == "self_hosted"), None)
    base = next((v for v in scored_cells.values()
                 if v["cell"].layer.id == v["cell"].suite.baseline_layer), None)
    if not (box and base):
        return 0

    floor = box["cell"].suite.floor
    margin = float(floor.get("margin_pp", 2.0))
    confidence = float(floor.get("confidence", 0.80))
    result = runner.compare(args.run_dir / box["cell"].id, args.run_dir / base["cell"].id,
                            margin_pp=margin, confidence=confidence, score_version=version)
    print(f"\n[PAIRED] {box['cell'].layer.id} vs {base['cell'].layer.id} on {result.n} shared items")
    print(f"  box {result.box_passed}/{result.n}, baseline {result.baseline_passed}/{result.n}, "
          f"discordant {result.only_baseline + result.only_box}")
    print(f"  difference {result.difference_pp:+.1f} pp, one-sided {confidence:.0%} lower bound "
          f"{result.lcb_pp:+.1f} pp against a margin of -{margin:.1f} pp")
    print(f"  -> {'non-inferior' if result.non_inferior else 'NOT non-inferior'} at this margin")

    resolution = scorers.minimum_detectable_margin_pp(
        result.n, result.only_baseline + result.only_box, confidence=confidence)
    if result.lcb_pp >= 0:
        # The bound is above zero, so the verdict does not rest on the margin at all: any margin would
        # have given the same answer, and the resolution is a fact about the design rather than a caveat.
        note = "which this verdict does not lean on, the bound being above zero"
    elif margin >= resolution:
        note = "which the quoted margin clears"
    else:
        note = ("and the quoted margin is finer than that, so this verdict rests on a margin the design "
                "could not have refused")
    print(f"  resolution: {result.n} paired items at {confidence:.0%} could certify no margin tighter "
          f"than {resolution:.2f} pp, {note}")

    # Written down rather than printed. A log line lives as long as the node does, and this one did not:
    # the pod that produced the first v2 comparison was gone before its output could be read.
    record = {"score_version": version, "box": box["cell"].layer.id, "baseline": base["cell"].layer.id,
              "margin_pp": margin, "confidence": confidence,
              "rates": {v["cell"].layer.id: v["summary"]["rate"] for v in scored_cells.values()},
              "paired": dict(result.__dict__) | {"non_inferior": result.non_inferior},
              "minimum_detectable_margin_pp": resolution, "band": []}

    region = getattr(box["task"], "admissible_thresholds", ())
    if region and all(v["measures"] for v in (box, base)):
        print(f"\n[BAND] the same decision at every threshold the calibration could not distinguish")
        verdicts = []
        for thresholds in region:
            for target in (box, base):
                for name, value in thresholds.items():
                    setattr(target["task"], name, value)
            shared = [k for k in box["measures"]
                      if box["measures"].get(k) and base["measures"].get(k)]
            pair = [(not box["task"].verdict_reasons(box["measures"][k]),
                     not base["task"].verdict_reasons(base["measures"][k])) for k in shared]
            band = scorers.paired_non_inferiority([p[0] for p in pair], [p[1] for p in pair],
                                                  margin_pp=margin, confidence=confidence)
            verdicts.append(band.non_inferior)
            record["band"].append({"thresholds": dict(thresholds), "n": band.n,
                                   "box_passed": band.box_passed,
                                   "baseline_passed": band.baseline_passed,
                                   "difference_pp": band.difference_pp, "lcb_pp": band.lcb_pp,
                                   "non_inferior": band.non_inferior})
            shown = " ".join(f"{k}={v}" for k, v in thresholds.items())
            print(f"  {shown:<52} box {band.box_passed}/{band.n} base {band.baseline_passed}/{band.n} "
                  f"diff {band.difference_pp:+5.1f} lcb {band.lcb_pp:+5.1f} "
                  f"-> {'non-inferior' if band.non_inferior else 'NOT'}")
        for target in (box, base):
            for name in region[0]:
                setattr(target["task"], name, getattr(type(target["task"]), name))
        stable = len(set(verdicts)) == 1
        if stable:
            print("  -> the decision is stable across the whole region")
        else:
            print("  -> the decision FLIPS inside the region, so this run does not decide: the "
                  "verdict is an artefact of where the threshold was put")
        record["band_stable"] = stable
    (args.run_dir / f"paired.{version}.json").write_text(json.dumps(record, indent=2))
    print(f"\n[OK] wrote {args.run_dir / f'paired.{version}.json'}")
    return 0


def cmd_price(args) -> int:
    """Re-price a recorded run from the token counts it already wrote, without sending anything.

    The symmetric operation to `score`. `score` exists because a verdict is an opinion about a reply and can
    be corrected; a price is an opinion about a token count and can be corrected the same way, from the four
    counts the provider reported. Neither needs the layer spent again.

    It exists because it was needed. Every api layer's rates had been typed into the specs by hand, and
    `gemma-4` was carried at $0.30 input against the gateway's own $5.00 — understating its measured cost 17x
    and putting it on two published frontiers as the cheapest layer. The rates now resolve from the gateway's
    card, but the runs on disk were priced with the old numbers, and re-running four layers over 278 images to
    fix a multiplication would be absurd.

    The box is left alone. Its money figure is derived from measured throughput at full occupancy rather than
    from anyone's rate card, so there is nothing here to resolve for it.
    """
    run = spec.load_run(args.run)
    layers = {c.layer.id: c.layer for c in run.cells}
    changed = 0
    print(f"{'cell':28} {'layer':20} {'was':>11} {'now':>11} {'change':>8}")
    for cell in run.cells:
        if cell.kind != "quality":
            continue
        out_dir = args.run_dir / cell.id
        cost_path, summary_path = out_dir / "cost.jsonl", out_dir / "summary.json"
        if not (cost_path.exists() and summary_path.exists()):
            continue
        layer = layers[cell.layer.id]
        rows = [json.loads(line) for line in cost_path.read_text().split("\n") if line.strip()]
        summary = json.loads(summary_path.read_text())
        if layer.kind != "api":
            print(f"{cell.id:28} {layer.id:20} "
                  f"{summary.get('box_usd_at_full_utilisation', 0.0):11.5f} "
                  f"{'':>11} {'box':>8}")
            continue
        if layer.pricing_status == "placeholder" or layer.input_usd_per_mtok is None:
            # Deliberately unpriced: no source for its rate, so it is compared on quality and latency and
            # not on cost. Pricing it at zero would be the worst available answer, and an earlier draft of
            # this command did exactly that.
            print(f"{cell.id:28} {layer.id:20} "
                  f"{'null' if summary.get('api_usd') is None else format(float(summary['api_usd']), '.5f'):>11} "
                  f"{'':>11} {'unpriced':>8}")
            if summary.get("api_usd") is not None and not args.dry_run:
                # Null, not zero. A zero would join every cost comparison as the cheapest layer there is.
                summary_path.write_text(json.dumps(
                    summary | {"api_usd": None, "pricing_status": "placeholder",
                               "pricing_key": layer.pricing_key,
                               "api_usd_superseded": summary.get("api_usd")}, indent=2))
                cost_path.write_text("".join(
                    json.dumps(r | {"api_usd": None}, ensure_ascii=False) + "\n" for r in rows))
                changed += 1
            continue

        priced = []
        total = 0.0
        for row in rows:
            detail = row.get("detail") or {}
            fresh = int(detail.get("fresh_prompt_tokens") or 0)
            cached = int(detail.get("cached_prompt_tokens") or 0)
            completion = int(detail.get("completion_tokens") or 0)
            cache_rate = (layer.cache_read_usd_per_mtok
                          if layer.cache_read_usd_per_mtok is not None
                          else (layer.input_usd_per_mtok or 0.0))
            usd = (fresh * (layer.input_usd_per_mtok or 0.0)
                   + cached * cache_rate
                   + completion * (layer.output_usd_per_mtok or 0.0)) / 1_000_000
            total += usd
            priced.append(row | {"api_usd": usd,
                                 "detail": detail | {"pricing_status": layer.pricing_status,
                                                     "pricing_key": layer.pricing_key}})
        was = float(summary.get("api_usd") or 0.0)
        ratio = (total / was) if was else 0.0
        print(f"{cell.id:28} {layer.id:20} {was:11.5f} {total:11.5f} {ratio:7.2f}x")
        if abs(total - was) < 1e-12:
            continue
        changed += 1
        if args.dry_run:
            continue
        cost_path.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in priced))
        summary_path.write_text(json.dumps(
            summary | {"api_usd": total, "pricing_status": layer.pricing_status,
                       "pricing_key": layer.pricing_key,
                       # Kept, because a reader of this file should be able to see that it moved and by how
                       # much without going to git for it.
                       "api_usd_superseded": was}, indent=2))
    verb = "would change" if args.dry_run else "rewrote"
    print(f"\n[OK] {verb} {changed} cell(s)")
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
    table = routing_table.merge(existing, run, args.run_dir, args.cells,
                                score_version=args.score_version)
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
    p.add_argument("--score-version", default="v1",
                   help="which scorer's opinion to merge; a corrected scorer writes a new version")
    p.set_defaults(func=cmd_table)

    p = sub.add_parser("manifest", help="print the expanded, immutable run manifest")
    p.add_argument("run", type=Path)
    p.set_defaults(func=cmd_manifest)

    p = sub.add_parser("score", help="re-run a scorer over existing responses, without a GPU")
    p.add_argument("run", type=Path)
    p.add_argument("--run-dir", type=Path, required=True)
    p.add_argument("--score-version", default="v2")
    p.add_argument("--cells", nargs="*", default=None)
    p.add_argument("--limit", type=int, default=None)
    p.add_argument("--spec-root", type=Path, default=Path("."))
    p.add_argument("--labels", default="ポジティブ,ニュートラル,ネガティブ")
    p.set_defaults(func=cmd_score)

    p = sub.add_parser("price", help="re-price a recorded run from its own token counts, sending nothing")
    p.add_argument("run", type=Path)
    p.add_argument("--run-dir", type=Path, required=True)
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(func=cmd_price)

    for name, help_text in (
        ("submit", "create one Job per cell"),
        ("collect", "copy artifacts off the shared volume and summarise"),
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
