"""Tests of what the command prints: the four --output formats, --query, the environment variables it reads, and
the rule that nothing is written to disk unless --html or --save-json asks for it.
"""
import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from test_cli import FakeEc2

from ec2_supportability import cli, collect, document, formats

TYPES = ["a.large", "b.large"]
AZS = ["use1-az1", "use1-az2"]


class Dropping(FakeEc2):
    """Leaves one pair out of a successful response, as the API was seen to do (2026-11-05)."""

    def __init__(self, drop, **kw):
        super().__init__(**kw)
        self.drop = set(drop)

    def get_capacity_manager_supportability_scores(self, **kw):
        r = super().get_capacity_manager_supportability_scores(**kw)
        r["CapacityManagerSupportabilityScores"] = [
            x for x in r["CapacityManagerSupportabilityScores"]
            if (x["InstanceType"], x["AvailabilityZoneId"]) not in self.drop]
        return r


def run(ec2, *argv, environ=None, cwd=None):
    """Run the command against a fake account. Returns (exit status, stdout, stderr, Session calls)."""
    sessions = []

    class STS:
        def get_caller_identity(self):
            return {"Account": "111122223333", "Arn": "arn:test"}

    class Session:
        def __init__(self, **kw):
            sessions.append(kw)

        def client(self, service, **kw):
            return ec2 if service == "ec2" else STS()

    out, err = io.StringIO(), io.StringIO()
    with mock.patch.object(cli.boto3, "Session", Session), mock.patch.object(collect.time, "sleep"), \
            contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            rc = cli.main(list(argv), environ=environ if environ is not None else {})
        except SystemExit as e:  # argparse
            rc = e.code
    return rc, out.getvalue(), err.getvalue(), sessions


BASE = ("--region", "us-east-1", "--types", *TYPES, "--azs", *AZS, "--markets", "on-demand", "--amounts", "50")


class NothingOnDiskByDefault(unittest.TestCase):
    def test_a_plain_run_prints_a_table_and_writes_no_file(self):
        with tempfile.TemporaryDirectory() as d:
            here = os.getcwd()
            os.chdir(d)
            try:
                with mock.patch.dict(os.environ, {"HOME": d}):
                    rc, out, _err, _ = run(FakeEc2(score="high", aggregate="high"), *BASE)
            finally:
                os.chdir(here)
            self.assertEqual(rc, 0)
            self.assertEqual(list(Path(d).rglob("*")), [])
        self.assertIn("On-Demand, 50 instances   aggregate: High", out)
        self.assertIn("a.large", out)

    def test_open_needs_html(self):
        rc, _out, err, sessions = run(FakeEc2(), *BASE, "--open")
        self.assertEqual(rc, 2)
        self.assertIn("--open", err)
        self.assertEqual(sessions, [])

    def test_option_prefixes_are_not_accepted(self):
        # --out used to be the report path; it must not silently become --output.
        rc, _out, err, _ = run(FakeEc2(), *BASE, "--out", "r.html")
        self.assertEqual(rc, 2)
        self.assertIn("unrecognized arguments", err)


class Formats(unittest.TestCase):
    def test_json_is_the_data_document_and_reads_back(self):
        rc, out, _err, _ = run(FakeEc2(), *BASE, "--output", "json")
        self.assertEqual(rc, 0)
        doc = json.loads(out)
        self.assertEqual(doc["schema"], document.SCHEMA)
        self.assertEqual(doc["result"], "complete")
        self.assertEqual(len(doc["scores"]), 4)
        document.from_data(doc)  # the printed document is a valid data file

    def test_text_rows_have_a_fixed_number_of_fields_per_record(self):
        rc, out, _err, _ = run(Dropping({("b.large", "use1-az2")}), *BASE, "--output", "text")
        self.assertEqual(rc, 0)
        width = {"RESULT": 5, "AGGREGATE": 6, "SCORE": 7}
        lines = out.splitlines()
        for line in lines:
            fields = line.split("\t")
            self.assertEqual(len(fields), width[fields[0]], line)
        self.assertIn("SCORE\ton-demand\t50\tb.large\tuse1-az2\tn/a\tmissing", lines)
        self.assertIn("SCORE\ton-demand\t50\ta.large\tuse1-az1\thigh\tscored", lines)

    def test_states_say_why_a_pair_has_no_score(self):
        # The API leaves out pairs that are not offered, as it was seen to (2026-11-05); preflight says why.
        ec2 = Dropping({("a.large", "use1-az2"), ("b.large", "use1-az1")}, not_offered={("b.large", "use1-az1")})
        rc, out, _err, _ = run(ec2, *BASE, "--output", "json")
        self.assertEqual(rc, 0)
        state = {(r["instance_type"], r["az_id"]): r["state"] for r in json.loads(out)["scores"]}
        self.assertEqual(state[("a.large", "use1-az1")], "scored")
        self.assertEqual(state[("a.large", "use1-az2")], "missing")
        self.assertEqual(state[("b.large", "use1-az1")], "not_offered")

    def test_a_failed_request_marks_its_pairs_failed_and_still_prints(self):
        rc, out, err, _ = run(FakeEc2(fail_all=True), *BASE, "--output", "json")
        self.assertEqual(rc, 3)
        doc = json.loads(out)
        self.assertEqual(doc["result"], "incomplete")
        self.assertEqual({r["state"] for r in doc["scores"]}, {"failed"})
        self.assertEqual([a["score"] for a in doc["aggregates"]], [None])
        self.assertIn("RESULT: INCOMPLETE", err)

    def test_nothing_sent_is_not_called_failed(self):
        rc, out, _err, _ = run(FakeEc2(disabled=True), *BASE, "--output", "json")
        self.assertEqual(rc, 3)
        self.assertEqual({r["state"] for r in json.loads(out)["scores"]}, {"not_sent"})

    def test_table_has_no_colour_codes_when_not_a_terminal(self):
        _rc, out, _err, _ = run(FakeEc2(), *BASE)
        self.assertNotIn("\x1b[", out)

    def test_table_explains_every_label_it_uses(self):
        _rc, out, _err, _ = run(Dropping({("b.large", "use1-az2")}), *BASE)
        self.assertIn("N/A", out)
        self.assertIn("N/A: the request succeeded but its response had no row for this pair. It is not Low.", out)
        self.assertNotIn("Not offered:", out)


@unittest.skipUnless(shutil.which("bash"), "bash is needed to evaluate the export lines")
class Env(unittest.TestCase):
    def bash(self, exports, script):
        return subprocess.run(["bash", "-c", exports + "\n" + script], capture_output=True, text=True, check=True).stdout

    def test_default_env_evaluates_to_the_scores(self):
        rc, out, _err, _ = run(FakeEc2(score="high", aggregate="medium"), *BASE, "--output", "env")
        self.assertEqual(rc, 0)
        got = self.bash(out, 'printf "%s|%s|%s" "$CS_RESULT" "$CS_AGGREGATE_ON_DEMAND_50" "$CS_HIGH_ON_DEMAND_50"')
        self.assertEqual(got, "complete|medium|a.large:use1-az1 a.large:use1-az2 b.large:use1-az1 b.large:use1-az2")

    def test_a_split_run_never_names_one_part_as_the_whole(self):
        types = [f"t{i}.large" for i in range(60)]  # more than 50 types: two requests
        rc, out, _err, _ = run(FakeEc2(), "--region", "us-east-1", "--types", *types, "--azs", "use1-az1",
                               "--markets", "on-demand", "--amounts", "50", "--output", "env")
        self.assertEqual(rc, 0)
        # The plain name is set, and empty, so an earlier eval cannot leave a whole-set value behind.
        self.assertIn("export CS_AGGREGATE_ON_DEMAND_50=''\n", out)
        self.assertIn("CS_AGGREGATE_ON_DEMAND_50_1=", out)
        self.assertIn("CS_AGGREGATE_ON_DEMAND_50_2=", out)

    def test_values_are_quoted_so_eval_runs_nothing(self):
        with tempfile.TemporaryDirectory() as d:
            marker = Path(d) / "ran"
            q = "{x: '$(touch %s); `touch %s`'}" % (marker, marker)
            rc, out, _err, _ = run(FakeEc2(), *BASE, "--output", "env", "--query", q)
            self.assertEqual(rc, 0)
            got = self.bash(out, 'printf "%s" "$CS_X"')
            self.assertFalse(marker.exists())
            self.assertEqual(got, f"$(touch {marker}); `touch {marker}`")

    def test_env_prefix(self):
        rc, out, _err, _ = run(FakeEc2(), *BASE, "--output", "env", "--env-prefix", "CAP_")
        self.assertEqual(rc, 0)
        self.assertTrue(all(line.startswith("export CAP_") for line in out.splitlines()))
        rc, _out, err, sessions = run(FakeEc2(), *BASE, "--env-prefix", "1X")
        self.assertEqual(rc, 2)
        self.assertEqual(sessions, [])


class Query(unittest.TestCase):
    def test_text_query_prints_one_row_per_match(self):
        ec2 = Dropping({("b.large", "use1-az2")})
        rc, out, _err, _ = run(ec2, *BASE, "--output", "text",
                               "--query", "scores[?score=='high'].[instance_type,az_id]")
        self.assertEqual(rc, 0)
        self.assertEqual(out.splitlines(), ["a.large\tuse1-az1", "a.large\tuse1-az2", "b.large\tuse1-az1"])

    def test_scalar_query_is_one_word(self):
        rc, out, _err, _ = run(FakeEc2(aggregate="low"), *BASE, "--output", "text",
                               "--query", "aggregates[?market=='on-demand'].score | [0]")
        self.assertEqual((rc, out), (0, "low\n"))

    def test_table_query_of_objects_has_a_header(self):
        rc, out, _err, _ = run(FakeEc2(), *BASE, "--query", "scores[0:1].{type:instance_type,az:az_id}")
        self.assertEqual(rc, 0)
        self.assertEqual(out.splitlines(), ["TYPE     AZ", "a.large  use1-az1"])

    def test_a_bad_query_is_refused_before_any_aws_call(self):
        rc, _out, err, sessions = run(FakeEc2(), *BASE, "--query", "scores[?")
        self.assertEqual(rc, 2)
        self.assertIn("JMESPath", err)
        self.assertEqual(sessions, [])

    def test_env_needs_an_object(self):
        rc, out, err, _ = run(FakeEc2(), *BASE, "--output", "env", "--query", "scores")
        self.assertEqual((rc, out), (2, ""))
        self.assertIn("needs --query to return an object", err)

    def test_env_keys_that_collide_are_refused(self):
        rc, _out, err, _ = run(FakeEc2(), *BASE, "--output", "env", "--query", "{\"a-b\": 'x', a_b: 'y'}")
        self.assertEqual(rc, 2)
        self.assertIn("both become CS_A_B", err)


class Environment(unittest.TestCase):
    def test_options_come_from_the_environment(self):
        env = {"EC2_SUPPORTABILITY_REGION": "us-east-1", "EC2_SUPPORTABILITY_TYPES": "a.large,b.large",
               "EC2_SUPPORTABILITY_AZS": "use1-az1 use1-az2", "EC2_SUPPORTABILITY_MARKETS": "spot",
               "EC2_SUPPORTABILITY_AMOUNTS": "7", "EC2_SUPPORTABILITY_OUTPUT": "json"}
        ec2 = FakeEc2()
        rc, out, _err, _ = run(ec2, environ=env)
        self.assertEqual(rc, 0)
        doc = json.loads(out)
        self.assertEqual(doc["request"]["region"], "us-east-1")
        self.assertEqual(doc["request"]["markets"], ["spot"])
        self.assertEqual(ec2.calls[0]["CapacityAmount"], 7)
        self.assertEqual(ec2.calls[0]["InstanceTypes"], ["a.large", "b.large"])

    def test_the_command_line_wins(self):
        env = {"EC2_SUPPORTABILITY_OUTPUT": "json", "EC2_SUPPORTABILITY_AMOUNTS": "7"}
        ec2 = FakeEc2()
        rc, out, _err, _ = run(ec2, *BASE, "--output", "text", environ=env)
        self.assertEqual(rc, 0)
        self.assertTrue(out.startswith("RESULT\t"))
        self.assertEqual(ec2.calls[0]["CapacityAmount"], 50)

    def test_aws_region_is_not_used_for_the_capacity_manager_region(self):
        rc, _out, err, sessions = run(FakeEc2(), environ={"AWS_REGION": "us-east-1", "AWS_DEFAULT_REGION": "us-east-1"})
        self.assertEqual(rc, 2)
        self.assertIn("--region is required", err)
        self.assertEqual(sessions, [])

    def test_enable_and_overwrite_are_never_taken_from_the_environment(self):
        env = {"EC2_SUPPORTABILITY_ENABLE": "1", "EC2_SUPPORTABILITY_OVERWRITE": "1",
               "EC2_SUPPORTABILITY_EXPECT_ACCOUNT": "111122223333"}
        ec2 = FakeEc2(disabled=True)
        rc, _out, _err, _ = run(ec2, *BASE, environ=env)
        self.assertEqual(rc, 3)
        self.assertFalse(ec2.enabled_called)

    def test_an_empty_variable_counts_as_unset(self):
        rc, out, _err, _ = run(FakeEc2(), *BASE, environ={"EC2_SUPPORTABILITY_OUTPUT": "", "EC2_SUPPORTABILITY_QUERY": " "})
        self.assertEqual(rc, 0)
        self.assertIn("aggregate:", out)


class SavedData(unittest.TestCase):
    def test_from_json_prints_any_format_without_aws(self):
        with tempfile.TemporaryDirectory() as d:
            saved = Path(d) / "r.json"
            rc, live, _err, _ = run(FakeEc2(), *BASE, "--output", "text", "--save-json", str(saved))
            self.assertEqual(rc, 0)
            rc, again, _err, sessions = run(FakeEc2(), "--from-json", str(saved), "--output", "text")
            self.assertEqual((rc, sessions), (0, []))
            self.assertEqual(again, live)

    def test_a_schema_1_file_gets_the_derived_lists(self):
        with tempfile.TemporaryDirectory() as d:
            saved = Path(d) / "r.json"
            run(FakeEc2(), *BASE, "--save-json", str(saved))
            old = json.loads(saved.read_text())
            for k in ("scores", "aggregates", "result"):
                del old[k]
            old["schema"] = "ec2-capacity-supportability-report/1"
            saved.write_text(json.dumps(old))
            rc, out, _err, _ = run(FakeEc2(), "--from-json", str(saved), "--output", "json")
            self.assertEqual(rc, 0)
            self.assertEqual(len(json.loads(out)["scores"]), 4)

    def test_edited_derived_lists_are_recomputed_from_the_facts(self):
        with tempfile.TemporaryDirectory() as d:
            saved = Path(d) / "r.json"
            run(FakeEc2(score="low"), *BASE, "--save-json", str(saved))
            doc = json.loads(saved.read_text())
            for r in doc["scores"]:
                r["score"] = "high"
            saved.write_text(json.dumps(doc))
            _rc, out, _err, _ = run(FakeEc2(), "--from-json", str(saved), "--output", "text",
                                    "--query", "scores[].score")
            self.assertEqual(out.split(), ["low"] * 4)


class ClosedPipe(unittest.TestCase):
    def test_a_reader_that_stops_early_is_not_a_failure(self):
        script = ("import sys\n"
                  "from ec2_supportability import cli\n"
                  "sys.exit(cli.main(['--from-json', sys.argv[1], '--output', 'json'], environ={}))\n")
        with tempfile.TemporaryDirectory() as d:
            saved = Path(d) / "r.json"
            # Far more output than a pipe buffer holds, so the writer is still writing when the reader leaves.
            types = [f"t{i}.large" for i in range(100)]
            azs = [f"use1-az{i}" for i in range(1, 11)]
            rc, *_ = run(FakeEc2(), "--region", "us-east-1", "--types", *types, "--azs", *azs, "--markets", "on-demand",
                         "--amounts", "50", "--save-json", str(saved))
            self.assertEqual(rc, 0)
            self.assertGreater(saved.stat().st_size, 1 << 18)
            proc = subprocess.Popen([sys.executable, "-c", script, str(saved)], stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE)
            proc.stdout.readline()
            proc.stdout.close()  # like `| head -1`
            err = proc.stderr.read().decode()
            proc.stderr.close()
            self.assertEqual(proc.wait(), 0, err)
            self.assertNotIn("Traceback", err)


class FormatUnits(unittest.TestCase):
    def test_every_format_name_renders(self):
        _rc, out, _err, _ = run(FakeEc2(), *BASE, "--output", "json")
        doc = json.loads(out)
        for fmt in formats.FORMATS:
            self.assertTrue(formats.render(doc, fmt))


if __name__ == "__main__":
    unittest.main()


class ReviewRegressions(unittest.TestCase):
    """One test per defect found in review; each fails when its fix is taken out."""

    def test_a_variable_cannot_add_an_option(self):
        env = {"EC2_SUPPORTABILITY_TYPES": "a.large --enable --expect-account 111122223333",
               "EC2_SUPPORTABILITY_REGION": "us-east-1"}
        ec2 = FakeEc2(disabled=True)
        rc, _out, err, sessions = run(ec2, environ=env)
        self.assertEqual(rc, 2)
        self.assertIn("EC2_SUPPORTABILITY_TYPES", err)
        self.assertEqual(sessions, [])
        self.assertFalse(ec2.enabled_called)

    def test_a_scalar_variable_stays_one_value(self):
        rc, _out, err, sessions = run(FakeEc2(), *BASE, environ={"EC2_SUPPORTABILITY_PROFILE": "--enable"})
        # The profile is the literal text "--enable"; the run is not enabled by it.
        self.assertEqual(sessions, [{"profile_name": "--enable"}])

    def test_the_command_line_slot_silences_the_variable_of_the_other_option(self):
        env = {"EC2_SUPPORTABILITY_TYPES": "a.large"}
        req = '{"VirtualizationTypes":["hvm"],"InstanceRequirements":{"VCpuCount":{"Min":1},"MemoryMiB":{"Min":1}}}'
        rc, out, _err, _ = run(FakeEc2(), "--region", "us-east-1", "--azs", "use1-az1", "--markets", "on-demand",
                               "--amounts", "1", "--requirements", req, "--output", "json", environ=env)
        self.assertEqual(rc, 0)
        self.assertIsNone(json.loads(out)["request"]["types"])

    def test_a_bad_variable_does_not_beat_the_command_line_or_block_version(self):
        rc, out, _err, _ = run(FakeEc2(), *BASE, "--output", "text", environ={"EC2_SUPPORTABILITY_OUTPUT": "xml"})
        self.assertEqual(rc, 0)
        self.assertTrue(out.startswith("RESULT\t"))
        rc, out, _err, _ = run(FakeEc2(), "--version", environ={"EC2_SUPPORTABILITY_OUTPUT": "xml"})
        self.assertEqual(rc, 0)
        rc, _out, err, _ = run(FakeEc2(), *BASE, environ={"EC2_SUPPORTABILITY_OUTPUT": "xml"})
        self.assertEqual(rc, 2)
        self.assertIn("EC2_SUPPORTABILITY_OUTPUT", err)

    def test_scalar_variables_are_trimmed(self):
        rc, out, _err, _ = run(FakeEc2(), *BASE[2:], environ={"EC2_SUPPORTABILITY_OUTPUT": " json ",
                                                              "EC2_SUPPORTABILITY_REGION": " us-east-1 "})
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(out)["request"]["region"], "us-east-1")

    def test_a_query_that_fails_on_the_data_is_status_two_without_a_traceback(self):
        rc, out, err, _ = run(FakeEc2(), *BASE, "--query", "length(`null`)")
        self.assertEqual((rc, out), (2, ""))
        self.assertNotIn("Traceback", err)
        self.assertIn("--query failed", err)

    def test_an_incomplete_run_keeps_status_three_when_printing_fails(self):
        rc, _out, _err, _ = run(FakeEc2(fail_all=True), *BASE, "--output", "env", "--query", "scores")
        self.assertEqual(rc, 3)

    def test_a_write_failure_is_status_four_and_the_result_is_still_printed(self):
        real = os.fdopen

        def full(fd, *a, **kw):
            f = real(fd, *a, **kw)
            f.write = lambda s: (_ for _ in ()).throw(OSError(28, "No space left on device"))
            return f
        with tempfile.TemporaryDirectory() as d, mock.patch("ec2_supportability.files.os.fdopen", full):
            rc, out, err, _ = run(FakeEc2(), *BASE, "--output", "text", "--save-json", str(Path(d) / "r.json"))
            self.assertEqual(rc, 4)
            self.assertTrue(out.startswith("RESULT\t"))
            self.assertEqual(sorted(Path(d).iterdir()), [])
        self.assertIn("No space left", err)

    def test_json_is_ascii(self):
        rc, out, _err, _ = run(FakeEc2(disabled=True), *BASE, "--output", "json", "--enable",
                               "--expect-account", "111122223333")
        self.assertEqual(rc, 0)
        self.assertTrue(json.loads(out)["log"])  # the Japanese notes are there ...
        out.encode("ascii")                       # ... escaped, so any encoding prints them

    def test_two_spellings_of_one_path_are_refused(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "sub").mkdir()
            rc, _out, err, _ = run(FakeEc2(), *BASE, "--save-json", str(Path(d) / "r.json"),
                                   "--html", str(Path(d) / "sub" / ".." / "r.json"), "--overwrite")
            self.assertEqual(rc, 4)
            self.assertIn("same file", err)
            self.assertEqual(sorted(p.name for p in Path(d).iterdir()), ["sub"])

    def test_side_names_never_replace_each_other(self):
        stem = "x" * 120
        with tempfile.TemporaryDirectory() as d:
            rc, *_ = run(FakeEc2(fail_all=True), *BASE, "--save-json", str(Path(d) / f"{stem}-data.out"),
                         "--html", str(Path(d) / f"{stem}-page.out"))
            self.assertEqual(rc, 3)
            files = sorted(Path(d).iterdir())
            self.assertEqual(len(files), 2)
            kinds = sorted("json" if p.read_text().lstrip().startswith("{") else "html" for p in files)
            self.assertEqual(kinds, ["html", "json"])

    def test_unknown_azs_have_rows(self):
        rc, out, _err, _ = run(FakeEc2(invalid_azs={"use1-az9"}), "--region", "us-east-1", "--types", "a.large",
                               "--azs", "use1-az1", "use1-az9", "--markets", "on-demand", "--amounts", "1",
                               "--output", "json")
        self.assertEqual(rc, 3)
        state = {r["az_id"]: r["state"] for r in json.loads(out)["scores"]}
        self.assertEqual(state, {"use1-az1": "scored", "use1-az9": "unknown_az"})

    def test_requirements_are_recorded(self):
        req = {"VirtualizationTypes": ["hvm"], "InstanceRequirements": {"VCpuCount": {"Min": 1}, "MemoryMiB": {"Min": 1}}}
        rc, out, _err, _ = run(FakeEc2(), "--region", "us-east-1", "--azs", "use1-az1", "--markets", "on-demand",
                               "--amounts", "1", "--requirements", json.dumps(req), "--output", "json")
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(out)["request"]["requirements"], req)

    def test_a_tab_in_a_type_is_refused_at_the_entry(self):
        rc, _out, err, sessions = run(FakeEc2(), "--region", "us-east-1", "--types", "a.large\tb", "--azs", "use1-az1")
        self.assertEqual(rc, 2)
        self.assertEqual(sessions, [])

    def test_query_text_escapes_tabs_and_line_breaks(self):
        rc, out, _err, _ = run(FakeEc2(), *BASE, "--output", "text", "--query", "['a\tb', 'c\nd']")
        self.assertEqual(rc, 0)
        self.assertEqual(out, "a\\tb\tc\\nd\n")

    def test_an_edited_status_cannot_claim_a_complete_run(self):
        with tempfile.TemporaryDirectory() as d:
            saved = Path(d) / "r.json"
            run(FakeEc2(fail_all=True), *BASE, "--save-json", str(saved))
            doc = json.loads(next(Path(d).iterdir()).read_text())
            doc["status"] = 0
            saved.write_text(json.dumps(doc))
            rc, out, _err, _ = run(FakeEc2(), "--from-json", str(saved), "--output", "text", "--query", "result")
            self.assertEqual((rc, out), (3, "incomplete\n"))
            doc["request"]["amounts"] = [50, 50]
            saved.write_text(json.dumps(doc))
            rc, *_ = run(FakeEc2(), "--from-json", str(saved))
            self.assertEqual(rc, 2)

    def test_an_empty_env_prefix_is_refused(self):
        rc, _out, _err, sessions = run(FakeEc2(), *BASE, "--output", "env", "--env-prefix", "")
        self.assertEqual(rc, 2)
        self.assertEqual(sessions, [])

    def test_the_table_explains_a_dash(self):
        class OneAz(FakeEc2):
            def get_capacity_manager_supportability_scores(self, **kw):
                return {"AggregateScore": "high", "CapacityManagerSupportabilityScores": [
                    {"InstanceType": "a.large", "AvailabilityZoneId": "use1-az1", "Score": "high"}]}
        req = '{"VirtualizationTypes":["hvm"],"InstanceRequirements":{"VCpuCount":{"Min":1},"MemoryMiB":{"Min":1}}}'
        rc, out, _err, _ = run(OneAz(), "--region", "us-east-1", "--azs", *AZS, "--markets", "on-demand",
                               "--amounts", "1", "--requirements", req)
        self.assertEqual(rc, 0)
        self.assertIn("-: no row for this pair", out)


class BrowserOutput(unittest.TestCase):
    def test_the_browser_never_writes_into_standard_output(self):
        with tempfile.TemporaryDirectory() as d:
            saved = Path(d) / "r.json"
            run(FakeEc2(), *BASE, "--save-json", str(saved))
            env = dict(os.environ, BROWSER="echo chatter-%s")
            proc = subprocess.run([sys.executable, "-m", "ec2_supportability", "--from-json", str(saved),
                                   "--output", "json", "--html", str(Path(d) / "r.html"), "--open"],
                                  capture_output=True, text=True, env=env)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            json.loads(proc.stdout)
            self.assertIn("chatter", proc.stderr)


class SecondRound(unittest.TestCase):
    def test_names_that_differ_only_in_case_count_as_one_file(self):
        with tempfile.TemporaryDirectory() as d:
            rc, _out, err, _ = run(FakeEc2(), *BASE, "--save-json", str(Path(d) / "Report.out"),
                                   "--html", str(Path(d) / "report.out"), "--overwrite")
            self.assertEqual(rc, 4)
            self.assertIn("same file", err)

    def test_text_that_the_console_cannot_encode_is_escaped(self):
        with tempfile.TemporaryDirectory() as d:
            saved = Path(d) / "r.json"
            run(FakeEc2(), *BASE, "--save-json", str(saved))
            env = dict(os.environ, PYTHONIOENCODING="ascii")
            proc = subprocess.run([sys.executable, "-m", "ec2_supportability", "--from-json", str(saved),
                                   "--output", "text", "--query", "'日本'"], capture_output=True, env=env)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout, b"\\u65e5\\u672c\n")


class ThirdRound(unittest.TestCase):
    def test_env_refuses_names_that_change_how_programs_run(self):
        for prefix, key in (("P", "ath"), ("LD_", "preload"), ("BASH_", "env"), ("PY", "thonpath")):
            rc, out, err, _ = run(FakeEc2(), *BASE, "--output", "env", "--env-prefix", prefix,
                                  "--query", "{%s: 'x'}" % key)
            self.assertEqual((rc, out), (2, ""), prefix + key)
            self.assertIn("change how the shell", err)

    def test_query_and_prefix_are_not_taken_from_the_environment(self):
        env = {"EC2_SUPPORTABILITY_QUERY": "{aggregate_on_demand_50: 'high'}", "EC2_SUPPORTABILITY_ENV_PREFIX": "X_"}
        rc, out, _err, _ = run(FakeEc2(aggregate="low"), *BASE, "--output", "env", environ=env)
        self.assertEqual(rc, 0)
        self.assertIn("export CS_AGGREGATE_ON_DEMAND_50=low\n", out)

    def test_env_values_are_not_escaped(self):
        # --output text would write the tab as \t; the shell variable holds the tab itself.
        rc, out, _err, _ = run(FakeEc2(), *BASE, "--output", "env", "--query", "{v: 'a\tb'}")
        self.assertEqual(rc, 0)
        self.assertEqual(out, "export CS_V='a\tb'\n")

    def test_a_float_status_and_bad_reasons_are_refused(self):
        with tempfile.TemporaryDirectory() as d:
            saved = Path(d) / "r.json"
            run(FakeEc2(), *BASE, "--save-json", str(saved))
            good = json.loads(saved.read_text())
            for change in ({"status": 3.0}, {"status": True}, {"reasons": {"x": 1}}):
                saved.write_text(json.dumps({**good, **change}))
                rc, *_ = run(FakeEc2(), "--from-json", str(saved))
                self.assertEqual(rc, 2, change)

    def test_reasons_are_rebuilt_when_the_status_is_raised(self):
        with tempfile.TemporaryDirectory() as d:
            run(FakeEc2(fail_all=True), *BASE, "--save-json", str(Path(d) / "r.json"))
            saved = next(Path(d).iterdir())
            doc = json.loads(saved.read_text())
            doc["status"], doc["reasons"] = 0, []
            saved.write_text(json.dumps(doc))
            rc, out, _err, _ = run(FakeEc2(), "--from-json", str(saved), "--output", "json")
            self.assertEqual(rc, 3)
            self.assertTrue(json.loads(out)["reasons"])
