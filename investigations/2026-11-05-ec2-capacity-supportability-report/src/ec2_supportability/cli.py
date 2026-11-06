"""Command line: arguments and environment variables, the run, and where its output goes.

Standard output carries only the result in the chosen --output format. Progress, warnings and the reasons a run was
not complete go to standard error, and the exit status says whether the run was complete.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import signal
import sys
import webbrowser
from datetime import datetime
from pathlib import Path

import boto3
from botocore.exceptions import BotoCoreError, ClientError

from . import __version__, document, formats, report_html
from .collect import (DEFAULT_AZS, DEFAULT_TYPES, JST, NAME, QUOTA_HEADROOM, QUOTA_PER_HOUR, Result, az_sort_key,
                      ensure_manager, err_text, exit_status, plan_calls, preflight, run_query, summarize)
from .files import new_work_file, place_report, refuse_existing

ENV_PREFIX = "EC2_SUPPORTABILITY_"
# Options that can also come from EC2_SUPPORTABILITY_<OPTION>; True marks a list (split on spaces or commas).
# --enable and --overwrite are left out on purpose: changing the account or replacing a file is asked for on the
# command line, never inherited from the environment. So are --query and --env-prefix, which decide what a script
# that evaluates the output receives. AWS_REGION is not read either: Capacity Manager can be enabled
# in only one Region per account, so that Region is never taken from whatever the shell happens to have.
ENV_OPTIONS = {"--region": False, "--profile": False, "--types": True, "--requirements": False, "--azs": True,
               "--markets": True, "--amounts": True, "--unit": False, "--expect-account": False, "--max-calls": False,
               "--output": False, "--lang": False}

EPILOG = """\
The scores are EC2 Capacity Manager data under the AWS Service Terms: use them for your own capacity planning and
workload management, and do not disclose them to third parties other than contractors or agents acting on your
behalf. CI logs and shared dashboards widen who can read standard output.

Every option above except --enable, --overwrite, --query, --env-prefix, --html, --save-json, --from-json and --open can be set as
EC2_SUPPORTABILITY_<OPTION> (for example EC2_SUPPORTABILITY_REGION, EC2_SUPPORTABILITY_TYPES="c7g.xlarge m7g.xlarge").
An option given on the command line wins.

Exit status: 0 complete; 1 authentication or --expect-account; 2 usage, --query or data-file error; 3 not complete
(the scores that were collected are still printed); 4 an output file could not be placed; 5 unexpected error;
6 the plan exceeds --max-calls; 130 interrupted.
"""


# Options that take each other's place: one given on the command line also silences the other's variable.
SAME_SLOT = {"--types": "--requirements", "--requirements": "--types"}


def env_arguments(environ, argv) -> list:
    """[(variable, tokens)] for the options set in the environment and not given on the command line.

    A variable only ever supplies the value of its own option. A scalar becomes one `--option=value` token, so a value
    that starts with "-" stays a value, and a list item that starts with "-" is refused, so no variable can add an
    option such as --enable that the command line did not ask for.
    """
    given = {t.split("=", 1)[0] for t in argv if t.startswith("-")}
    if given & {"-h", "--help", "--version"}:
        return []
    out = []
    for flag, is_list in ENV_OPTIONS.items():
        if flag in given or SAME_SLOT.get(flag) in given or ("--from-json" in given and flag in SAME_SLOT):
            continue
        name = ENV_PREFIX + flag[2:].upper().replace("-", "_")
        value = environ.get(name, "").strip()
        if not value:
            continue  # an empty variable (docker run -e NAME=) means "not set"
        if is_list:
            items = [v for v in re.split(r"[,\s]+", value) if v]
            bad = [v for v in items if v.startswith("-")]
            if bad:
                raise ValueError(f"{name}: a list item may not start with '-' ({bad[0]!r})")
            out.append((name, [flag, *items]))
        else:
            out.append((name, [f"{flag}={value}"]))
    return out


def _clean(parser, option, values):
    out = [v.strip().lower() for v in values]
    if any(not v for v in out):
        parser.error(f"{option} must not contain empty values")
    bad = [v for v in out if not NAME.match(v)]
    if bad:
        parser.error(f"{option}: {bad[0]!r} is not an instance type or AZ ID (letters, digits, '.' and '-' only)")
    return out


def build_parser(**kw) -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="ec2-supportability", epilog=EPILOG, allow_abbrev=False, **kw,
                                description="Check EC2 Capacity Manager supportability scores (High, Medium, Low) for "
                                            "instance type x Availability Zone pairs and print them.",
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    g = p.add_argument_group("what to check")
    g.add_argument("--region", default=None,
                   help="Region where Capacity Manager is (or will be) enabled; the API is called here. "
                        "Required: it can be enabled in only one Region per account, so a wrong default would steer --enable there")
    g.add_argument("--profile", default=None, help="AWS profile name (default: the usual AWS credential chain)")
    g.add_argument("--types", nargs="+", default=None,
                   help="instance types to score (default: a GPU, Trainium and general-purpose sample)")
    g.add_argument("--requirements", default=None,
                   help="JSON for InstanceRequirementsWithMetadata (attribute-based selection); replaces --types. "
                        'The API requires "VirtualizationTypes", e.g. {"ArchitectureTypes":["x86_64"],'
                        '"VirtualizationTypes":["hvm"],"InstanceRequirements":{"VCpuCount":{"Min":4,"Max":4},'
                        '"MemoryMiB":{"Min":16384,"Max":16384}}}')
    g.add_argument("--azs", nargs="+", default=DEFAULT_AZS, help="AZ IDs, e.g. apne1-az4; Regions may be mixed")
    g.add_argument("--markets", nargs="+", default=["on-demand", "spot"], choices=["on-demand", "spot"])
    g.add_argument("--amounts", nargs="+", type=int, default=[1, 10, 100],
                   help="requested amounts; every score is relative to the amount")
    g.add_argument("--unit", default="instances", choices=["instances", "vcpus"])
    g = p.add_argument_group("safety")
    g.add_argument("--enable", action="store_true",
                   help="enable Capacity Manager in --region if it is disabled (one Region per account); requires --expect-account")
    g.add_argument("--expect-account", default=None, metavar="ACCOUNT_ID",
                   help="refuse to run unless the caller is in this 12-digit account; required with --enable so the account is "
                        "never changed by accident")
    g.add_argument("--max-calls", type=int, default=QUOTA_PER_HOUR - QUOTA_HEADROOM, metavar="N",
                   help="refuse to start when this run plans more than N API calls (default 95). The quota of 100 per hour is "
                        "shared by the whole account, so lower this when others use it too")
    g = p.add_argument_group("output")
    g.add_argument("--output", default="table", choices=formats.FORMATS,
                   help="standard output format: table (default, for people), json (the whole data document), "
                        "text (tab-separated, no header) or env (export lines for eval)")
    g.add_argument("--query", default=None, metavar="JMESPATH",
                   help="JMESPath expression run on the json document; the chosen --output prints its result, "
                        "e.g. \"scores[?score=='high'].[instance_type,az_id]\"")
    g.add_argument("--env-prefix", default="CS_", metavar="PREFIX", help="prefix of the variable names --output env prints (default CS_)")
    g.add_argument("--html", default=None, metavar="FILE", help="also write the bilingual HTML report to FILE")
    g.add_argument("--save-json", default=None, metavar="FILE",
                   help="also write the data document to FILE; --from-json reads it back later")
    g.add_argument("--overwrite", action="store_true", help="replace --html or --save-json files that already exist (default: refuse)")
    g.add_argument("--lang", default=None, choices=["en", "ja"],
                   help="language the HTML report opens in, overriding the language the browser saved (default: the saved choice, else English)")
    g.add_argument("--open", action="store_true", help="open the --html report in the default browser when done")
    g.add_argument("--from-json", default=None, metavar="FILE",
                   help="do not call AWS: print (and optionally --html or --save-json) a data document saved by an earlier run")
    return p


def parse_args(argv=None, environ=None):
    p = build_parser()
    argv = list(sys.argv[1:] if argv is None else argv)
    try:
        from_env = env_arguments(os.environ if environ is None else environ, argv)
    except ValueError as e:
        p.error(str(e))
    checker = build_parser(exit_on_error=False)
    for name, tokens in from_env:
        try:
            checker.parse_args(tokens)
        except argparse.ArgumentError as e:
            p.error(f"{name}: {e}")
    a = p.parse_args([t for _name, tokens in from_env for t in tokens] + argv)
    if a.from_json is None and not a.region:
        p.error("--region is required (unless --from-json is used)")
    if a.from_json is not None and (a.enable or a.requirements is not None):
        p.error("--from-json does not call AWS; --enable and --requirements do not apply")
    if any(x < 1 for x in a.amounts):
        p.error("--amounts must be positive integers")
    if not 1 <= a.max_calls <= QUOTA_PER_HOUR:
        p.error(f"--max-calls must be between 1 and {QUOTA_PER_HOUR}")
    if a.enable and not a.expect_account:
        p.error("--enable requires --expect-account ACCOUNT_ID")
    if a.expect_account is not None and not (a.expect_account.isdigit() and len(a.expect_account) == 12):
        p.error("--expect-account must be a 12-digit account ID")
    if a.open and a.html is None:
        p.error("--open opens the --html report; give --html FILE")
    for name in ("html", "save_json"):
        v = getattr(a, name)
        if v is not None and not v.strip():
            p.error(f"--{name.replace('_', '-')} must not be empty")
    if a.html and a.save_json and Path(a.html).expanduser() == Path(a.save_json).expanduser():
        p.error("--html and --save-json must be different files")
    try:
        a.query = formats.compile_query(a.query) if a.query is not None else None
        formats.check_env_prefix(a.env_prefix)
    except ValueError as e:
        p.error(str(e))
    # Repeated values would run the same query twice and the later run would overwrite the earlier one.
    a.amounts = sorted(set(a.amounts))
    a.markets = list(dict.fromkeys(a.markets))
    if a.requirements is not None and a.types is not None:
        p.error("--types and --requirements cannot be used together")
    # Trim and lower-case so " M7I.large" and "m7i.large" are one value and an empty value is refused at the entry.
    a.types = list(dict.fromkeys(_clean(p, "--types", a.types if a.types is not None else DEFAULT_TYPES)))
    # Keep the AZs of one Region together so the table's Region headings are not split.
    a.azs = sorted(set(_clean(p, "--azs", a.azs)), key=az_sort_key)
    if any(x > 100000 for x in a.amounts) and a.unit == "instances":
        print("Warning: the API refused an amount above 100000 instances when this was tried (2026-11-05); "
              "that request will probably fail.", file=sys.stderr)
    if a.requirements is not None:
        try:
            a.requirements = json.loads(a.requirements)
        except json.JSONDecodeError as e:
            p.error(f"--requirements is not valid JSON: {e}")
        if not isinstance(a.requirements, dict) or not a.requirements:
            p.error("--requirements must be a non-empty JSON object")
        for key in ("ArchitectureTypes", "VirtualizationTypes"):
            v = a.requirements.get(key)
            if v is not None and not (isinstance(v, list) and all(isinstance(x, str) for x in v)):
                p.error(f"--requirements: {key} must be a list of strings")
        if not isinstance(a.requirements.get("InstanceRequirements", {}), dict):
            p.error("--requirements: InstanceRequirements must be an object")
        if "VirtualizationTypes" not in a.requirements:
            print("Warning: the API answered MissingParameter when VirtualizationTypes was left out (2026-11-05); "
                  'add "VirtualizationTypes":["hvm"] to --requirements.', file=sys.stderr)
    return a


def planned_calls(args) -> int:
    per_run = len(plan_calls(None if args.requirements is not None else args.types, args.azs))
    return len(args.markets) * len(args.amounts) * per_run


def valid_identity(identity) -> bool:
    return isinstance(identity, dict) and isinstance(identity.get("Account"), str) and isinstance(identity.get("Arn"), str)


_critical = {"on": False, "pending": False}


def _interrupt(signum, frame):
    """End the run like Ctrl-C, except while files are being placed: finish that step first."""
    if _critical["on"]:
        _critical["pending"] = True
        return
    raise KeyboardInterrupt


def main(argv=None, environ=None) -> int:
    args = parse_args(argv, environ)
    # Ctrl-C, SIGTERM and SIGHUP all end the run the same way, and none of them lands while files are being placed.
    _critical.update(on=False, pending=False)
    previous = {}
    for name in ("SIGINT", "SIGTERM", "SIGHUP"):
        if hasattr(signal, name):
            try:
                sig = getattr(signal, name)
                if signal.getsignal(sig) != signal.SIG_IGN:  # keep `nohup` working
                    previous[sig] = signal.signal(sig, _interrupt)
            except ValueError:  # not the main thread
                pass
    try:
        return _run(args)
    except KeyboardInterrupt:
        print("Interrupted. Requests already sent still count against the hourly quota; if --enable had already "
              "run, the change stays in place; files already placed stay where they are.", file=sys.stderr)
        return 130
    except Exception as e:  # never a traceback and exit 1, which means an authentication failure here
        print(f"Unexpected error: {type(e).__name__}: {e}", file=sys.stderr)
        return 5
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def _stamp() -> str:
    return datetime.now(JST).strftime("%Y%m%d-%H%M%S-%f")


def _same_place(a: Path, b: Path) -> bool:
    """True when two spellings may reach one directory entry (a/../b, a symbolic link, letter case)."""
    def key(p):
        return os.path.normcase(os.path.realpath(p)).casefold()
    if key(a) == key(b):
        return True
    try:
        # Names that differ only in case are treated as one file everywhere, because macOS and Windows volumes
        # usually ignore case and normcase does not fold it on macOS.
        return os.path.samefile(a.parent, b.parent) and a.name.casefold() == b.name.casefold()
    except OSError:
        return False


def _targets(args, reading=None):
    """[(kind, path)] for the files asked for, or an error message when one cannot be used."""
    try:
        targets = [(kind, Path(v).expanduser()) for kind, v in (("json", args.save_json), ("html", args.html)) if v]
        if len(targets) == 2 and _same_place(targets[0][1], targets[1][1]):
            return None, "--html and --save-json name the same file; give two different paths."
        for _kind, path in targets:
            problem = refuse_existing(path, args.overwrite)
            if not problem and reading is not None and _same_place(path, reading):
                problem = f"{path} is the data file being read; give another path."
            if problem:
                return None, problem
    except (OSError, RuntimeError) as e:  # an unreadable parent, or ~user that does not exist
        return None, f"An output path cannot be used: {e}."
    return targets, None


def _open_work(targets):
    """Create the owner-only temporary files next to each target. Returns [(kind, path, handle, work)]."""
    opened = []
    try:
        for kind, path in targets:
            fh, work = new_work_file(path)
            opened.append((kind, path, fh, work))
    except OSError:
        _discard(opened)
        raise
    return opened


def _discard(opened):
    """Best effort: a close that fails again (a full disk) must not hide the error that led here."""
    for _kind, _path, fh, work in opened:
        try:
            if not fh.closed:
                fh.close()
        except OSError:
            pass
        try:
            work.unlink(missing_ok=True)
        except OSError:
            pass


def _write_and_place(opened, text_of, status, overwrite):
    """Write each file, then move it into place. Returns (final paths, notes, all placed).

    A file that cannot be written (a full disk, an I/O error) is a file problem like one that cannot be placed: the
    temporary files are removed, nothing reaches the paths, and the caller still prints the result.
    """
    try:
        for kind, _path, fh, _work in opened:
            fh.write(text_of(kind))
            fh.close()
    except OSError as e:
        _discard(opened)
        return [], [f"The output files could not be written ({e}); none was placed."], False
    stamp, finals, notes, all_ok, json_ok = _stamp(), [], [], True, True
    _critical["on"] = True
    try:
        # The data file is the source of the page, so it goes first; if it cannot be placed, the page is kept beside it.
        for kind, path, _fh, work in opened:
            side = "unplaced" if kind == "html" and not json_ok and status == 0 else None
            final, note, ok = place_report(work, path, status, overwrite, stamp, force_side=side)
            finals.append(final)
            if note:
                notes.append(note)
            all_ok = all_ok and ok
            if kind == "json":
                json_ok = ok
    finally:
        _critical["on"] = False
    return finals, notes, all_ok


def _emit(args, doc) -> int:
    """Print the document in the chosen format. Returns 0, or 2 when the query result does not fit the format."""
    color = args.output == "table" and sys.stdout.isatty() and not os.environ.get("NO_COLOR")
    try:
        text = formats.render(doc, args.output, args.query, args.env_prefix, color)
    except formats.OutputError as e:
        print(f"Cannot print the result: {e}", file=sys.stderr)
        return 2
    try:
        if hasattr(sys.stdout, "reconfigure"):
            # A character the output encoding lacks (a --query literal on a cp1252 console) is escaped, not fatal.
            sys.stdout.reconfigure(errors="backslashreplace")
        if text:
            print(text)
        sys.stdout.flush()
    except BrokenPipeError:
        # The reader stopped early (`| head -1`). That is its choice, not a failure of the run; send what is left of
        # the output nowhere so that Python does not report the closed pipe again at exit.
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
    return 0


def _open_page(args, finals):
    """Open the HTML report with standard output pointed at standard error, so no browser message reaches the data."""
    pages = [f for f in finals if f.suffix.lower() in (".html", ".htm")] or finals[-1:]
    if not (args.open and pages):
        return
    sys.stdout.flush()
    saved = os.dup(1)
    try:
        os.dup2(2, 1)
        webbrowser.open(pages[-1].resolve().as_uri())
    finally:
        os.dup2(saved, 1)
        os.close(saved)


def _render_only(args) -> int:
    """--from-json: print a saved data document. No AWS calls, no credentials needed."""
    source = Path(args.from_json).expanduser()
    try:
        ctx = document.from_data(document.load_data(source), args.lang or "en", args.lang is not None)
    except (ValueError, OSError, RecursionError) as e:
        print(f"Cannot use the data file: {e}", file=sys.stderr)
        return 2
    doc = document.to_data(ctx)  # recompute the derived lists, so a /1 file prints like a new one
    targets, problem = _targets(args, reading=source)
    if problem:
        print(problem, file=sys.stderr)
        return 4
    try:
        opened = _open_work(targets)
    except OSError as e:
        print(f"Cannot create a file next to the output: {e}.", file=sys.stderr)
        return 4
    placed_ok, finals, notes = True, [], []
    if opened:
        done = False
        try:
            data_text = json.dumps(doc, indent=2, ensure_ascii=False) + "\n"
            # A page made from the data of an incomplete run keeps that fact in its name, like the run itself did.
            finals, notes, placed_ok = _write_and_place(
                opened, lambda k: data_text if k == "json" else report_html.render(ctx), ctx["status"], args.overwrite)
            done = True
        except Exception as e:
            print(f"Unexpected error: {type(e).__name__}: {e}", file=sys.stderr)
            return 5
        finally:
            if not done:
                _discard(opened)
    for n in notes:
        print(n, file=sys.stderr)
    for f in finals:
        print(f"Wrote {f}", file=sys.stderr)
    if ctx["status"] != 0:
        print(f"Note: the run that produced this data ended with exit status {ctx['status']} (result: incomplete).",
              file=sys.stderr)
    if _critical["pending"]:
        _critical["pending"] = False
        raise KeyboardInterrupt
    emitted = _emit(args, doc)
    _open_page(args, finals)
    # The exit status is the saved run's (0 or 3), so replaying an incomplete run never looks complete.
    status = ctx["status"] or (0 if placed_ok else 4)
    return status or emitted


def _run(args) -> int:
    if args.from_json is not None:
        return _render_only(args)
    requirements = args.requirements
    try:
        session = boto3.Session(profile_name=args.profile) if args.profile else boto3.Session()
        ec2 = session.client("ec2", region_name=args.region)
        identity = session.client("sts", region_name=args.region).get_caller_identity()
    except (ClientError, BotoCoreError) as e:
        print(f"Authentication failed: {err_text(e)}", file=sys.stderr)
        return 1
    if not valid_identity(identity):
        print("Authentication failed: the caller identity response was not usable", file=sys.stderr)
        return 1

    if args.expect_account and identity["Account"] != args.expect_account:
        print(f"The caller is in account {identity['Account']}, not the expected {args.expect_account}. Nothing was changed.",
              file=sys.stderr)
        return 1
    n_calls = planned_calls(args)
    if n_calls > args.max_calls:
        print(f"This run plans {n_calls} calls, more than {args.max_calls} (the quota is "
              f"{QUOTA_PER_HOUR} per account per hour, shared by everyone in the account). "
              "Calls already made this hour are not counted. Reduce markets, amounts, types or AZs.", file=sys.stderr)
        return 6

    targets, problem = _targets(args)
    if problem:
        print(f"{problem} Nothing was changed in the account.", file=sys.stderr)
        return 4
    try:
        opened = _open_work(targets)
    except OSError as e:
        print(f"Cannot create a file next to the output: {e}. Nothing was changed in the account.", file=sys.stderr)
        return 4
    print(f"Account {identity['Account']}; {n_calls} calls planned", file=sys.stderr)

    retry_budget = [max(0, args.max_calls - n_calls)]  # repeats after dropping a rejected value must stay inside the cap
    known_bad = set()
    done = False
    try:
        pf = preflight(session, None if requirements is not None else args.types, args.azs)
        state, log = ensure_manager(ec2, args.enable)
        for en, _ in log:
            print(en, file=sys.stderr)

        results = {m: {} for m in args.markets}
        calls = 0
        for m in args.markets:
            for amt in args.amounts:
                if state["enabled"] and pf.azs and (requirements is not None or pf.types):
                    res = run_query(ec2, m, amt, args.unit, pf.types, pf.azs, requirements, retry_budget, known_bad)
                    calls += res.sent
                    bad = sum(1 for g in res.groups if g.error)
                    print(f"  {m:9s} x{amt:<6d} rows {len(res.cells):3d}  errors {bad}", file=sys.stderr)
                else:
                    res = Result()
                results[m][amt] = res

        status = exit_status(state, results, pf)
        reasons = summarize(state, results, pf)
        collected = {"identity": identity, "region": args.region, "state": state, "log": log, "status": status,
                     "now": datetime.now(JST).strftime("%Y-%m-%d %H:%M:%S"),
                     "types": None if requirements is not None else args.types, "requirements": requirements,
                     "azs": pf.azs, "pf": pf,
                     "markets": args.markets, "amounts": args.amounts, "unit": args.unit,
                     "results": results, "calls": calls, "reasons": reasons}
        # One document is the single source of every output: serialise it, read it back, and print and render
        # only what was read, so a saved file always reproduces exactly what this run showed.
        data_text = json.dumps(document.to_data(collected), indent=2, ensure_ascii=False) + "\n"
        doc = json.loads(data_text)
        ctx = document.from_data(doc, args.lang or "en", args.lang is not None)
        finals, notes, placed_ok = [], [], True
        if opened:
            finals, notes, placed_ok = _write_and_place(
                opened, lambda k: data_text if k == "json" else report_html.render(ctx), status, args.overwrite)
        done = True
        if status == 0 and not placed_ok:
            status = 4  # the run itself was fine, but a file is not at the path that was asked for
        if _critical["pending"]:
            _critical["pending"] = False
            raise KeyboardInterrupt
    except Exception as e:  # report any unexpected failure with its own exit status
        print(f"Unexpected error: {type(e).__name__}: {e}", file=sys.stderr)
        return 5
    finally:
        if not done:
            # An interrupted or crashed run leaves no half-written file behind and never touches the target paths.
            # If the account was changed before that, the messages above say so.
            _discard(opened)
    if status != 0:
        print(f"RESULT: INCOMPLETE (exit status {status})", file=sys.stderr)
        for r in reasons:
            print(f"  - {r}", file=sys.stderr)
    else:
        print("RESULT: complete", file=sys.stderr)
    for n in notes:
        print(n, file=sys.stderr)
    for f in finals:
        print(f"Wrote {f}", file=sys.stderr)
    emitted = _emit(args, doc)
    if emitted and args.save_json and finals:
        print(f"The data was saved; print it another way with --from-json {finals[0]}", file=sys.stderr)
    _open_page(args, finals)
    # A run that was not complete keeps saying so even when printing failed too.
    return status or emitted
