"""Offline tests for the ec2-supportability command. Run from the package directory:

  uv run --quiet --with-editable . python -I -m unittest discover -b -s tests
"""
import json
import os
import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from botocore.exceptions import BotoCoreError, ClientError, EndpointConnectionError

from ec2_supportability import cli, collect, document, files, formats, report_html


def read_html(directory):
    """Text of the single visible .html file in a directory (a successful report or a .failed- report), else None."""
    files = sorted(p for p in Path(directory).iterdir() if p.suffix == ".html" and not p.name.startswith("."))
    return files[-1].read_text(encoding="utf-8") if files else None


def files_for(html_path):
    """The arguments that write the report and its data file side by side, as the tests expect."""
    p = Path(html_path)
    return ["--html", str(p), "--save-json", str(p.with_suffix(".json"))]


class FakeEc2:
    """Records every request and answers from a table; raises for configured calls."""

    def __init__(self, score="high", aggregate="medium", fail_on_call=None, disabled=False,
                 status_style=False, response=None, enable_fails=False, attr_error=None, stay_disabled=False,
                 invalid_azs=(), not_offered=(), preflight_error=None, fail_all=False, fail_code="UnauthorizedOperation"):
        self.calls, self.score, self.aggregate = [], score, aggregate
        self.fail_on_call, self.disabled, self.enabled_called = fail_on_call, disabled, False
        self.status_style, self.response, self.enable_fails, self.attr_error = status_style, response, enable_fails, attr_error
        self.stay_disabled = stay_disabled
        self.invalid_azs, self.not_offered, self.preflight_error = set(invalid_azs), set(not_offered), preflight_error
        self.fail_all, self.fail_code, self.preflight_calls = fail_all, fail_code, 0

    def get_capacity_manager_supportability_scores(self, **kw):
        self.calls.append(kw)
        if self.fail_all or self.fail_on_call == len(self.calls):
            raise ClientError({"Error": {"Code": self.fail_code, "Message": "denied"}}, "op")
        if self.response is not None:
            return self.response
        types = kw.get("InstanceTypes") or ["resolved.large"]
        return {"AggregateScore": self.aggregate,
                "CapacityManagerSupportabilityScores": [
                    {"InstanceType": t, "AvailabilityZoneId": a, "Score": self.score}
                    for t in types for a in kw["CapacityAvailabilityZoneIds"]]}

    def get_capacity_manager_attributes(self):
        if self.attr_error is not None:
            raise self.attr_error
        if self.disabled and (not self.enabled_called or self.stay_disabled):
            if self.status_style:
                return {"CapacityManagerStatus": "disabled"}
            raise ClientError({"Error": {"Code": "CapacityManager.Disabled", "Message": "off"}}, "op")
        return {"CapacityManagerStatus": "enabled"}

    def describe_availability_zones(self, **kw):
        self.preflight_calls += 1
        if self.preflight_error is not None:
            raise self.preflight_error
        ids = kw["Filters"][0]["Values"]
        return {"AvailabilityZones": [{"ZoneId": i} for i in ids if i not in self.invalid_azs]}

    def describe_instance_type_offerings(self, **kw):
        self.preflight_calls += 1
        if self.preflight_error is not None:
            raise self.preflight_error
        loc = next(f["Values"] for f in kw["Filters"] if f["Name"] == "location")
        typ = next(f["Values"] for f in kw["Filters"] if f["Name"] == "instance-type")
        return {"InstanceTypeOfferings": [{"InstanceType": t, "Location": a} for t in typ for a in loc
                                          if (t, a) not in self.not_offered and not t.startswith("zzz")]}

    def enable_capacity_manager(self):
        if self.enable_fails:
            raise ClientError({"Error": {"Code": "UnauthorizedOperation", "Message": "denied"}}, "op")
        self.enabled_called = True


class PlanCalls(unittest.TestCase):
    def test_every_request_stays_within_documented_limits(self):
        types = [f"t{i}.large" for i in range(60)]
        azs = [f"use1-az{i}" for i in range(1, 12)]  # 11 AZs
        plan = collect.plan_calls(types, azs)
        for tc, ac in plan:
            self.assertLessEqual(len(ac), collect.MAX_AZ_PER_CALL)
            self.assertLessEqual(len(tc), collect.MAX_TYPE_PER_CALL)
            self.assertLessEqual(len(tc) * len(ac), collect.MAX_COMBOS_PER_CALL)
        covered = {(t, a) for tc, ac in plan for t in tc for a in ac}
        self.assertEqual(len(covered), len(types) * len(azs))  # nothing dropped, nothing duplicated

    def test_default_run_is_one_call_per_market_and_amount(self):
        self.assertEqual(len(collect.plan_calls(collect.DEFAULT_TYPES, collect.DEFAULT_AZS)), 1)

    def test_requirements_mode_splits_only_azs(self):
        plan = collect.plan_calls(None, [f"use1-az{i}" for i in range(1, 12)])
        self.assertEqual([len(ac) for _, ac in plan], [10, 1])
        self.assertTrue(all(tc is None for tc, _ in plan))


class RunQuery(unittest.TestCase):
    def test_collects_cells_and_aggregate_per_group(self):
        ec2 = FakeEc2()
        res = collect.run_query(ec2, "spot", 5, "instances", ["a.large", "b.large"], ["use1-az1", "use1-az2"])
        self.assertEqual(len(res.cells), 4)
        self.assertEqual([g.aggregate for g in res.groups], ["medium"])
        self.assertEqual(ec2.calls[0]["MarketType"], "spot")
        self.assertEqual(ec2.calls[0]["CapacityAmount"], 5)

    def test_error_is_recorded_on_its_group_and_other_groups_continue(self):
        ec2 = FakeEc2(fail_on_call=1)
        types = [f"t{i}.large" for i in range(30)]  # 30 x 10 AZ -> 3 calls
        azs = [f"use1-az{i}" for i in range(1, 11)]
        res = collect.run_query(ec2, "on-demand", 1, "instances", types, azs)
        self.assertEqual(len(res.groups), 3)
        self.assertIn("UnauthorizedOperation", res.groups[0].error)
        self.assertIsNone(res.groups[1].error)
        self.assertEqual(len(res.cells), 20 * 10)  # the failed slice is missing, not zero-filled

    def test_requirements_are_passed_instead_of_instance_types(self):
        ec2 = FakeEc2()
        req = {"ArchitectureTypes": ["arm64"]}
        res = collect.run_query(ec2, "on-demand", 1, "vcpus", None, ["use1-az1"], req)
        self.assertEqual(ec2.calls[0]["InstanceRequirementsWithMetadata"], req)
        self.assertNotIn("InstanceTypes", ec2.calls[0])
        self.assertEqual(res.types, ["resolved.large"])


class EnsureManager(unittest.TestCase):
    def test_does_not_enable_without_the_flag(self):
        ec2 = FakeEc2(disabled=True)
        state, _ = collect.ensure_manager(ec2, allow_enable=False)
        self.assertFalse(state["enabled"])
        self.assertTrue(state["needs_enable"])
        self.assertFalse(ec2.enabled_called)

    def test_enables_with_the_flag(self):
        ec2 = FakeEc2(disabled=True)
        with mock.patch.object(collect.time, "sleep"):
            state, _ = collect.ensure_manager(ec2, allow_enable=True)
        self.assertTrue(state["enabled"])
        self.assertTrue(ec2.enabled_called)


class Render(unittest.TestCase):
    def ctx(self, **over):
        res = collect.run_query(FakeEc2(score="low", aggregate="high"), "on-demand", 10, "instances",
                           ["g6e.xlarge"], ["apne1-az4"])
        c = {"identity": {"Account": "111122223333", "Arn": "arn:aws:sts::111122223333:assumed-role/x/y"},
             "region": "ap-northeast-1", "state": {"enabled": True, "attrs": {"CapacityManagerStatus": "enabled"}, "error": None},
             "log": [], "now": "2026-11-05 10:00:00", "types": ["g6e.xlarge"], "azs": ["apne1-az4"],
             "markets": ["on-demand"], "amounts": [10], "unit": "instances",
             "results": {"on-demand": {10: res}}, "calls": 1, "lang": "en", "lang_explicit": False}
        c.update(over)
        return c

    def test_every_translatable_span_has_both_languages(self):
        out = report_html.render(self.ctx())
        pairs = re.findall(r'<span class="en">(.*?)</span><span class="ja">(.*?)</span>', out, flags=re.S)
        self.assertEqual(out.count('<span class="en">'), len(pairs))  # every en span is directly followed by its ja span
        self.assertGreaterEqual(len(pairs), 30)
        for en, ja in pairs:
            self.assertTrue(en.strip() and ja.strip())
            # A Japanese span that is identical to the English one, or has no Japanese character, was not translated.
            if re.search(r"[A-Za-z]{3,}", en) and en not in ("Spot",):
                self.assertTrue(re.search(r"[\u3040-\u30ff\u4e00-\u9fff]", ja), f"untranslated: {en[:60]}")

    def test_erasing_a_translation_is_detected(self):
        out = report_html.render(self.ctx()).replace("スコアの読み方", "How to read the scores", 1)
        pairs = re.findall(r'<span class="en">(.*?)</span><span class="ja">(.*?)</span>', out, flags=re.S)
        self.assertTrue(any(en == ja for en, ja in pairs))

    def test_initial_language_follows_the_option(self):
        self.assertIn('<html lang="ja"', report_html.render(self.ctx(lang="ja", lang_explicit=True)))
        self.assertIn('<html lang="en"', report_html.render(self.ctx(lang="en")))

    def test_low_cell_with_high_aggregate_is_shown_as_is(self):
        out = report_html.render(self.ctx())
        table = out[out.index("<table>", out.index("Request: 10")):]
        self.assertIn('<th class="sticky mono">g6e.xlarge</th><td><span class="pill low">Low</span></td>', table)
        self.assertIn('<div class="agg"><b><span class="en">Aggregate score</span><span class="ja">集約スコア</span></b> <span class="pill high">High</span>', out)

    def test_missing_combination_is_na_not_low(self):
        out = report_html.heatmap({}, ["g6e.xlarge"], ["apne1-az4"])
        self.assertIn("pill na", out)
        self.assertNotIn("pill low", out)

    def test_split_run_never_claims_one_aggregate_for_the_whole_set(self):
        groups = [collect.Group(types=["a"], azs=["x"], aggregate="high"), collect.Group(types=["b"], azs=["x"], aggregate="low")]
        out = report_html.aggregate_block(groups)
        self.assertIn("1/2", out)
        self.assertIn("documentation does not say how to combine aggregates", out)
        self.assertIn("<span class='mono'>a</span>", out)  # each aggregate names the types and AZs it covers
        self.assertIn("<span class='mono'>b</span>", out)

    def test_markup_in_values_is_escaped(self):
        out = report_html.render(self.ctx(state={"enabled": False, "attrs": {}, "error": "<script>x</script>"}))
        self.assertNotIn("<script>x</script>", out)

    def test_terms_notice_is_present(self):
        out = report_html.render(self.ctx())
        self.assertIn("EC2 Capacity Manager Data", out)
        self.assertIn("contractors or agents", out)


class Cli(unittest.TestCase):
    def test_quota_guard_counts_calls_not_combinations(self):
        a = cli.parse_args(["--region", "r", "--markets", "on-demand", "spot", "--amounts", "1", "10", "100"])
        self.assertEqual(cli.planned_calls(a), 6)

    def test_region_is_required(self):
        with self.assertRaises(SystemExit):
            cli.parse_args([])

    def test_duplicates_are_removed_and_amounts_sorted(self):
        a = cli.parse_args(["--region", "r", "--amounts", "100", "1", "100", "--markets", "spot", "spot"])
        self.assertEqual(a.amounts, [1, 100])
        self.assertEqual(a.markets, ["spot"])

    def test_non_positive_amount_and_bad_requirements_are_refused_at_entry(self):
        for argv in (["--amounts", "0"], ["--amounts", "-3"], ["--requirements", "{"], ["--requirements", "{}"],
                     ["--requirements", "[1]"]):
            with self.assertRaises(SystemExit, msg=argv):
                cli.parse_args(["--region", "r"] + argv)


class MainFlow(unittest.TestCase):
    """main() with a fake session: exit status, quota guard and what is written."""

    def run_main(self, ec2, *argv):
        class STS:
            def get_caller_identity(self):
                return {"Account": "111122223333", "Arn": "arn:test"}

        class Session:
            def client(self, service, **kw):
                return ec2 if service == "ec2" else STS()

        with tempfile.TemporaryDirectory() as d, mock.patch.object(cli.boto3, "Session", lambda **kw: Session()), \
                mock.patch.object(collect.time, "sleep"):
            out = Path(d) / "r.html"
            rc = cli.main(["--region", "r", "--markets", "on-demand", "--amounts", "1", "--types", "a.large",
                          "--azs", "use1-az1", *files_for(out), *argv])
            return rc, read_html(d)

    def test_success_exits_zero(self):
        rc, page = self.run_main(FakeEc2())
        self.assertEqual(rc, 0)
        self.assertIn("a.large", page)

    def test_failed_request_exits_nonzero_but_still_writes_the_report(self):
        rc, page = self.run_main(FakeEc2(fail_on_call=1))
        self.assertEqual(rc, 3)
        self.assertIn("UnauthorizedOperation", page)

    def test_disabled_without_enable_exits_nonzero_and_changes_nothing(self):
        ec2 = FakeEc2(disabled=True)
        rc, page = self.run_main(ec2)
        self.assertEqual(rc, 3)
        self.assertFalse(ec2.enabled_called)
        self.assertEqual(ec2.calls, [])
        self.assertIn("--enable", page)

    def test_disabled_with_enable_enables_then_scores(self):
        ec2 = FakeEc2(disabled=True)
        rc, _ = self.run_main(ec2, "--enable", "--expect-account", "111122223333")
        self.assertEqual(rc, 0)
        self.assertTrue(ec2.enabled_called)
        self.assertEqual(len(ec2.calls), 1)

    def test_quota_guard_refuses_before_any_call(self):
        ec2 = FakeEc2()
        amounts = [str(i) for i in range(1, 97)]  # 96 planned calls > 95
        rc, page = self.run_main(ec2, *["--amounts", *amounts])
        self.assertEqual(rc, 6)
        self.assertEqual(ec2.calls, [])
        self.assertIsNone(page)

    def test_the_last_allowed_run_is_not_refused(self):
        ec2 = FakeEc2()
        rc, _ = self.run_main(ec2, "--amounts", *[str(i) for i in range(1, 96)])  # 95 calls
        self.assertEqual(rc, 0)
        self.assertEqual(len(ec2.calls), 95)

    def test_explicit_lang_overrides_the_saved_browser_choice(self):
        _, page = self.run_main(FakeEc2(), "--lang", "ja")
        self.assertIn('lang="ja" data-lang-explicit="1"', page)
        _, page = self.run_main(FakeEc2())
        self.assertIn('lang="en" data-lang-explicit="0"', page)


class DocumentedConstants(unittest.TestCase):
    def test_limits_are_the_documented_literals(self):
        # Quotas page: 100 queries/hour, 100 combinations/request. CLI reference: 10 AZs, 50 instance types.
        self.assertEqual((collect.QUOTA_PER_HOUR, collect.MAX_COMBOS_PER_CALL, collect.MAX_AZ_PER_CALL, collect.MAX_TYPE_PER_CALL),
                         (100, 100, 10, 50))

    def test_plan_has_no_duplicates_and_uses_few_calls(self):
        types = [f"t{i}.large" for i in range(60)]
        azs = [f"use1-az{i}" for i in range(1, 12)]  # chunks of 10 and 1
        plan = collect.plan_calls(types, azs)
        pairs = [(t, a) for tc, ac in plan for t in tc for a in ac]
        self.assertEqual(len(pairs), len(set(pairs)))
        self.assertEqual(len(plan), 6 + 2)  # 10 AZ x 10 types -> 6 calls; 1 AZ x 50 types -> 2 calls


class EnableStatus(unittest.TestCase):
    def test_disabled_status_in_a_normal_response_is_treated_as_disabled(self):
        ec2 = FakeEc2(disabled=True, status_style=True)
        state, _ = collect.ensure_manager(ec2, allow_enable=False)
        self.assertFalse(state["enabled"])
        self.assertTrue(state.get("needs_enable"))

    def test_unknown_status_stops_without_enabling(self):
        ec2 = FakeEc2(attr_error=ClientError({"Error": {"Code": "UnauthorizedOperation", "Message": "x"}}, "op"))
        state, _ = collect.ensure_manager(ec2, allow_enable=True)
        self.assertFalse(state["enabled"])
        self.assertIn("UnauthorizedOperation", state["error"])
        self.assertFalse(ec2.enabled_called)

    def test_botocore_error_on_the_first_read_is_reported_not_raised(self):
        ec2 = FakeEc2(attr_error=EndpointConnectionError(endpoint_url="https://x"))
        state, _ = collect.ensure_manager(ec2, allow_enable=True)
        self.assertFalse(state["enabled"])
        self.assertFalse(ec2.enabled_called)

    def test_enable_that_does_not_take_effect_is_not_reported_as_enabled(self):
        ec2 = FakeEc2(disabled=True, status_style=True, stay_disabled=True)
        with mock.patch.object(collect.time, "sleep"):
            state, _ = collect.ensure_manager(ec2, allow_enable=True)
        self.assertTrue(ec2.enabled_called)
        self.assertFalse(state["enabled"])

    def test_enable_failure_is_reported(self):
        ec2 = FakeEc2(disabled=True, enable_fails=True)
        state, _ = collect.ensure_manager(ec2, allow_enable=True)
        self.assertFalse(state["enabled"])
        self.assertIn("UnauthorizedOperation", state["error"])


class ResponseShapes(unittest.TestCase):
    def test_empty_or_malformed_responses_are_errors_not_successes(self):
        for resp in ({}, {"AggregateScore": "high", "CapacityManagerSupportabilityScores": []},
                     {"AggregateScore": "good", "CapacityManagerSupportabilityScores": [{"InstanceType": "a", "AvailabilityZoneId": "x", "Score": "low"}]},
                     {"AggregateScore": "high", "CapacityManagerSupportabilityScores": None}):
            res = collect.run_query(FakeEc2(response=resp), "on-demand", 1, "instances", ["a.large"], ["use1-az1"])
            self.assertTrue(res.groups[0].error, resp)
            self.assertEqual(cli.exit_status({"enabled": True}, {"on-demand": {1: res}}), 3)

    def test_a_malformed_row_is_left_out_and_flagged(self):
        resp = {"AggregateScore": "high", "CapacityManagerSupportabilityScores": [
            {"InstanceType": "a.large", "AvailabilityZoneId": "use1-az1", "Score": "high"},
            {"InstanceType": "b.large", "AvailabilityZoneId": "use1-az1"},
            {"InstanceType": "c.large", "AvailabilityZoneId": "use1-az1", "Score": {"x": 1}}]}
        res = collect.run_query(FakeEc2(response=resp), "on-demand", 1, "instances", ["a.large"], ["use1-az1"])
        self.assertEqual(list(res.cells), [("a.large", "use1-az1")])
        self.assertIn("2 score rows were malformed", res.groups[0].error)

    def test_botocore_errors_on_a_request_are_recorded(self):
        class Boom(FakeEc2):
            def get_capacity_manager_supportability_scores(self, **kw):
                raise EndpointConnectionError(endpoint_url="https://x")
        res = collect.run_query(Boom(), "on-demand", 1, "instances", ["a.large"], ["use1-az1"])
        self.assertIn("EndpointConnectionError", res.groups[0].error)

    def test_unit_is_passed_through(self):
        ec2 = FakeEc2()
        collect.run_query(ec2, "on-demand", 4, "vcpus", ["a.large"], ["use1-az1"])
        self.assertEqual(ec2.calls[0]["CapacityUnit"], "vcpus")


class RenderMore(unittest.TestCase):
    def ctx(self, res_by_market, **over):
        c = {"identity": {"Account": "111122223333", "Arn": "arn:aws:sts::111122223333:assumed-role/x/y"},
             "region": "r", "state": {"enabled": True, "attrs": {"CapacityManagerStatus": "enabled"}, "error": None},
             "log": [], "now": "t", "types": ["a.large"], "azs": ["use1-az1"], "markets": list(res_by_market),
             "amounts": [1], "unit": "instances", "results": {m: {1: r} for m, r in res_by_market.items()},
             "calls": 1, "lang": "en", "lang_explicit": False}
        c.update(over)
        return c

    def test_best_score_ignores_missing(self):
        self.assertEqual(collect.best_score(["low", None, "high"]), "high")
        self.assertIsNone(collect.best_score([None, None]))

    def test_failed_request_cells_show_error_not_na(self):
        res = collect.run_query(FakeEc2(fail_on_call=1), "on-demand", 1, "instances", ["a.large"], ["use1-az1"])
        out = report_html.render(self.ctx({"on-demand": res}))
        table = out[out.index("<tbody>"):]
        self.assertIn('class="pill err">Error', table)
        self.assertNotIn('class="pill na">N/A', table)

    def test_best_column_is_error_when_a_failed_request_left_no_score_for_the_row(self):
        res = collect.Result(cells={("a.large", "use1-az1"): "low"}, groups=[
            collect.Group(types=["b.large"], azs=["use1-az1"], error="Boom: x", all_types=["b.large"], all_azs=["use1-az1"])])
        row = report_html.heatmap(res.cells, ["b.large"], ["use1-az1"], collect.failed_pairs(res))
        self.assertIn('class="bestcol"><span class="pill err">Error', row)

    def test_unreadable_status_is_not_shown_as_disabled(self):
        ec2 = FakeEc2(attr_error=ClientError({"Error": {"Code": "UnauthorizedOperation", "Message": "x"}}, "op"))
        state, _ = collect.ensure_manager(ec2, allow_enable=False)
        out = report_html.render(self.ctx({"on-demand": collect.Result()}, state=state))
        self.assertIn(">unknown<", out)
        self.assertNotIn(">disabled<", out)

    def test_failed_aggregate_says_the_request_failed(self):
        g = collect.Group(types=["a"], azs=["x"], aggregate=None, error="Boom: x")
        self.assertIn("request failed", report_html.aggregate_block([g]))

    def test_every_api_derived_value_is_escaped(self):
        evil = "<img src=x onerror=alert(1)>"
        res = collect.Result(cells={(evil, "use1-az1"): "low"}, groups=[collect.Group(types=[evil], azs=["use1-az1"], aggregate="low")])
        res.groups.append(collect.Group(types=[evil], azs=["use1-az1"], error=evil))
        out = report_html.render(self.ctx({"on-demand": res}, types=[evil], state={"enabled": True, "attrs": {"CapacityManagerStatus": evil}, "error": evil}))
        self.assertNotIn(evil, out)

    def test_split_spot_run_says_each_aggregate_covers_its_slice(self):
        res = collect.Result(groups=[collect.Group(types=["a"], azs=["x"], aggregate="high"), collect.Group(types=["b"], azs=["x"], aggregate="low")])
        out = report_html.render(self.ctx({"spot": res}))
        self.assertIn("split into several requests", out)
        one = collect.Result(groups=[collect.Group(types=["a"], azs=["x"], aggregate="high")])
        self.assertNotIn("split into several requests", report_html.render(self.ctx({"spot": one})))

    def test_terms_notice_has_the_restrictions_not_only_the_permission(self):
        out = report_html.render(self.ctx({"on-demand": collect.Result()}))
        for needle in ("solely for your internal", "contractors or agents acting on your behalf", "competing product",
                       "suspend", "not legal advice"):
            self.assertIn(needle, out)

    def test_toggle_persists_only_on_click(self):
        self.assertIn("addEventListener('click'", report_html.JS)
        self.assertEqual(report_html.JS.count("setItem"), 1)
        self.assertRegex(report_html.JS, r"addEventListener\('click',function\(\)\{[^}]*\n[^}]*setItem")


class OutputFile(unittest.TestCase):
    def run_main_with(self, ec2, out, *argv, pre=None):
        class STS:
            def get_caller_identity(self):
                return {"Account": "111122223333", "Arn": "arn:test"}

        class Session:
            def client(self, service, **kw):
                return ec2 if service == "ec2" else STS()

        with mock.patch.object(cli.boto3, "Session", lambda **kw: Session()), mock.patch.object(collect.time, "sleep"):
            return cli.main(["--region", "r", "--markets", "on-demand", "--amounts", "1", "--types", "a.large",
                            "--azs", "use1-az1", *files_for(out), *argv])

    def test_existing_file_is_refused_before_the_account_is_touched(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "r.html"
            out.write_text("keep me")
            ec2 = FakeEc2(disabled=True)
            rc = self.run_main_with(ec2, out, "--enable", "--expect-account", "111122223333")
            self.assertEqual(rc, 4)
            self.assertEqual(out.read_text(), "keep me")
            self.assertFalse(ec2.enabled_called)
            self.assertEqual(ec2.calls, [])

    def test_overwrite_replaces_and_file_is_owner_only(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "r.html"
            out.write_text("old")
            rc = self.run_main_with(FakeEc2(), out, "--overwrite")
            self.assertEqual(rc, 0)
            self.assertIn("a.large", out.read_text(encoding="utf-8"))
            self.assertEqual(out.stat().st_mode & 0o077, 0)

    def test_symlink_without_overwrite_is_refused_and_target_untouched(self):
        with tempfile.TemporaryDirectory() as d:
            target = Path(d) / "target.txt"
            target.write_text("precious")
            link = Path(d) / "r.html"
            link.symlink_to(target)
            rc = self.run_main_with(FakeEc2(), link)
            self.assertEqual(rc, 4)
            self.assertEqual(target.read_text(), "precious")

    def test_symlink_with_overwrite_is_replaced_not_followed(self):
        with tempfile.TemporaryDirectory() as d:
            target = Path(d) / "target.txt"
            target.write_text("precious")
            link = Path(d) / "r.html"
            link.symlink_to(target)
            rc = self.run_main_with(FakeEc2(), link, "--overwrite")
            self.assertEqual(rc, 0)
            self.assertEqual(target.read_text(), "precious")
            self.assertFalse(link.is_symlink())
            self.assertIn("a.large", link.read_text(encoding="utf-8"))

    def test_a_crash_leaves_no_half_written_file_and_exits_five(self):
        class Crash(FakeEc2):
            def get_capacity_manager_supportability_scores(self, **kw):
                raise RuntimeError("boom")
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "r.html"
            self.assertEqual(self.run_main_with(Crash(), out), 5)
            self.assertEqual(list(Path(d).iterdir()), [])

    def test_a_failed_run_with_overwrite_keeps_the_old_report(self):
        class Crash(FakeEc2):
            def get_capacity_manager_supportability_scores(self, **kw):
                raise RuntimeError("boom")
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "r.html"
            out.write_text("old report")
            self.assertEqual(self.run_main_with(Crash(), out, "--overwrite"), 5)
            self.assertEqual(out.read_text(), "old report")
            self.assertEqual([p.name for p in Path(d).iterdir()], ["r.html"])

    def test_quota_refusal_happens_before_any_file_or_account_change(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "r.html"
            ec2 = FakeEc2(disabled=True)
            rc = self.run_main_with(ec2, out, "--enable", "--expect-account", "111122223333", "--amounts", *[str(i) for i in range(1, 97)])
            self.assertEqual(rc, 6)
            self.assertFalse(out.exists())
            self.assertFalse(ec2.enabled_called)

    def test_authentication_failure_exits_one(self):
        class Session:
            def client(self, service, **kw):
                raise EndpointConnectionError(endpoint_url="https://x")
        with mock.patch.object(cli.boto3, "Session", lambda **kw: Session()):
            self.assertEqual(cli.main(["--region", "r"]), 1)


class AccountSafety(unittest.TestCase):
    def test_enable_requires_an_expected_account(self):
        with self.assertRaises(SystemExit):
            cli.parse_args(["--region", "r", "--enable"])

    def test_bad_expected_account_and_max_calls_are_refused(self):
        for argv in (["--expect-account", "123"], ["--max-calls", "0"], ["--max-calls", "101"]):
            with self.assertRaises(SystemExit, msg=argv):
                cli.parse_args(["--region", "r"] + argv)

    def test_wrong_account_stops_everything_before_any_change(self):
        ec2 = FakeEc2(disabled=True)
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "r.html"
            rc = OutputFile().run_main_with(ec2, out, "--enable", "--expect-account", "999999999999")
            self.assertEqual(rc, 1)
            self.assertFalse(ec2.enabled_called)
            self.assertEqual(ec2.calls, [])
            self.assertFalse(out.exists())

    def test_max_calls_lowers_the_cap(self):
        ec2 = FakeEc2()
        with tempfile.TemporaryDirectory() as d:
            rc = OutputFile().run_main_with(ec2, Path(d) / "r.html", "--max-calls", "1", "--amounts", "1", "2")
            self.assertEqual(rc, 6)
            self.assertEqual(ec2.calls, [])

    def test_a_failed_run_with_overwrite_keeps_the_old_good_report(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "r.html"
            out.write_text("old good report")
            rc = OutputFile().run_main_with(FakeEc2(fail_on_call=1), out, "--overwrite")
            self.assertEqual(rc, 3)
            self.assertEqual(out.read_text(), "old good report")
            failed = sorted(p for p in Path(d).iterdir() if ".failed-" in p.name)
            self.assertEqual([p.suffix for p in failed], [".html", ".json"])
            self.assertEqual(failed[0].stat().st_mode & 0o077, 0)
            self.assertIn("UnauthorizedOperation", failed[0].read_text(encoding="utf-8"))
            self.assertEqual(json.loads(failed[1].read_text(encoding="utf-8"))["status"], 3)

    def test_status_three_never_fills_the_final_path_even_without_an_old_report(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "r.html"
            rc = OutputFile().run_main_with(FakeEc2(fail_on_call=1), out, "--overwrite")
            self.assertEqual(rc, 3)
            self.assertFalse(out.exists())  # the final path only ever holds reports of successful runs
            self.assertFalse(out.with_suffix(".json").exists())
            names = [p.name for p in Path(d).iterdir()]
            self.assertEqual(len(names), 2)  # the page and its data file
            self.assertTrue(all(".failed-" in n for n in names))

    def test_best_score_with_a_failed_request_is_marked_partial(self):
        res = collect.Result(cells={("a.large", "use1-az1"): "high"}, groups=[
            collect.Group(types=["a.large"], azs=["use1-az1"], aggregate="high"),
            collect.Group(types=["a.large"], azs=["use1-az2"], error="Boom: x", all_types=["a.large"], all_azs=["use1-az2"])])
        out = report_html.heatmap(res.cells, ["a.large"], ["use1-az1", "use1-az2"], collect.failed_pairs(res))
        self.assertIn("†", out)


class CliMore(unittest.TestCase):
    def test_types_and_requirements_together_are_refused(self):
        with self.assertRaises(SystemExit):
            cli.parse_args(["--region", "r", "--types", "a.large", "--requirements", '{"a": 1}'])

    def test_requirements_alone_is_accepted_and_counts_az_chunks(self):
        a = cli.parse_args(["--region", "r", "--requirements", '{"ArchitectureTypes":["x86_64"]}', "--markets", "spot",
                           "--amounts", "1", "--azs", *[f"use1-az{i}" for i in range(1, 12)]])
        self.assertEqual(cli.planned_calls(a), 2)

    def test_azs_of_one_region_stay_together(self):
        a = cli.parse_args(["--region", "r", "--azs", "use1-az1", "usw2-az1", "use1-az2"])
        self.assertEqual(a.azs, ["use1-az1", "use1-az2", "usw2-az1"])


class ErrorHandling(unittest.TestCase):
    """What the report and exit status do when things go wrong. Each case runs main() end to end."""

    def run_main(self, ec2, *argv, session=None):
        class STS:
            def get_caller_identity(self):
                return {"Account": "111122223333", "Arn": "arn:test"}

        class Session:
            def client(self, service, **kw):
                return ec2 if service == "ec2" else STS()

        factory = session or (lambda **kw: Session())
        with tempfile.TemporaryDirectory() as d, mock.patch.object(cli.boto3, "Session", factory), \
                mock.patch.object(collect.time, "sleep"):
            out = Path(d) / "r.html"
            rc = cli.main(["--region", "r", *files_for(out), *argv])
            return rc, read_html(d)

    def test_every_request_failing_still_gives_a_readable_report_and_status_three(self):
        ec2 = FakeEc2(fail_all=True)
        rc, page = self.run_main(ec2, "--types", "a.large", "b.large", "--azs", "use1-az1", "use1-az2",
                                 "--amounts", "1", "10")
        self.assertEqual(rc, 3)
        self.assertIn("did not obtain every score you asked for (exit status 3)", page)
        self.assertIn("UnauthorizedOperation", page)
        # 2 types x 2 AZs x 2 markets x 2 amounts request cells, plus the Best and sensitivity cells
        self.assertGreaterEqual(page.count('class="pill err">Error'), 16)
        self.assertTrue('class="pill low"' not in page.split("<tbody>", 1)[1])  # no score invented in any table
        self.assertGreaterEqual(len(ec2.calls), 4)  # on-demand and spot, two amounts: failures do not stop later requests

    def test_one_amount_failing_does_not_hide_the_others(self):
        ec2 = FakeEc2(fail_on_call=1)
        rc, page = self.run_main(ec2, "--types", "a.large", "--azs", "use1-az1", "--markets", "on-demand", "--amounts", "1", "2")
        self.assertEqual(rc, 3)
        self.assertIn('class="pill err">Error', page)
        self.assertIn('class="pill high">High', page)

    def test_throttling_is_recorded_like_any_other_error(self):
        rc, page = self.run_main(FakeEc2(fail_all=True, fail_code="Throttling"), "--types", "a.large", "--azs", "use1-az1",
                                 "--markets", "on-demand", "--amounts", "1")
        self.assertEqual(rc, 3)
        self.assertIn("Throttling", page)

    def test_a_bad_az_is_dropped_before_sending_and_reported(self):
        ec2 = FakeEc2(invalid_azs={"use1-az9"})
        rc, page = self.run_main(ec2, "--types", "a.large", "--azs", "use1-az1", "use1-az9", "--markets", "on-demand", "--amounts", "1")
        self.assertEqual(rc, 3)  # something asked for was left out
        self.assertEqual(ec2.calls[0]["CapacityAvailabilityZoneIds"], ["use1-az1"])
        self.assertIn("use1-az9", page)
        self.assertIn("AZ IDs that EC2 does not know", page)

    def test_a_typo_in_one_type_costs_only_that_type(self):
        ec2 = FakeEc2()
        rc, page = self.run_main(ec2, "--types", "a.large", "zzz.large", "--azs", "use1-az1", "--markets", "on-demand", "--amounts", "1")
        self.assertEqual(rc, 3)
        self.assertEqual(ec2.calls[0]["InstanceTypes"], ["a.large"])
        self.assertIn("zzz.large", page)
        self.assertIn('class="pill high">High', page)
        self.assertIn('class="pill no">Not offered', page)

    def test_nothing_left_to_send_makes_no_capacity_manager_request(self):
        ec2 = FakeEc2()
        rc, page = self.run_main(ec2, "--types", "zzz.large", "--azs", "use1-az1", "--markets", "on-demand", "--amounts", "1")
        self.assertEqual(rc, 3)
        self.assertEqual(ec2.calls, [])
        self.assertIn("Nothing was left to send", page)

    def test_a_pair_not_offered_in_one_az_is_marked_and_the_rest_is_still_sent(self):
        ec2 = FakeEc2(not_offered={("a.large", "use1-az2")})
        rc, page = self.run_main(ec2, "--types", "a.large", "--azs", "use1-az1", "use1-az2", "--markets", "on-demand", "--amounts", "1")
        self.assertEqual(rc, 0)  # sent as asked; EC2 says the pair does not exist, which is not a failure of the run
        self.assertEqual(len(ec2.calls), 1)
        self.assertIn('class="pill no">Not offered', page)

    def test_a_failing_preflight_never_blocks_the_run(self):
        ec2 = FakeEc2(preflight_error=ClientError({"Error": {"Code": "UnauthorizedOperation", "Message": "x"}}, "op"))
        rc, page = self.run_main(ec2, "--types", "a.large", "--azs", "use1-az1", "--markets", "on-demand", "--amounts", "1")
        self.assertEqual(rc, 0)
        self.assertEqual(len(ec2.calls), 1)
        self.assertIn("Could not check the AZs of us-east-1", page)

    def test_an_az_of_an_unknown_region_prefix_is_sent_unchecked_with_a_note(self):
        ec2 = FakeEc2()
        rc, page = self.run_main(ec2, "--types", "a.large", "--azs", "zzzz9-az1", "--markets", "on-demand", "--amounts", "1")
        self.assertEqual(ec2.calls[0]["CapacityAvailabilityZoneIds"], ["zzzz9-az1"])
        self.assertIn("not known to this tool", page)

    def test_capacity_manager_enabled_in_another_region_is_explained_and_never_enabled_here(self):
        err = ClientError({"Error": {"Code": "CapacityManager.IncorrectRegion", "Message": "already enabled in ap-northeast-1"}}, "op")
        ec2 = FakeEc2(attr_error=err)
        rc, page = self.run_main(ec2, "--enable", "--expect-account", "111122223333", "--types", "a.large", "--azs", "use1-az1")
        self.assertEqual(rc, 3)
        self.assertFalse(ec2.enabled_called)
        self.assertEqual(ec2.calls, [])
        self.assertIn("different Region", page)
        self.assertIn("ap-northeast-1", page)

    def test_unreadable_state_gives_a_report_and_status_three(self):
        err = ClientError({"Error": {"Code": "UnauthorizedOperation", "Message": "denied"}}, "op")
        rc, page = self.run_main(FakeEc2(attr_error=err), "--types", "a.large", "--azs", "use1-az1")
        self.assertEqual(rc, 3)
        self.assertIn("Could not read or enable Capacity Manager", page)

    def test_profile_not_found_exits_one_without_a_traceback(self):
        from botocore.exceptions import ProfileNotFound
        def boom(**kw):
            raise ProfileNotFound(profile="nope")
        rc, page = self.run_main(FakeEc2(), "--profile", "nope", session=boom)
        self.assertEqual(rc, 1)
        self.assertIsNone(page)

    def test_a_response_with_garbage_scores_is_an_error_not_a_crash(self):
        ec2 = FakeEc2(response={"AggregateScore": "high", "CapacityManagerSupportabilityScores": [{"InstanceType": 5}]})
        rc, page = self.run_main(ec2, "--types", "a.large", "--azs", "use1-az1", "--markets", "on-demand", "--amounts", "1")
        self.assertEqual(rc, 3)
        self.assertIn("UnexpectedResponse", page)

    def test_the_api_naming_a_bad_value_makes_the_tool_repeat_without_it(self):
        class Picky(FakeEc2):
            def get_capacity_manager_supportability_scores(self, **kw):
                if "zzzz9-az9" in kw["CapacityAvailabilityZoneIds"]:
                    self.calls.append(kw)
                    raise ClientError({"Error": {"Code": "InvalidParameterValue", "Message": "The Availability Zone ID 'zzzz9-az9' isn't valid."}}, "op")
                return super().get_capacity_manager_supportability_scores(**kw)
        ec2 = Picky()
        rc, page = self.run_main(ec2, "--types", "a.large", "--azs", "use1-az1", "zzzz9-az9", "--markets", "on-demand", "--amounts", "1")
        self.assertEqual(rc, 3)  # something asked for was left out
        self.assertEqual(len(ec2.calls), 2)
        self.assertEqual(ec2.calls[1]["CapacityAvailabilityZoneIds"], ["use1-az1"])
        self.assertIn("rejected a value by name", page)
        self.assertIn('class="pill high">High', page)

    def test_repeats_stay_inside_the_call_cap(self):
        class Picky(FakeEc2):
            def get_capacity_manager_supportability_scores(self, **kw):
                self.calls.append(kw)
                raise ClientError({"Error": {"Code": "InvalidParameterValue", "Message": "The instance type 'a.large' isn't available."}}, "op")
        ec2 = Picky()
        rc, _ = self.run_main(ec2, "--types", "a.large", "b.large", "c.large", "--azs", "use1-az1", "--markets", "on-demand",
                              "--amounts", "1", "--max-calls", "1")
        self.assertEqual(rc, 3)
        self.assertEqual(len(ec2.calls), 1)  # budget 0: no repeat

    def test_a_message_that_names_nothing_in_the_request_is_not_retried(self):
        class Vague(FakeEc2):
            def get_capacity_manager_supportability_scores(self, **kw):
                self.calls.append(kw)
                raise ClientError({"Error": {"Code": "InvalidParameterValue", "Message": "CapacityAmount can't be more than 100000."}}, "op")
        ec2 = Vague()
        rc, _ = self.run_main(ec2, "--types", "a.large", "--azs", "use1-az1", "--markets", "on-demand", "--amounts", "1")
        self.assertEqual(rc, 3)
        self.assertEqual(len(ec2.calls), 1)

    def test_invalid_value_hint_tells_the_reader_that_one_bad_value_fails_the_request(self):
        rc, page = self.run_main(FakeEc2(fail_all=True, fail_code="InvalidParameterValue"), "--types", "a.large",
                                 "--azs", "use1-az1", "--markets", "on-demand", "--amounts", "1")
        self.assertIn("One invalid value makes the whole request fail", page)


class Robustness(ErrorHandling):
    """More end-to-end failure cases. Inherits the main() harness from ErrorHandling (its own tests run again, which is cheap)."""

    def run_capture(self, ec2, *argv):
        import contextlib
        import io
        err, outb = io.StringIO(), io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(outb):
            rc, page = self.run_main(ec2, *argv)
        return rc, page, err.getvalue()

    def test_sigterm_ends_the_run_cleanly_without_leaving_files_or_touching_the_path(self):
        import os as _os
        import signal as _signal

        class Killed(FakeEc2):
            def get_capacity_manager_supportability_scores(self, **kw):
                _os.kill(_os.getpid(), _signal.SIGTERM)
                return super().get_capacity_manager_supportability_scores(**kw)

        class STS:
            def get_caller_identity(self):
                return {"Account": "111122223333", "Arn": "arn:test"}

        ec2 = Killed()

        class Session:
            def client(self, service, **kw):
                return ec2 if service == "ec2" else STS()

        before = _signal.getsignal(_signal.SIGTERM)
        with tempfile.TemporaryDirectory() as d, mock.patch.object(cli.boto3, "Session", lambda **kw: Session()):
            out = Path(d) / "r.html"
            out.write_text("previous")
            rc = cli.main(["--region", "r", "--types", "a.large", "--azs", "use1-az1", "--markets", "on-demand",
                          "--amounts", "1", *files_for(out), "--overwrite"])
            self.assertEqual(rc, 130)
            self.assertEqual(out.read_text(), "previous")
            self.assertEqual([p.name for p in Path(d).iterdir()], ["r.html"])
        self.assertEqual(_signal.getsignal(_signal.SIGTERM), before)  # the handler is restored

    def test_a_leftover_temporary_file_does_not_block_the_next_run(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / ".r.html.1.deadbeef.tmp").write_text("")
            out = Path(d) / "r.html"
            rc = OutputFile().run_main_with(FakeEc2(), out)
            self.assertEqual(rc, 0)
            self.assertTrue(out.exists())

    def test_a_directory_as_out_is_refused_with_its_own_message(self):
        with tempfile.TemporaryDirectory() as d:
            import contextlib
            import io
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                rc = OutputFile().run_main_with(FakeEc2(), Path(d), "--overwrite")
            self.assertEqual(rc, 4)
            self.assertIn("is a directory", err.getvalue())

    def test_the_final_path_appearing_during_the_run_is_not_clobbered_and_the_status_says_so(self):
        holder = {}

        class Racy(FakeEc2):
            def get_capacity_manager_supportability_scores(self, **kw):
                holder["path"].write_text("someone else")
                return super().get_capacity_manager_supportability_scores(**kw)

        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "r.html"
            holder["path"] = out
            rc = OutputFile().run_main_with(Racy(), out)
            self.assertEqual(rc, 4)  # the scores are fine, but the report is not where it was asked to be
            self.assertEqual(out.read_text(), "someone else")
            self.assertTrue(any(".unplaced-" in p.name for p in Path(d).iterdir()))

    def test_file_systems_without_hard_links_still_get_an_exclusive_placement(self):
        with tempfile.TemporaryDirectory() as d, mock.patch.object(files.os, "link", side_effect=OSError(1, "not permitted")):
            out = Path(d) / "r.html"
            rc = OutputFile().run_main_with(FakeEc2(), out)
            self.assertEqual(rc, 0)
            self.assertIn("a.large", out.read_text(encoding="utf-8"))
            self.assertEqual(out.stat().st_mode & 0o077, 0)
            self.assertEqual(sorted(p.name for p in Path(d).iterdir()), ["r.html", "r.json"])

    def test_no_hard_links_and_the_path_appearing_still_does_not_clobber(self):
        holder = {}

        class Racy(FakeEc2):
            def get_capacity_manager_supportability_scores(self, **kw):
                holder["path"].write_text("someone else")
                return super().get_capacity_manager_supportability_scores(**kw)

        with tempfile.TemporaryDirectory() as d, mock.patch.object(files.os, "link", side_effect=OSError(1, "no")):
            out = Path(d) / "r.html"
            holder["path"] = out
            rc = OutputFile().run_main_with(Racy(), out)
            self.assertEqual(rc, 4)
            self.assertEqual(out.read_text(), "someone else")

    def test_a_long_output_name_does_not_break_the_temporary_file(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / (("x" * 200) + ".html")
            rc = OutputFile().run_main_with(FakeEc2(), out)
            self.assertEqual(rc, 0)
            self.assertTrue(out.exists())
            rc = OutputFile().run_main_with(FakeEc2(fail_all=True), Path(d) / (("y" * 250) + ".html"))
            self.assertEqual(rc, 3)

    def test_an_ignored_hangup_stays_ignored_so_nohup_still_works(self):
        import signal as _signal
        if not hasattr(_signal, "SIGHUP"):
            self.skipTest("no SIGHUP on this platform")
        old = _signal.signal(_signal.SIGHUP, _signal.SIG_IGN)
        try:
            with tempfile.TemporaryDirectory() as d:
                OutputFile().run_main_with(FakeEc2(), Path(d) / "r.html")
            self.assertEqual(_signal.getsignal(_signal.SIGHUP), _signal.SIG_IGN)
        finally:
            _signal.signal(_signal.SIGHUP, old)

    def test_an_incomplete_run_prints_a_result_line_and_reasons_on_stderr(self):
        rc, page, err = self.run_capture(FakeEc2(fail_all=True), "--types", "a.large", "--azs", "use1-az1",
                                         "--markets", "on-demand", "--amounts", "1")
        self.assertEqual(rc, 3)
        self.assertIn("RESULT: INCOMPLETE (exit status 3)", err)
        self.assertIn("on-demand x1: 1 of 1 requests failed", err)
        self.assertIn(".failed-", err)

    def test_a_complete_run_says_so(self):
        import contextlib
        import io
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc, _ = self.run_main(FakeEc2(), "--types", "a.large", "--azs", "use1-az1", "--markets", "on-demand", "--amounts", "1")
        self.assertEqual(rc, 0)
        self.assertIn("RESULT: complete", err.getvalue())
        # Standard output carries only the result, so a pipe never sees progress messages.
        self.assertNotIn("RESULT", out.getvalue())
        self.assertNotIn("calls planned", out.getvalue())
        self.assertIn("result: complete", out.getvalue())

    def test_a_value_rejected_once_is_not_paid_for_again(self):
        class Picky(FakeEc2):
            def get_capacity_manager_supportability_scores(self, **kw):
                self.calls.append(kw)
                if "zzzz9-az9" in kw["CapacityAvailabilityZoneIds"]:
                    raise ClientError({"Error": {"Code": "InvalidParameterValue", "Message": "The Availability Zone ID 'zzzz9-az9' isn't valid."}}, "op")
                return {"AggregateScore": "high", "CapacityManagerSupportabilityScores": [
                    {"InstanceType": t, "AvailabilityZoneId": a, "Score": "high"} for t in kw["InstanceTypes"] for a in kw["CapacityAvailabilityZoneIds"]]}
        ec2 = Picky()
        self.run_main(ec2, "--types", "a.large", "--azs", "use1-az1", "zzzz9-az9", "--markets", "on-demand", "--amounts", "1", "2", "3")
        self.assertEqual(len(ec2.calls), 2 + 1 + 1)  # first amount: failure + repeat; the others go straight without it

    def test_a_type_rejected_for_one_az_set_is_not_dropped_for_another(self):
        class Picky(FakeEc2):
            def get_capacity_manager_supportability_scores(self, **kw):
                self.calls.append(kw)
                if "q.large" in kw["InstanceTypes"] and "use1-az1" in kw["CapacityAvailabilityZoneIds"]:
                    raise ClientError({"Error": {"Code": "InvalidParameterValue", "Message": "The instance type 'q.large' isn't available in the specified Availability Zones."}}, "op")
                return {"AggregateScore": "high", "CapacityManagerSupportabilityScores": [
                    {"InstanceType": t, "AvailabilityZoneId": a, "Score": "high"} for t in kw["InstanceTypes"] for a in kw["CapacityAvailabilityZoneIds"]]}
        azs = [f"use1-az{i}" for i in range(1, 12)]  # chunks: 10 AZs, then ['use1-az9'..] differs
        ec2 = Picky()
        rc, page = self.run_main(ec2, "--types", "q.large", "a.large", "--azs", *azs, "--markets", "on-demand", "--amounts", "1")
        sent_with_q = [c for c in ec2.calls if "q.large" in c["InstanceTypes"]]
        self.assertTrue(any(c["CapacityAvailabilityZoneIds"] == ["use1-az11"] for c in sent_with_q))  # still tried in the other AZ set

    def test_a_rejection_is_remembered_even_when_there_is_no_budget_to_repeat(self):
        class Picky(FakeEc2):
            def get_capacity_manager_supportability_scores(self, **kw):
                self.calls.append(kw)
                if "zzzz9-az9" in kw["CapacityAvailabilityZoneIds"]:
                    raise ClientError({"Error": {"Code": "InvalidParameterValue", "Message": "The Availability Zone ID 'zzzz9-az9' isn't valid."}}, "op")
                return {"AggregateScore": "high", "CapacityManagerSupportabilityScores": [
                    {"InstanceType": t, "AvailabilityZoneId": a, "Score": "high"} for t in kw["InstanceTypes"] for a in kw["CapacityAvailabilityZoneIds"]]}
        ec2 = Picky()
        self.run_main(ec2, "--types", "a.large", "--azs", "use1-az1", "zzzz9-az9", "--markets", "on-demand",
                      "--amounts", "1", "2", "3", "--max-calls", "3")  # budget 0: no repeat, but the next requests skip it
        self.assertEqual(len(ec2.calls), 3)
        self.assertEqual(sum("zzzz9-az9" in c["CapacityAvailabilityZoneIds"] for c in ec2.calls), 1)

    def test_a_type_rejected_for_the_same_az_set_is_skipped_by_later_requests(self):
        class Picky(FakeEc2):
            def get_capacity_manager_supportability_scores(self, **kw):
                self.calls.append(kw)
                if "q.large" in kw["InstanceTypes"]:
                    raise ClientError({"Error": {"Code": "InvalidParameterValue", "Message": "The instance type 'q.large' isn't available in the specified Availability Zones."}}, "op")
                return {"AggregateScore": "high", "CapacityManagerSupportabilityScores": [
                    {"InstanceType": t, "AvailabilityZoneId": a, "Score": "high"} for t in kw["InstanceTypes"] for a in kw["CapacityAvailabilityZoneIds"]]}
        ec2 = Picky()
        self.run_main(ec2, "--types", "a.large", "q.large", "--azs", "use1-az1", "--markets", "on-demand", "--amounts", "1", "2")
        self.assertEqual(len(ec2.calls), 3)  # amount 1: failure + repeat without q; amount 2: straight without q
        self.assertNotIn("q.large", ec2.calls[2]["InstanceTypes"])

    def test_an_ignored_hangup_does_not_interrupt_a_run(self):
        import os as _os
        import signal as _signal
        if not hasattr(_signal, "SIGHUP"):
            self.skipTest("no SIGHUP on this platform")

        class Hup(FakeEc2):
            def get_capacity_manager_supportability_scores(self, **kw):
                _os.kill(_os.getpid(), _signal.SIGHUP)
                return super().get_capacity_manager_supportability_scores(**kw)

        old = _signal.signal(_signal.SIGHUP, _signal.SIG_IGN)
        try:
            rc, page = self.run_main(Hup(), "--types", "a.large", "--azs", "use1-az1", "--markets", "on-demand", "--amounts", "1")
            self.assertEqual(rc, 0)
            self.assertIsNotNone(page)
        finally:
            _signal.signal(_signal.SIGHUP, old)

    def test_the_request_count_includes_repeats(self):
        class Picky(FakeEc2):
            def get_capacity_manager_supportability_scores(self, **kw):
                self.calls.append(kw)
                if "zzzz9-az9" in kw["CapacityAvailabilityZoneIds"]:
                    raise ClientError({"Error": {"Code": "InvalidParameterValue", "Message": "The Availability Zone ID 'zzzz9-az9' isn't valid."}}, "op")
                return {"AggregateScore": "high", "CapacityManagerSupportabilityScores": [
                    {"InstanceType": t, "AvailabilityZoneId": a, "Score": "high"} for t in kw["InstanceTypes"] for a in kw["CapacityAvailabilityZoneIds"]]}
        ec2 = Picky()
        rc, page = self.run_main(ec2, "--types", "a.large", "--azs", "use1-az1", "zzzz9-az9", "--markets", "on-demand", "--amounts", "1")
        self.assertEqual(len(ec2.calls), 2)
        self.assertIn("<div class='v'>2</div>", page)

    def test_a_type_rejection_is_found_again_after_a_known_bad_az_is_removed(self):
        class Picky(FakeEc2):
            def get_capacity_manager_supportability_scores(self, **kw):
                self.calls.append(kw)
                if "zzzz9-az9" in kw["CapacityAvailabilityZoneIds"]:
                    raise ClientError({"Error": {"Code": "InvalidParameterValue", "Message": "The Availability Zone ID 'zzzz9-az9' isn't valid."}}, "op")
                if "q.large" in kw["InstanceTypes"]:
                    raise ClientError({"Error": {"Code": "InvalidParameterValue", "Message": "The instance type 'q.large' isn't available in the specified Availability Zones."}}, "op")
                return {"AggregateScore": "high", "CapacityManagerSupportabilityScores": [
                    {"InstanceType": t, "AvailabilityZoneId": a, "Score": "high"} for t in kw["InstanceTypes"] for a in kw["CapacityAvailabilityZoneIds"]]}
        ec2 = Picky()
        self.run_main(ec2, "--types", "a.large", "q.large", "--azs", "use1-az1", "zzzz9-az9", "--markets", "on-demand", "--amounts", "1", "2", "--max-calls", "20")
        # amount 1: bad AZ rejected, repeat, bad type rejected, repeat (3 calls); amount 2 must go straight through (1 call)
        self.assertEqual(len(ec2.calls), 4)

    def test_the_request_count_is_the_number_actually_sent(self):
        rc, page = self.run_main(FakeEc2(), "--types", "zzz.large", "--azs", "use1-az1", "--markets", "on-demand", "--amounts", "1")
        self.assertIn("<div class='v'>0</div>", page)

    def test_only_the_documented_message_shapes_name_a_rejected_value(self):
        self.assertEqual(collect.rejected_value("InvalidParameterValue: The instance type 'x.large' isn't available in the specified Availability Zones.", ["x.large"], ["a"]), ("x.large", "type"))
        self.assertEqual(collect.rejected_value("InvalidParameterValue: The Availability Zone ID 'a' isn't valid.", ["x.large"], ["a"]), ("a", "az"))
        self.assertIsNone(collect.rejected_value("InvalidParameterValue: CapacityAmount can't be more than 'x.large'.", ["x.large"], ["a"]))
        self.assertIsNone(collect.rejected_value("Throttling: The instance type 'x.large' isn't available", ["x.large"], ["a"]))

    def test_a_dropped_type_shows_error_cells_and_the_run_is_incomplete(self):
        class Picky(FakeEc2):
            def get_capacity_manager_supportability_scores(self, **kw):
                self.calls.append(kw)
                if "q.large" in kw["InstanceTypes"]:
                    raise ClientError({"Error": {"Code": "InvalidParameterValue", "Message": "The instance type 'q.large' isn't available in the specified Availability Zones."}}, "op")
                return {"AggregateScore": "high", "CapacityManagerSupportabilityScores": [
                    {"InstanceType": t, "AvailabilityZoneId": a, "Score": "high"} for t in kw["InstanceTypes"] for a in kw["CapacityAvailabilityZoneIds"]]}
        # the fake offerings call says everything is offered, so only the API can reject q.large
        rc, page = self.run_main(Picky(), "--types", "a.large", "q.large", "--azs", "use1-az1", "--markets", "on-demand", "--amounts", "1")
        self.assertEqual(rc, 3)
        table = page.split("<tbody>", 1)[1]
        self.assertIn('class="pill err">Error', table)
        self.assertIn('class="pill high">High', table)

    def test_attribute_mode_failure_warns_and_marks_every_best_value(self):
        class Half(FakeEc2):
            def get_capacity_manager_supportability_scores(self, **kw):
                self.calls.append(kw)
                if len(self.calls) == 2:
                    raise ClientError({"Error": {"Code": "UnauthorizedOperation", "Message": "denied"}}, "op")
                return {"AggregateScore": "high", "CapacityManagerSupportabilityScores": [
                    {"InstanceType": "r.large", "AvailabilityZoneId": a, "Score": "high"} for a in kw["CapacityAvailabilityZoneIds"]]}
        azs = [f"use1-az{i}" for i in range(1, 12)]  # two requests
        rc, page = self.run_main(Half(), "--requirements", '{"VirtualizationTypes":["hvm"]}', "--azs", *azs, "--markets", "on-demand", "--amounts", "1")
        self.assertEqual(rc, 3)
        self.assertIn("1 of 2 requests failed", page)
        self.assertIn("†", page)

    def test_partial_flag_marks_the_best_column_in_both_tables(self):
        cells = {("r.large", "use1-az1"): "high"}
        self.assertIn("†", report_html.heatmap(cells, ["r.large"], ["use1-az1"], partial=True).split('class="bestcol"')[1])
        self.assertNotIn("†", report_html.heatmap(cells, ["r.large"], ["use1-az1"], partial=False))
        res = collect.Result(cells=cells, groups=[collect.Group(types=None, azs=["use1-az1"], aggregate="high"),
                                             collect.Group(types=None, azs=["use1-az2"], error="Boom: x")])
        self.assertTrue(res.partial)
        self.assertIn("†", report_html.sensitivity({1: res}, ["r.large"], ["use1-az1"], [1]))

    def test_all_azs_invalid_does_not_blame_the_instance_types(self):
        ec2 = FakeEc2(invalid_azs={"use1-az1"})
        rc, page = self.run_main(ec2, "--types", "a.large", "--azs", "use1-az1", "--markets", "on-demand", "--amounts", "1")
        self.assertEqual(rc, 3)
        self.assertIn("AZ IDs that EC2 does not know", page)
        self.assertNotIn("Instance types not offered in any requested AZ", page)

    def test_a_market_with_nothing_sent_says_so_instead_of_showing_empty_tables(self):
        rc, page = self.run_main(FakeEc2(disabled=True), "--types", "a.large", "--azs", "use1-az1", "--markets", "on-demand", "--amounts", "1")
        self.assertEqual(rc, 3)
        self.assertIn("No request was sent for this market", page)
        self.assertNotIn("Best score per type as the requested amount grows", page)


class InputNormalisation(unittest.TestCase):
    def test_case_and_whitespace_are_normalised_and_deduplicated(self):
        a = cli.parse_args(["--region", "r", "--types", " M7I.large", "m7i.large ", "--azs", "USE1-AZ1", " use1-az1"])
        self.assertEqual(a.types, ["m7i.large"])
        self.assertEqual(a.azs, ["use1-az1"])

    def test_empty_values_are_refused(self):
        for argv in (["--types", ""], ["--azs", " "], ["--html", " "], ["--save-json", ""]):
            with self.assertRaises(SystemExit, msg=argv):
                cli.parse_args(["--region", "r"] + argv)

    def test_requirements_with_wrong_json_types_are_refused_before_anything_runs(self):
        for req in ('{"ArchitectureTypes":"x86_64"}', '{"VirtualizationTypes":[1]}', '{"InstanceRequirements":[1]}'):
            with self.assertRaises(SystemExit, msg=req):
                cli.parse_args(["--region", "r", "--requirements", req])


class DataFile(unittest.TestCase):
    """The page is built from the JSON data file and from nothing else."""

    def run_to(self, d, ec2, *argv):
        return OutputFile().run_main_with(ec2, Path(d) / "r.html", *argv)

    def test_every_run_writes_a_json_file_beside_the_page(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(self.run_to(d, FakeEc2()), 0)
            data = json.loads((Path(d) / "r.json").read_text(encoding="utf-8"))
            self.assertEqual(data["schema"], document.SCHEMA)
            self.assertEqual(data["status"], 0)
            self.assertEqual(data["request"]["markets"], ["on-demand"])
            self.assertEqual(data["results"]["on-demand"]["1"]["cells"], [["a.large", "use1-az1", "high"]])
            self.assertEqual((Path(d) / "r.json").stat().st_mode & 0o077, 0)

    def test_the_page_is_rebuilt_from_the_json_alone_without_any_aws_call(self):
        with tempfile.TemporaryDirectory() as d:
            self.run_to(d, FakeEc2())
            original = (Path(d) / "r.html").read_text(encoding="utf-8")
            with mock.patch.object(cli.boto3, "Session", side_effect=AssertionError("AWS must not be touched")):
                rc = cli.main(["--from-json", str(Path(d) / "r.json"), "--html", str(Path(d) / "again.html")])
            self.assertEqual(rc, 0)
            self.assertEqual((Path(d) / "again.html").read_text(encoding="utf-8"), original)

    def test_the_page_follows_the_json_not_the_run(self):
        with tempfile.TemporaryDirectory() as d:
            self.run_to(d, FakeEc2(score="high"))
            data = json.loads((Path(d) / "r.json").read_text(encoding="utf-8"))
            data["results"]["on-demand"]["1"]["cells"] = [["a.large", "use1-az1", "low"]]
            (Path(d) / "edited.json").write_text(json.dumps(data), encoding="utf-8")
            rc = cli.main(["--from-json", str(Path(d) / "edited.json"), "--html", str(Path(d) / "edited.html")])
            self.assertEqual(rc, 0)
            table = (Path(d) / "edited.html").read_text(encoding="utf-8").split("<tbody>", 1)[1]
            self.assertIn('class="pill low">Low', table)
            self.assertNotIn('class="pill high">High', table)

    def test_from_json_lets_the_language_change_without_a_new_run(self):
        with tempfile.TemporaryDirectory() as d:
            self.run_to(d, FakeEc2())
            cli.main(["--from-json", str(Path(d) / "r.json"), "--lang", "ja", "--html", str(Path(d) / "ja.html")])
            self.assertIn('<html lang="ja" data-lang-explicit="1"', (Path(d) / "ja.html").read_text(encoding="utf-8"))

    def test_to_data_and_from_data_round_trip_every_field_the_page_uses(self):
        res = collect.run_query(FakeEc2(fail_on_call=1), "spot", 3, "vcpus", ["a.large", "b.large"], ["use1-az1", "use1-az2"])
        res.groups[0].dropped.append(("zzz.large", "type", "InvalidParameterValue: x"))
        pf = collect.Preflight(azs=["use1-az1", "use1-az2"], types=["a.large", "b.large"], bad_azs=["use1-az9"],
                          excluded_types=["q.large"], not_offered={("a.large", "use1-az2")}, notes=[("en", "ja")])
        ctx = {"identity": {"Account": "1", "Arn": "a"}, "region": "r", "state": {"enabled": True, "status": "enabled", "error": None, "attrs": {"CapacityManagerStatus": "enabled"}},
               "log": [("x", "y")], "status": 3, "now": "t", "types": ["a.large", "b.large"], "azs": pf.azs, "pf": pf,
               "markets": ["spot"], "amounts": [3], "unit": "vcpus", "results": {"spot": {3: res}}, "calls": 1, "reasons": ["why"],
               "lang": "en", "lang_explicit": False}
        again = document.from_data(json.loads(json.dumps(document.to_data(ctx))))
        self.assertEqual(report_html.render(again), report_html.render(ctx))

    def test_a_bad_data_file_is_refused_with_a_reason_and_exit_two(self):
        import contextlib
        import io
        good = None
        with tempfile.TemporaryDirectory() as d:
            self.run_to(d, FakeEc2())
            good = json.loads((Path(d) / "r.json").read_text(encoding="utf-8"))
            cases = {"schema": lambda x: x.update(schema="other/9"),
                     "score": lambda x: x["results"]["on-demand"]["1"].update(cells=[["a", "b", "excellent"]]),
                     "markets": lambda x: x["request"].update(markets=["reserved"]),
                     "amounts": lambda x: x["request"].update(amounts=[0]),
                     "missing results": lambda x: x["results"].pop("on-demand"),
                     "not an object": lambda x: None}
            for name, mutate in cases.items():
                bad = json.loads(json.dumps(good))
                mutate(bad)
                f = Path(d) / f"{name.replace(' ', '_')}.json"
                f.write_text(json.dumps(bad if name != "not an object" else [1]), encoding="utf-8")
                err = io.StringIO()
                with contextlib.redirect_stderr(err):
                    rc = cli.main(["--from-json", str(f), "--html", str(Path(d) / f"{f.stem}.html")])
                self.assertEqual(rc, 2, name)
                self.assertIn("Cannot use the data file", err.getvalue(), name)
                self.assertFalse((Path(d) / f"{f.stem}.html").exists(), name)

    def test_a_missing_or_broken_json_file_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "broken.json").write_text("{", encoding="utf-8")
            for name in ("nope.json", "broken.json"):
                self.assertEqual(cli.main(["--from-json", str(Path(d) / name), "--html", str(Path(d) / "x.html")]), 2)

    def test_markup_inside_a_data_file_is_escaped_by_the_page(self):
        with tempfile.TemporaryDirectory() as d:
            self.run_to(d, FakeEc2())
            data = json.loads((Path(d) / "r.json").read_text(encoding="utf-8"))
            evil = "<img src=x onerror=alert(1)>"
            # Free-text fields may hold anything and are escaped by the page.
            data["identity"]["Arn"] = evil
            data["state"]["error"] = evil
            (Path(d) / "evil.json").write_text(json.dumps(data), encoding="utf-8")
            self.assertEqual(cli.main(["--from-json", str(Path(d) / "evil.json"), "--html", str(Path(d) / "evil.html")]), 0)
            self.assertNotIn(evil, (Path(d) / "evil.html").read_text(encoding="utf-8"))
            # Instance types and AZ IDs are names, and a value that is not one is refused before anything is printed.
            data["request"]["types"] = [evil]
            data["results"]["on-demand"]["1"]["cells"] = [[evil, "use1-az1", "low"]]
            (Path(d) / "evil2.json").write_text(json.dumps(data), encoding="utf-8")
            self.assertEqual(cli.main(["--from-json", str(Path(d) / "evil2.json"), "--html", str(Path(d) / "evil2.html")]), 2)
            self.assertFalse((Path(d) / "evil2.html").exists())

    def test_the_json_file_follows_the_same_placement_rules_as_the_page(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "r.json").write_text("keep", encoding="utf-8")
            ec2 = FakeEc2(disabled=True)
            rc = self.run_to(d, ec2, "--enable", "--expect-account", "111122223333")
            self.assertEqual(rc, 4)  # the data file already exists: refused before the account is touched
            self.assertFalse(ec2.enabled_called)
            self.assertEqual((Path(d) / "r.json").read_text(), "keep")

    def test_a_run_renders_what_it_wrote_not_what_it_collected(self):
        real = document.to_data

        def altered(ctx):
            d = real(ctx)
            d["identity"]["Account"] = "999988887777"  # only visible if the page is built from the document
            return d

        with tempfile.TemporaryDirectory() as d, mock.patch.object(document, "to_data", altered):
            self.run_to(d, FakeEc2())
            self.assertIn("999988887777", (Path(d) / "r.html").read_text(encoding="utf-8"))
            self.assertIn("999988887777", (Path(d) / "r.json").read_text(encoding="utf-8"))

    def test_null_values_in_the_data_file_are_refused_not_a_traceback(self):
        import contextlib
        import io
        with tempfile.TemporaryDirectory() as d:
            self.run_to(d, FakeEc2())
            good = json.loads((Path(d) / "r.json").read_text(encoding="utf-8"))
            for mutate in (lambda x: x["results"]["on-demand"]["1"].update(cells=None),
                           lambda x: x["results"]["on-demand"]["1"].update(groups=None),
                           lambda x: x["preflight"].update(notes=None),
                           lambda x: x.update(log=None),
                           lambda x: x["results"]["on-demand"]["1"]["groups"][0].update(dropped=None)):
                bad = json.loads(json.dumps(good))
                mutate(bad)
                f = Path(d) / "bad.json"
                f.write_text(json.dumps(bad), encoding="utf-8")
                err = io.StringIO()
                with contextlib.redirect_stderr(err):
                    rc = cli.main(["--from-json", str(f), "--html", str(Path(d) / "bad.html"), "--overwrite"])
                self.assertEqual(rc, 2)
                self.assertIn("Cannot use the data file", err.getvalue())

    def test_a_page_made_from_the_data_of_an_incomplete_run_is_named_failed(self):
        with tempfile.TemporaryDirectory() as d:
            self.run_to(d, FakeEc2(fail_all=True))
            failed_json = next(p for p in Path(d).iterdir() if p.suffix == ".json")
            rc = cli.main(["--from-json", str(failed_json), "--html", str(Path(d) / "again.html")])
            self.assertEqual(rc, 3)  # replaying an incomplete run says so, like the run did
            self.assertFalse((Path(d) / "again.html").exists())
            self.assertTrue(any(p.name.startswith("again.failed-") for p in Path(d).iterdir()))

    def test_from_json_refuses_to_overwrite_its_own_input(self):
        with tempfile.TemporaryDirectory() as d:
            self.run_to(d, FakeEc2())
            before = (Path(d) / "r.json").read_text()
            rc = cli.main(["--from-json", str(Path(d) / "r.json"), "--save-json", str(Path(d) / "r.json"), "--overwrite"])
            self.assertEqual(rc, 4)
            self.assertEqual((Path(d) / "r.json").read_text(), before)

    def test_when_the_data_file_cannot_be_placed_the_page_is_kept_beside_it(self):
        holder = {}

        class Racy(FakeEc2):
            def get_capacity_manager_supportability_scores(self, **kw):
                holder["json"].write_text("someone else")
                return super().get_capacity_manager_supportability_scores(**kw)

        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "r.html"
            holder["json"] = Path(d) / "r.json"
            rc = OutputFile().run_main_with(Racy(), out)
            self.assertEqual(rc, 4)
            self.assertFalse(out.exists())  # the page does not sit alone at the target
            self.assertEqual((Path(d) / "r.json").read_text(), "someone else")
            self.assertEqual(sum(".unplaced-" in p.name for p in Path(d).iterdir()), 2)

    def test_a_failed_copy_on_a_file_system_without_hard_links_leaves_no_truncated_file(self):
        real_open = os.fdopen

        def broken_fdopen(fd, *a, **k):
            f = real_open(fd, *a, **k)
            class Boom:
                def __enter__(self_inner):
                    return self_inner
                def __exit__(self_inner, *x):
                    f.close()
                def write(self_inner, text):
                    f.write(text[:5])
                    raise OSError(28, "No space left on device")
            return Boom()

        with tempfile.TemporaryDirectory() as d, mock.patch.object(files.os, "link", side_effect=OSError(1, "no")):
            tmp = Path(d) / ".t.tmp"
            tmp.write_text("complete report")
            target = Path(d) / "r.html"
            with mock.patch.object(files.os, "fdopen", broken_fdopen):
                final, note, ok = files.place_report(tmp, target, 0, False, "stamp")
            self.assertFalse(ok)
            self.assertFalse(target.exists())
            self.assertTrue(final.exists())
            self.assertEqual(final.read_text(), "complete report")

    def test_a_signal_during_placement_waits_until_both_files_are_placed(self):
        cli._critical.update(on=True, pending=False)
        try:
            cli._interrupt(15, None)
            self.assertTrue(cli._critical["pending"])
        finally:
            cli._critical.update(on=False, pending=False)
        with self.assertRaises(KeyboardInterrupt):
            cli._interrupt(15, None)

    def test_html_and_save_json_cannot_name_the_same_file(self):
        with self.assertRaises(SystemExit) as e, mock.patch("sys.stderr"):
            cli.parse_args(["--region", "r", "--html", "/x/r.json", "--save-json", "/x/r.json"])
        self.assertEqual(e.exception.code, 2)

    def test_region_is_not_needed_with_from_json_but_is_otherwise(self):
        cli.parse_args(["--from-json", "x.json"])
        with self.assertRaises(SystemExit):
            cli.parse_args([])
        with self.assertRaises(SystemExit):
            cli.parse_args(["--from-json", "x.json", "--enable", "--expect-account", "111122223333"])


class Limits(unittest.TestCase):
    def test_a_51st_type_moves_to_a_second_request(self):
        plan = collect.plan_calls([f"t{i}.large" for i in range(51)], ["use1-az1"])
        self.assertEqual(sorted(len(tc) for tc, _ in plan), [1, 50])


if __name__ == "__main__":
    unittest.main()
