#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["boto3>=1.43.123"]
# ///
"""Run EC2 Capacity Manager real-time supportability checks and render one HTML report.

Flow: identify the caller -> read the Capacity Manager state (enable it only with --enable)
-> call get-capacity-manager-supportability-scores for every market x amount -> write a
self-contained bilingual (English / Japanese) HTML file.

The report restates what the AWS documentation says about the scores and nothing more:
  https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/capacity-manager-supportability.html

The scores are "EC2 Capacity Manager Data" under the AWS Service Terms. This tool runs in your
own account and writes the file only to your machine; sharing the file is up to you and the terms.

The visual style reproduces the Cloudscape Design System (visual-refresh) token values in plain
CSS; the token names are kept in comments so a real Cloudscape port is a mechanical swap.
"""
from __future__ import annotations

import argparse
import html
import json
import os
import re
import signal
import sys
import time
import webbrowser
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

import boto3
from botocore.exceptions import BotoCoreError, ClientError

JST = timezone(timedelta(hours=9))

# Documented limits (Check supportability > EC2 Capacity Manager quotas).
QUOTA_PER_HOUR = 100  # queries per account per hour
MAX_COMBOS_PER_CALL = 100  # instance type x Availability Zone combinations per request
# Request limits from the AWS CLI reference for get-capacity-manager-supportability-scores:
# up to 10 Availability Zones and up to 50 instance types per request.
MAX_AZ_PER_CALL = 10
MAX_TYPE_PER_CALL = 50
QUOTA_HEADROOM = 5  # default call cap = QUOTA_PER_HOUR - QUOTA_HEADROOM; lower it with --max-calls

RANK = {"high": 3, "medium": 2, "low": 1}

# AZ ID prefix -> Region, used only to group table columns. Unknown prefixes are shown as-is.
REGION_BY_PREFIX = {
    "use1": "us-east-1", "use2": "us-east-2", "usw1": "us-west-1", "usw2": "us-west-2",
    "apne1": "ap-northeast-1", "apne2": "ap-northeast-2", "apne3": "ap-northeast-3",
    "apse1": "ap-southeast-1", "apse2": "ap-southeast-2", "apse4": "ap-southeast-4",
    "aps1": "ap-south-1", "euw1": "eu-west-1", "euw2": "eu-west-2", "euw3": "eu-west-3",
    "euc1": "eu-central-1", "eun1": "eu-north-1", "eus2": "eu-south-2", "cac1": "ca-central-1",
    "sae1": "sa-east-1", "eus1": "eu-south-1", "euc2": "eu-central-2", "aps2": "ap-south-2",
    "apse3": "ap-southeast-3", "apse5": "ap-southeast-5", "ape1": "ap-east-1", "afs1": "af-south-1",
    "mes1": "me-south-1", "mec1": "me-central-1", "ilc1": "il-central-1", "caw1": "ca-west-1",
}

DEFAULT_TYPES = ["g6e.xlarge", "g5.xlarge", "p5en.48xlarge", "p6-b200.48xlarge",
                 "p6-b300.48xlarge", "trn2.48xlarge", "m7i.large"]
DEFAULT_AZS = ["apne1-az1", "apne1-az2", "apne1-az4", "usw2-az1", "usw2-az2", "usw2-az3",
               "usw2-az4", "use1-az2", "use1-az4", "use2-az1"]


# ---------------------------------------------------------------------------------------
# Request planning
# ---------------------------------------------------------------------------------------

def chunks(seq, n):
    return [seq[i:i + n] for i in range(0, len(seq), n)]


def region_of(az_id: str) -> str:
    prefix = az_id.split("-")[0]
    return REGION_BY_PREFIX.get(prefix, prefix)


def plan_calls(types, azs):
    """Split (types x azs) into requests that respect every documented per-request limit.

    Returns a list of (type_chunk, az_chunk). With attribute-based requirements the type list is
    unknown up front, so pass types=None and only the AZs are split.
    """
    az_n = max(1, min(MAX_AZ_PER_CALL, len(azs)))
    az_chunks = chunks(azs, az_n)
    if types is None:
        return [(None, ac) for ac in az_chunks]
    plan = []
    for ac in az_chunks:
        # The type width depends on this chunk's own AZ count, so a short last chunk is not penalised.
        type_n = max(1, min(MAX_TYPE_PER_CALL, MAX_COMBOS_PER_CALL // len(ac)))
        plan.extend((tc, ac) for tc in chunks(types, type_n))
    return plan


@dataclass
class Group:
    """One API call: the combinations it covered, its aggregate score and its error, if any."""
    types: list | None
    azs: list
    aggregate: str | None = None
    error: str | None = None
    dropped: list = field(default_factory=list)  # (value, kind, error): rejected by name, request repeated without it
    all_types: list | None = None  # what was asked for in this request before anything was dropped
    all_azs: list = field(default_factory=list)


@dataclass
class Result:
    """All calls for one market x amount."""
    cells: dict = field(default_factory=dict)  # (instance_type, az_id) -> score
    groups: list = field(default_factory=list)
    retries: int = 0  # extra requests sent after dropping a value the API rejected
    sent: int = 0     # requests actually sent to the API

    @property
    def partial(self) -> bool:
        """True when a request failed or lost a value and its pairs cannot be listed (attribute-based mode)."""
        return any((g.error or g.dropped) and g.all_types is None for g in self.groups)

    @property
    def types(self):
        return sorted({t for t, _ in self.cells})


def err_text(e: Exception) -> str:
    if isinstance(e, ClientError):
        c = e.response.get("Error", {})
        return f"{c.get('Code', 'ClientError')}: {c.get('Message', '')}"
    return f"{type(e).__name__}: {e}"


MAX_DROP_RETRIES = 3  # per request: repeat at most this many times after dropping a rejected value
_REJECTED = re.compile(r"(Availability Zone ID|instance type) '([^']+)'")


def rejected_value(error_text: str, types, azs):
    """Return (value, kind) for the instance type or AZ ID that an InvalidParameterValue message names.

    The wording is observed behaviour (2026-11-05), not documented: "The Availability Zone ID 'X' isn't
    valid." and "The instance type 'X' isn't available in the specified Availability Zones." Anything else
    leaves the request failed as before.
    """
    if not error_text.startswith("InvalidParameterValue"):
        return None
    for label, value in _REJECTED.findall(error_text):
        if label == "Availability Zone ID" and value in azs:
            return value, "az"
        if label == "instance type" and types is not None and value in types:
            return value, "type"
    return None


def run_query(ec2, market, amount, unit, types, azs, requirements=None, retry_budget=None, known_bad=None) -> Result:
    """Score one market x amount.

    retry_budget: one-element list, the number of extra requests still allowed in the whole run.
    known_bad: set of rejections already seen in this run, removed up front so the same mistake is not paid for
    again by every request: ("az", value, None) applies everywhere; ("type", value, frozenset of AZs) applies only
    to requests with exactly that AZ set, because the message says the type is not available in "the specified
    Availability Zones", which says nothing about other AZs.
    """
    budget = retry_budget if retry_budget is not None else [MAX_DROP_RETRIES * 1000]
    bad_seen = known_bad if known_bad is not None else set()
    res = Result()
    for type_chunk, az_chunk in plan_calls(None if requirements is not None else types, azs):
        group = Group(types=None if type_chunk is None else list(type_chunk), azs=list(az_chunk),
                      all_types=None if type_chunk is None else list(type_chunk), all_azs=list(az_chunk))
        res.groups.append(group)
        for kind, value, _where in sorted(bad_seen, key=lambda x: (x[0], x[1])):
            if kind == "az" and value in group.azs:
                group.azs.remove(value)
                group.dropped.append((value, kind, "InvalidParameterValue: rejected earlier in this run"))
        scope = frozenset(group.azs)  # after the AZ removals, the same set the rejection was recorded against
        for kind, value, where in sorted(bad_seen, key=lambda x: (x[0], x[1])):
            if kind == "type" and where == scope and group.types is not None and value in group.types:
                group.types.remove(value)
                group.dropped.append((value, kind, "InvalidParameterValue: rejected earlier in this run"))
        for attempt in range(MAX_DROP_RETRIES + 1):
            if not group.azs or (group.types is not None and not group.types):
                group.error = group.error or "NothingToSend: every value of this request was rejected"
                break
            kwargs = dict(MarketType=market, CapacityAmount=amount, CapacityUnit=unit,
                          CapacityAvailabilityZoneIds=group.azs)
            if requirements is not None:
                kwargs["InstanceRequirementsWithMetadata"] = requirements
            else:
                kwargs["InstanceTypes"] = group.types
            try:
                res.sent += 1
                r = ec2.get_capacity_manager_supportability_scores(**kwargs)
            except (ClientError, BotoCoreError) as e:
                group.error = err_text(e)
                found = rejected_value(group.error, group.types, group.azs)
                if found is not None:
                    # Remember the rejection even when there is no budget to repeat, so later requests skip it.
                    bad_seen.add((found[1], found[0], None if found[1] == "az" else frozenset(group.azs)))
                if found is None or attempt >= MAX_DROP_RETRIES or budget[0] <= 0:
                    break
                value, kind = found
                # One invalid value fails the whole request, so repeat it without that value.
                if kind == "az":
                    group.azs = [x for x in group.azs if x != value]
                else:
                    group.types = [x for x in group.types if x != value]
                group.dropped.append((value, kind, group.error))
                if not group.azs or (group.types is not None and not group.types):
                    group.error = "NothingToSend: every value of this request was rejected"
                    break
                budget[0] -= 1
                res.retries += 1
                group.error = None
                continue
            group.error = None
            rows = r.get("CapacityManagerSupportabilityScores") if isinstance(r, dict) else None
            agg = r.get("AggregateScore") if isinstance(r, dict) else None
            if not isinstance(rows, list) or not rows or not isinstance(agg, str) or agg not in RANK:
                group.error = "UnexpectedResponse: the response had no usable scores or aggregate score"
                break
            group.aggregate = agg
            bad_rows = 0
            for row in rows:
                ok = (isinstance(row, dict) and isinstance(row.get("InstanceType"), str)
                      and isinstance(row.get("AvailabilityZoneId"), str) and isinstance(row.get("Score"), str)
                      and row["Score"] in RANK)
                if ok:
                    res.cells[(row["InstanceType"], row["AvailabilityZoneId"])] = row["Score"]
                else:
                    bad_rows += 1
            if bad_rows:
                group.error = f"UnexpectedResponse: {bad_rows} score rows were malformed and were left out"
            break
    return res


def best_score(scores):
    vals = [s for s in scores if s]
    return max(vals, key=lambda s: RANK.get(s, 0)) if vals else None


# ---------------------------------------------------------------------------------------
# Preflight: catch typos and unavailable types before any Capacity Manager request is spent
# ---------------------------------------------------------------------------------------

@dataclass
class Preflight:
    azs: list                       # AZ IDs to send (valid or unverifiable)
    types: list | None              # instance types to send (None in requirements mode)
    bad_azs: list = field(default_factory=list)          # AZ IDs EC2 does not know
    excluded_types: list = field(default_factory=list)   # offered in none of the verified AZs
    not_offered: set = field(default_factory=set)        # (type, az) pairs EC2 says are not offered
    notes: list = field(default_factory=list)            # things that could not be checked


def preflight(session, types, azs) -> Preflight:
    """Check AZ IDs and instance type offerings with free EC2 calls (not Capacity Manager queries).

    A failure of the check never blocks the run: the affected AZs are simply not verified.
    """
    pf = Preflight(azs=list(azs), types=None if types is None else list(types))
    by_region = {}
    for az in azs:
        if az.split("-")[0] in REGION_BY_PREFIX:
            by_region.setdefault(region_of(az), []).append(az)
        else:
            pf.notes.append(("Region of {az} is not known to this tool, so it was not checked before sending.".format(az=az),
                             "{az} の Region をこのツールが知らないので、送信前の確認はしていません。".format(az=az)))
    verified = set()
    offered = set()
    for region, region_azs in by_region.items():
        try:
            client = session.client("ec2", region_name=region)
            zones = client.describe_availability_zones(AllAvailabilityZones=True,
                                                       Filters=[{"Name": "zone-id", "Values": region_azs}])
            known = {z["ZoneId"] for z in zones.get("AvailabilityZones", []) if isinstance(z.get("ZoneId"), str)}
            pf.bad_azs += [a for a in region_azs if a not in known]
            good = [a for a in region_azs if a in known]
            if types is not None and good:
                for i, j in ((i, j) for i in range(0, len(types), MAX_TYPE_PER_CALL) for j in range(0, len(good), 50)):
                    token = None
                    while True:
                        kw = dict(LocationType="availability-zone-id",
                                  Filters=[{"Name": "location", "Values": good[j:j + 50]},
                                           {"Name": "instance-type", "Values": types[i:i + MAX_TYPE_PER_CALL]}])
                        if token:
                            kw["NextToken"] = token
                        page = client.describe_instance_type_offerings(**kw)
                        offered.update((o["InstanceType"], o["Location"]) for o in page.get("InstanceTypeOfferings", []))
                        token = page.get("NextToken")
                        if not token:
                            break
            verified.update(good)
        except (ClientError, BotoCoreError, KeyError, TypeError) as e:
            detail = err_text(e) if isinstance(e, (ClientError, BotoCoreError)) else type(e).__name__
            pf.notes.append((f"Could not check the AZs of {region} before sending ({detail}); they are sent as given. The check needs ec2:DescribeAvailabilityZones and ec2:DescribeInstanceTypeOfferings.",
                             f"{region} の AZ を送信前に確認できませんでした ({detail})。指定どおりに送信します。この確認には ec2:DescribeAvailabilityZones と ec2:DescribeInstanceTypeOfferings が必要です。"))
    pf.azs = [a for a in azs if a not in pf.bad_azs]
    if types is not None:
        pf.not_offered = {(t, a) for t in types for a in verified if (t, a) not in offered}
        unverified = [a for a in pf.azs if a not in verified]
        pf.excluded_types = [t for t in types
                             if pf.azs and not unverified and all((t, a) in pf.not_offered for a in pf.azs)]
        pf.types = [t for t in types if t not in pf.excluded_types]
    return pf


# ---------------------------------------------------------------------------------------
# Capacity Manager state
# ---------------------------------------------------------------------------------------

def read_status(ec2):
    """Return ("enabled" | "disabled" | "unknown", attrs, error_text)."""
    try:
        attrs = ec2.get_capacity_manager_attributes()
    except (ClientError, BotoCoreError) as e:
        code = e.response.get("Error", {}).get("Code") if isinstance(e, ClientError) else None
        if code == "CapacityManager.Disabled":
            return "disabled", {}, None
        if code == "CapacityManager.IncorrectRegion":
            # Observed 2026-11-05 (not in the documentation): the message names the Region that has it.
            return "elsewhere", {}, err_text(e)
        return "unknown", {}, err_text(e)
    status = attrs.get("CapacityManagerStatus") if isinstance(attrs, dict) else None
    if status in ("enabled", "disabled"):
        return status, attrs, None
    return "unknown", {}, f"UnexpectedResponse: CapacityManagerStatus was {status!r}"


def ensure_manager(ec2, allow_enable: bool):
    """Return (state, log). Enables Capacity Manager only when allow_enable is true.

    A Region counts as enabled only when the status is read back as "enabled".
    """
    log = []
    status, attrs, error = read_status(ec2)
    if status == "enabled":
        log.append(("Capacity Manager is already enabled in this Region.",
                    "この Region では Capacity Manager はすでに有効です。"))
        return {"enabled": True, "status": "enabled", "attrs": attrs, "error": None}, log
    if status in ("unknown", "elsewhere"):
        # "elsewhere": Capacity Manager is enabled in another Region, so --enable here would only fail.
        return {"enabled": False, "status": status, "attrs": {}, "error": error}, log
    log.append(("Capacity Manager is not enabled in this Region.",
                "この Region では Capacity Manager は有効ではありません。"))
    if not allow_enable:
        return {"enabled": False, "status": "disabled", "attrs": {}, "error": None, "needs_enable": True}, log
    try:
        ec2.enable_capacity_manager()
    except (ClientError, BotoCoreError) as e:
        return {"enabled": False, "status": "disabled", "attrs": {}, "error": err_text(e)}, log
    print("Ran enable-capacity-manager; the change stays in place.", flush=True)
    log.append(("Ran enable-capacity-manager. This starts data ingestion and can be done in one Region per account; the change stays in place.",
                "enable-capacity-manager を実行しました。データの取り込みが始まります。有効にできるのは 1 アカウントにつき 1 Region だけで、この変更は残ります。"))
    time.sleep(4)
    status, attrs, error = read_status(ec2)
    if status != "enabled":
        return {"enabled": False, "status": status, "attrs": {}, "error": error or "enable-capacity-manager was sent but the status could not be confirmed as enabled; the change may still be taking effect, so check get-capacity-manager-attributes and run again"}, log
    return {"enabled": True, "status": "enabled", "attrs": attrs, "error": None}, log


# ---------------------------------------------------------------------------------------
# The data file: everything the report shows lives in one JSON document
# ---------------------------------------------------------------------------------------

SCHEMA = "ec2-capacity-supportability-report/1"


def to_data(ctx: dict) -> dict:
    """Turn what a run collected into a plain, JSON-serialisable document.

    The HTML is rendered from this document only (see from_data), so the page can be rebuilt later without
    calling the API, and other tools can read the same facts.
    """
    pf = ctx["pf"]
    results = {}
    for market, by_amount in ctx["results"].items():
        results[market] = {}
        for amount, res in by_amount.items():
            results[market][str(amount)] = {
                "cells": [[t, az, score] for (t, az), score in sorted(res.cells.items())],
                "groups": [{"types": g.types, "azs": g.azs, "aggregate": g.aggregate, "error": g.error,
                            "dropped": [list(d) for d in g.dropped], "all_types": g.all_types, "all_azs": g.all_azs}
                           for g in res.groups],
                "retries": res.retries, "sent": res.sent,
            }
    attrs = ctx["state"].get("attrs") or {}
    return {
        "schema": SCHEMA,
        "generated_by": "supportability_report.py",
        "generated_at_jst": ctx["now"],
        "status": ctx["status"],
        "reasons": ctx.get("reasons", []),
        "identity": {"Account": ctx["identity"]["Account"], "Arn": ctx["identity"]["Arn"]},
        "request": {"region": ctx["region"], "markets": ctx["markets"], "amounts": ctx["amounts"], "unit": ctx["unit"],
                    "types": ctx["types"], "azs": ctx["azs"], "calls": ctx["calls"]},
        "state": {"enabled": ctx["state"]["enabled"], "status": ctx["state"].get("status", "unknown"),
                  "error": ctx["state"].get("error"), "needs_enable": bool(ctx["state"].get("needs_enable")),
                  "attrs": {k: attrs[k] for k in ("CapacityManagerStatus", "IngestionStatus")
                            if isinstance(attrs.get(k), str)}},
        "log": [list(x) for x in ctx["log"]],
        "preflight": {"azs": pf.azs, "types": pf.types, "bad_azs": pf.bad_azs, "excluded_types": pf.excluded_types,
                      "not_offered": sorted([t, az] for t, az in pf.not_offered),
                      "notes": [list(n) for n in pf.notes]},
        "results": results,
    }


def _need(cond, why):
    if not cond:
        raise ValueError(why)


def _str_list(v, name, allow_none=False):
    if v is None and allow_none:
        return None
    _need(isinstance(v, list) and all(isinstance(x, str) for x in v), f"{name} must be a list of strings")
    return list(v)


def _pairs(v, name, n):
    _need(isinstance(v, list) and all(isinstance(x, list) and len(x) == n and all(isinstance(y, str) for y in x) for x in v),
          f"{name} must be a list of {n}-string lists")
    return v


def from_data(data, lang="en", lang_explicit=False) -> dict:
    """Validate a document made by to_data and rebuild the objects the renderer reads. Raises ValueError only."""
    try:
        return _from_data(data, lang, lang_explicit)
    except (TypeError, KeyError, AttributeError, IndexError) as e:
        raise ValueError(f"the document has a value of the wrong type or a missing field ({type(e).__name__}: {e})") from e


def _from_data(data, lang, lang_explicit) -> dict:
    _need(isinstance(data, dict), "the document must be a JSON object")
    _need(data.get("schema") == SCHEMA, f"unsupported schema {data.get('schema')!r} (expected {SCHEMA})")
    ident = data.get("identity")
    _need(isinstance(ident, dict) and isinstance(ident.get("Account"), str) and isinstance(ident.get("Arn"), str), "identity is missing")
    req = data.get("request")
    _need(isinstance(req, dict), "request is missing")
    markets = _str_list(req.get("markets"), "request.markets")
    _need(all(m in ("on-demand", "spot") for m in markets), "request.markets has an unknown market")
    amounts = req.get("amounts")
    _need(isinstance(amounts, list) and all(isinstance(a, int) and not isinstance(a, bool) and a >= 1 for a in amounts), "request.amounts must be positive integers")
    _need(isinstance(req.get("region"), str) and req.get("unit") in ("instances", "vcpus"), "request.region or request.unit is invalid")
    _need(isinstance(req.get("calls"), int), "request.calls must be an integer")
    types = _str_list(req.get("types"), "request.types", allow_none=True)
    azs = _str_list(req.get("azs"), "request.azs")
    st = data.get("state")
    _need(isinstance(st, dict) and isinstance(st.get("enabled"), bool) and isinstance(st.get("status"), str), "state is invalid")
    _need(st.get("error") is None or isinstance(st.get("error"), str), "state.error must be a string or null")
    _need(isinstance(data.get("status"), int) and isinstance(data.get("generated_at_jst"), str), "status or generated_at_jst is invalid")
    pfd = data.get("preflight")
    _need(isinstance(pfd, dict), "preflight is missing")
    pf = Preflight(azs=_str_list(pfd.get("azs"), "preflight.azs"), types=_str_list(pfd.get("types"), "preflight.types", True),
                   bad_azs=_str_list(pfd.get("bad_azs"), "preflight.bad_azs"),
                   excluded_types=_str_list(pfd.get("excluded_types"), "preflight.excluded_types"),
                   not_offered={tuple(x) for x in _pairs(pfd.get("not_offered"), "preflight.not_offered", 2)},
                   notes=[tuple(x) for x in _pairs(pfd.get("notes"), "preflight.notes", 2)])
    log = [tuple(x) for x in _pairs(data.get("log"), "log", 2)]
    raw = data.get("results")
    _need(isinstance(raw, dict) and set(raw) == set(markets), "results must have exactly the requested markets")
    results = {}
    for market in markets:
        by_amount = raw[market]
        _need(isinstance(by_amount, dict) and set(by_amount) == {str(a) for a in amounts}, f"results.{market} must have exactly the requested amounts")
        results[market] = {}
        for amount in amounts:
            r = by_amount[str(amount)]
            _need(isinstance(r, dict), "a result entry must be an object")
            cells = {}
            for row in r.get("cells", []):
                _need(isinstance(row, list) and len(row) == 3 and all(isinstance(x, str) for x in row) and row[2] in RANK, "a cell row is invalid")
                cells[(row[0], row[1])] = row[2]
            groups = []
            for g in r.get("groups", []):
                _need(isinstance(g, dict), "a group must be an object")
                _need(g.get("aggregate") is None or g.get("aggregate") in RANK, "a group aggregate is invalid")
                _need(g.get("error") is None or isinstance(g.get("error"), str), "a group error must be a string or null")
                dropped = []
                for d in g.get("dropped", []):
                    _need(isinstance(d, list) and len(d) == 3 and all(isinstance(x, str) for x in d), "a dropped entry is invalid")
                    dropped.append(tuple(d))
                groups.append(Group(types=_str_list(g.get("types"), "group.types", True), azs=_str_list(g.get("azs"), "group.azs"),
                                    aggregate=g.get("aggregate"), error=g.get("error"), dropped=dropped,
                                    all_types=_str_list(g.get("all_types"), "group.all_types", True),
                                    all_azs=_str_list(g.get("all_azs"), "group.all_azs")))
            _need(isinstance(r.get("retries", 0), int) and isinstance(r.get("sent", 0), int), "retries and sent must be integers")
            results[market][amount] = Result(cells=cells, groups=groups, retries=r.get("retries", 0), sent=r.get("sent", 0))
    attrs = st.get("attrs") or {}
    _need(isinstance(attrs, dict) and all(isinstance(v, str) for v in attrs.values()), "state.attrs is invalid")
    state = {"enabled": st["enabled"], "status": st["status"], "error": st.get("error"),
             "needs_enable": bool(st.get("needs_enable")), "attrs": attrs}
    return {"identity": {"Account": ident["Account"], "Arn": ident["Arn"]}, "region": req["region"], "state": state, "log": log,
            "status": data["status"], "now": data["generated_at_jst"], "types": types, "azs": azs, "pf": pf,
            "markets": markets, "amounts": amounts, "unit": req["unit"], "results": results, "calls": req["calls"],
            "reasons": data.get("reasons", []), "lang": lang, "lang_explicit": lang_explicit}


def load_data(path: Path) -> dict:
    """Read a data file. Raises ValueError with a readable reason; the content is validated by from_data."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as e:
        raise ValueError(f"cannot read {path}: {e}") from e
    try:
        return json.loads(text)
    except json.JSONDecodeError as e:
        raise ValueError(f"{path} is not valid JSON: {e}") from e


# ---------------------------------------------------------------------------------------
# HTML rendering (English / Japanese in one file)
# ---------------------------------------------------------------------------------------

def bi(en: str, ja: str) -> str:
    """Paired text. CSS shows exactly one of the two according to <html lang>."""
    return f'<span class="en">{html.escape(en)}</span><span class="ja">{html.escape(ja)}</span>'


def bi_raw(en_html: str, ja_html: str) -> str:
    """Like bi() for fragments that already contain trusted markup."""
    return f'<span class="en">{en_html}</span><span class="ja">{ja_html}</span>'


PARTIAL_MARK = '<sup class="partial" title="Some requests for this row failed, so this best score may be incomplete / このタイプの一部のリクエストが失敗したので、この最良スコアは不完全かもしれません">†</sup>'


def pill(score, failed=False, not_offered=False) -> str:
    if score is None and not_offered:
        return '<span class="pill no">Not offered</span>'
    if score is None and failed:
        return '<span class="pill err">Error</span>'
    if score is None:
        return '<span class="pill na">N/A</span>'
    label = {"high": "High", "medium": "Medium", "low": "Low"}.get(score, html.escape(str(score)))
    cls = score if score in RANK else "na"
    return f'<span class="pill {cls}">{label}</span>'


def region_groups(azs):
    groups = []
    for az in azs:
        r = region_of(az)
        if groups and groups[-1][0] == r:
            groups[-1][1].append(az)
        else:
            groups.append((r, [az]))
    return groups


def heatmap(cells, types, azs, failed=frozenset(), not_offered=frozenset(), partial=False) -> str:
    out = ['<div class="tablewrap"><table><thead><tr><th rowspan="2" class="sticky">',
           bi("Instance type", "インスタンスタイプ"), "</th>"]
    for r, g in region_groups(azs):
        out.append(f'<th colspan="{len(g)}" class="grp">{html.escape(r)}</th>')
    out.append('<th rowspan="2" class="grp">' + bi("Best", "最良") + "</th></tr><tr>")
    for _, g in region_groups(azs):
        for az in g:
            out.append(f'<th class="az">{html.escape(az)}</th>')
    out.append("</tr></thead><tbody>")
    for t in types:
        row = [cells.get((t, az)) for az in azs]
        out.append(f'<tr><th class="sticky mono">{html.escape(t)}</th>')
        out.extend(f"<td>{pill(x, (t, az) in failed, (t, az) in not_offered)}</td>" for x, az in zip(row, azs))
        best = best_score(row)
        any_failed = any((t, az) in failed for az in azs) or partial
        all_no = all((t, az) in not_offered for az in azs)
        mark = PARTIAL_MARK if any_failed and best is not None else ""
        out.append(f'<td class="bestcol">{pill(best, best is None and any_failed, best is None and all_no)}{mark}</td></tr>')
    out.append("</tbody></table></div>")
    return "".join(out)


def sensitivity(results, types, azs, amounts, not_offered=frozenset()) -> str:
    out = ['<div class="tablewrap"><table><thead><tr><th class="sticky">',
           bi("Instance type", "インスタンスタイプ"), "</th>"]
    out.extend(f'<th class="az">{a:,}</th>' for a in amounts)
    out.append("</tr></thead><tbody>")
    for t in types:
        out.append(f'<tr><th class="sticky mono">{html.escape(t)}</th>')
        for a in amounts:
            cells, failed = results[a].cells, failed_pairs(results[a])
            best = best_score(cells.get((t, az)) for az in azs)
            any_failed = any((t, az) in failed for az in azs) or results[a].partial
            all_no = all((t, az) in not_offered for az in azs)
            mark = PARTIAL_MARK if any_failed and best is not None else ""
            out.append(f"<td>{pill(best, best is None and any_failed, best is None and all_no)}{mark}</td>")
        out.append("</tr>")
    out.append("</tbody></table></div>")
    return "".join(out)


def agg_pill(g) -> str:
    if g.aggregate:
        return pill(g.aggregate)
    return bi("request failed, see API errors", "リクエスト失敗 (API エラーを参照)") if g.error else bi("not in the response", "応答に含まれていません")


def failed_pairs(res) -> frozenset:
    """(instance_type, az) pairs that were in a request that failed or lost a value (explicit type lists only)."""
    out = set()
    for g in res.groups:
        if g.all_types is None or not (g.error or g.dropped):
            continue
        for t in g.all_types:
            for az in g.all_azs:
                if g.error or t not in (g.types or []) or az not in g.azs:
                    out.add((t, az))
    return frozenset(out)


def aggregate_block(groups) -> str:
    """The aggregate score belongs to ONE request. When a run was split, say which slice."""
    if not groups:
        return ""
    if len(groups) == 1:
        g = groups[0]
        return ('<div class="agg"><b>' + bi("Aggregate score", "集約スコア") + "</b> " + agg_pill(g) + "</div>")
    out = ['<div class="agg"><b>' + bi("Aggregate score per request", "リクエストごとの集約スコア")
           + "</b><ul>"]
    for i, g in enumerate(groups, 1):
        types = "(attribute-based)" if g.types is None else ", ".join(g.types[:3]) + (f" +{len(g.types) - 3}" if len(g.types) > 3 else "")
        out.append(f"<li>{i}/{len(groups)}: <span class='mono'>{html.escape(types)}</span> x "
                   f"<span class='mono'>{html.escape(', '.join(g.azs))}</span> "
                   + agg_pill(g) + "</li>")
    out.append("</ul>"
               + bi("The run was split to stay within the per-request limits: 100 combinations (Quotas page) and 10 AZs and 50 instance types (AWS CLI reference). The documentation does not say how to combine aggregates, so each one is shown for its own request.",
                    "1 リクエストの上限に収めるため分割しました。上限は、組み合わせ 100 組 (Quotas のページ)、AZ 10 個とインスタンスタイプ 50 個 (AWS CLI リファレンス) です。ドキュメントは分けた集約の扱いを書いていないので、集約はリクエストごとに表示しています。")
               + "</div>")
    return "".join(out)


CSS = """
:root{
  --ink:#0f141a;           /* color-text-body-default */
  --ink2:#424650;          /* color-text-heading-secondary */
  --ink3:#656871;          /* color-text-body-secondary */
  --bg:#f6f6f9;            /* color-background-cell-shaded */
  --card:#ffffff;          /* color-background-container-content */
  --line:#c6c6cd;          /* color-border-divider-default */
  --line2:#ebebf0;         /* color-border-divider-secondary */
  --link:#006ce0;          /* color-text-link-default */
  --nav:#0f141a;           /* same value as --ink */
  --ok-bg:#effff1;--ok:#00802f;       /* status: success */
  --warn-bg:#fffce9;--warn:#855900;   /* status: warning */
  --err-bg:#fff5f5;--err:#db0000;     /* status: error */
  --info-bg:#f0fbff;--info:#006ce0;   /* status: info */
  --r-pill:20px;           /* border-radius-button */
  --r-card:16px;           /* border-radius-container */
  --font:'Open Sans','Helvetica Neue',Roboto,Arial,'Hiragino Kaku Gothic ProN','Noto Sans JP',sans-serif;
  --mono:Monaco,Menlo,Consolas,'Courier Prime',Courier,'Courier New',monospace;
}
*{box-sizing:border-box}
html[lang="en"] .ja{display:none}
html[lang="ja"] .en{display:none}
body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.6 var(--font)}
.topnav{background:var(--nav);color:#fff;padding:10px 24px;font-weight:700;display:flex;gap:16px;align-items:center}
.topnav small{font-weight:400;color:var(--line)}
.topnav .sp{flex:1}
.lang button{font:inherit;color:#fff;background:transparent;border:1px solid var(--line);padding:2px 14px;cursor:pointer}
.lang button:first-child{border-radius:var(--r-pill) 0 0 var(--r-pill)}
.lang button:last-child{border-radius:0 var(--r-pill) var(--r-pill) 0;border-left:0}
.lang button[aria-pressed="true"]{background:#fff;color:var(--ink)}
.wrap{max-width:1280px;margin:0 auto;padding:16px 24px 48px}
.crumbs{color:var(--ink3);font-size:12px;margin:8px 0}
h1{font-size:28px;line-height:1.3;margin:4px 0;font-weight:700}
h2{font-size:18px;margin:0 0 12px;font-weight:700}
h3{font-size:14px;margin:18px 0 8px;font-weight:700;color:var(--ink2)}
.lead{color:var(--ink2);margin:0 0 16px}
.card{background:var(--card);border-radius:var(--r-card);padding:20px 24px;margin:16px 0;
  box-shadow:0 1px 1px 0 rgba(0,28,36,.3),1px 1px 1px 0 rgba(0,28,36,.15),-1px 1px 1px 0 rgba(0,28,36,.15)}
.kv{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:16px}
.kv .k{color:var(--ink3);font-size:12px;font-weight:700}
.kv .v{font-size:16px;word-break:break-all}
.mono{font-family:var(--mono);font-size:13px}
.alert{border-radius:8px;padding:12px 16px;margin:12px 0;border:1px solid}
.alert.info{background:var(--info-bg);border-color:var(--info)}
.alert.err{background:var(--err-bg);border-color:var(--err)}
.alert.warn{background:var(--warn-bg);border-color:var(--warn)}
.pill{display:inline-block;min-width:64px;text-align:center;padding:1px 10px;border-radius:var(--r-pill);font-weight:700;font-size:12px}
.pill.high{background:var(--ok-bg);color:var(--ok);box-shadow:inset 0 0 0 1px var(--ok)}
.pill.medium{background:var(--warn-bg);color:var(--warn);box-shadow:inset 0 0 0 1px var(--warn)}
.pill.low{background:var(--err-bg);color:var(--err);box-shadow:inset 0 0 0 1px var(--err)}
.pill.err{background:var(--err-bg);color:var(--err);box-shadow:inset 0 0 0 1px var(--err);border-style:dashed}
.pill.no{background:var(--bg);color:var(--ink3);box-shadow:inset 0 0 0 1px var(--line);border-style:dotted;font-weight:400}
.partial{color:var(--err);cursor:help;font-weight:700}
.pill.na{background:var(--bg);color:var(--ink3);box-shadow:inset 0 0 0 1px var(--line);font-weight:400}
.tablewrap{overflow-x:auto;border:1px solid var(--line2);border-radius:8px}
table{border-collapse:collapse;width:100%;background:#fff}
th,td{padding:8px 12px;border-bottom:1px solid var(--line2);text-align:center;white-space:nowrap}
thead th{background:var(--bg);font-size:12px;color:var(--ink2)}
th.sticky{text-align:left;position:sticky;left:0;background:#fff;z-index:1}
thead th.sticky{background:var(--bg)}
th.grp{border-left:1px solid var(--line2)}
th.az{font-family:var(--mono);font-weight:400}
td.bestcol{border-left:2px solid var(--line)}
tr:last-child td,tr:last-child th{border-bottom:none}
.agg{margin:8px 0 12px;color:var(--ink2)}
.agg ul{margin:6px 0;padding-left:20px}
.legend{display:grid;gap:8px}
.legend div{display:flex;gap:12px;align-items:baseline}
.legend .pill{flex:none}
.sec{border-top:1px solid var(--line2);margin-top:20px;padding-top:4px}
ul.plain{margin:6px 0;padding-left:20px}
footer{color:var(--ink3);font-size:12px;margin-top:24px}
"""

JS = """
(function(){
  var KEY='supportability-report-lang', root=document.documentElement;
  function show(l){
    root.setAttribute('lang',l);
    document.title=root.getAttribute('data-title-'+l);
    document.querySelectorAll('.lang button').forEach(function(b){
      b.setAttribute('aria-pressed', b.getAttribute('data-lang')===l ? 'true':'false');
    });
  }
  var saved=null; try{saved=localStorage.getItem(KEY)}catch(e){}
  var explicit=root.getAttribute('data-lang-explicit')==='1';
  show(!explicit && (saved==='en'||saved==='ja') ? saved : root.getAttribute('lang'));
  document.querySelectorAll('.lang button').forEach(function(b){
    b.addEventListener('click',function(){
      var l=b.getAttribute('data-lang'); show(l);
      try{localStorage.setItem(KEY,l)}catch(e){}
    });
  });
})();
"""

TITLE_EN = "EC2 Capacity Manager - real-time supportability check"
TITLE_JA = "EC2 Capacity Manager - リアルタイム supportability チェック"


def render(ctx: dict) -> str:
    h = [f'<!doctype html><html lang="{ctx["lang"]}" data-lang-explicit="{1 if ctx["lang_explicit"] else 0}" data-title-en="{html.escape(TITLE_EN)}" '
         f'data-title-ja="{html.escape(TITLE_JA)}"><head><meta charset="utf-8">',
         '<meta name="viewport" content="width=device-width,initial-scale=1">',
         f"<title>{html.escape(TITLE_EN if ctx['lang'] == 'en' else TITLE_JA)}</title>",
         f"<style>{CSS}</style></head><body>",
         '<div class="topnav">EC2 Capacity Manager <small>' + bi("Check supportability report", "Check supportability レポート")
         + '</small><span class="sp"></span><span class="lang" role="group" aria-label="Language">'
         '<button type="button" data-lang="en" aria-pressed="false">English</button>'
         '<button type="button" data-lang="ja" aria-pressed="false">日本語</button></span></div>',
         '<div class="wrap">',
         '<div class="crumbs">EC2 &gt; Capacity Manager &gt; Check supportability</div>',
         "<h1>" + bi("Real-time supportability check", "リアルタイム supportability チェック") + "</h1>",
         '<p class="lead">' + bi(
             "Each score compares the capacity an instance type and Availability Zone combination holds right now with the amount you asked for. "
             "It reflects capacity at a point in time. It doesn't reserve capacity or guarantee that a later launch will succeed.",
             "各スコアは、インスタンスタイプと Availability Zone の組み合わせがいま保有しているキャパシティを、要求した量と比べたものです。"
             "ある時点のキャパシティを反映したもので、キャパシティを予約せず、後の起動が成功することも保証しません。") + "</p>"]

    pf = ctx.get("pf") or Preflight(azs=ctx["azs"], types=ctx["types"])
    if ctx.get("status"):
        h.append("<div class='alert err'><b>" + bi(
            f"This run did not obtain every score you asked for (exit status {ctx['status']}).",
            f"この実行では、要求したスコアをすべては取得できませんでした (終了コード {ctx['status']})。") + "</b> " + bi(
            "Read the Error, Not offered and N/A marks, the checks before sending and the API errors below before using any number on this page.",
            "このページの数値を使う前に、下の Error、Not offered、N/A の表示、送信前の確認、API エラーを読んでください。") + "</div>")

    # How to read (restates the documentation, nothing more)
    h.append('<div class="card"><h2>' + bi("How to read the scores", "スコアの読み方") + "</h2>"
             '<div class="legend">'
             f"<div>{pill('high')}<span>" + bi("The combination holds several times your request. Proceed.",
                                              "要求量の数倍を保有しています。先へ進めてよい水準です。") + "</span></div>"
             f"<div>{pill('medium')}<span>" + bi(
                 "The combination can cover your request with little to spare. Workable rather than safe; a launch can still fail.",
                 "要求量をぎりぎり満たせる程度です。安全というより実行可能な水準で、起動は失敗する場合があります。") + "</span></div>"
             f"<div>{pill('low')}<span>" + bi(
                 "The combination holds less than you asked for, though some capacity is likely still available.",
                 "要求量より少ない保有量ですが、一部のキャパシティはまだ残っていると見込まれます。") + "</span></div>"
             f"<div>{pill(None)}<span>" + bi(
                 "This instance type x AZ pair is not in the response. The documentation does not say why a requested pair can be absent.",
                 "このインスタンスタイプと AZ の組み合わせは応答に含まれていません。要求した組み合わせが応答に無い理由は、ドキュメントに書かれていません。") + "</span></div>"
             f"<div>{pill(None, False, True)}<span>" + bi(
                 "EC2 reports that this instance type is not offered in this AZ (checked with DescribeInstanceTypeOfferings before sending, not with Capacity Manager).",
                 "EC2 によると、このインスタンスタイプはこの AZ では提供されていません (送信前に Capacity Manager ではなく DescribeInstanceTypeOfferings で確認しました)。") + "</span></div>"
             f"<div>{pill(None, True)}<span>" + bi(
                 "The request that contained this pair failed, or returned no usable score for it. The error is listed under API errors below.",
                 "この組み合わせを含むリクエストが失敗したか、この組み合わせの使えるスコアを返しませんでした。エラーは下の API エラーに載せています。") + "</span></div>"
             "<div><span class=\"partial\">†</span><span>" + bi(
                 "Some requests for this row failed, so the best score shown may be incomplete.",
                 "この行の一部のリクエストが失敗したので、表示している最良スコアは不完全かもしれません。") + "</span></div>"
             "</div>"
             '<ul class="plain">'
             "<li>" + bi("Scores are relative to the amount you ask for: the same combination can score High for 50 instances and Low for 5,000 at the same moment.",
                         "スコアは要求量に対する相対値です。同じ組み合わせでも、同時点で 50 台なら High、5,000 台なら Low になりえます。") + "</li>"
             "<li>" + bi("No score, including High, guarantees that a launch will succeed. Insufficient capacity errors remain possible. For critical workloads use Capacity Reservations or Future-dated Capacity Reservations regardless of score.",
                         "High を含め、どのスコアも起動の成功を保証しません。容量不足エラーは起こりえます。重要なワークロードには、スコアに関係なく Capacity Reservation か将来日付の Capacity Reservation を使います。") + "</li>"
             "<li>" + bi("The aggregate score rates the whole set of options in one request. Low scores per combination with a High aggregate is intended: no single combination can carry the request, but the options together can.",
                         "集約スコアは、1 つのリクエストに含めた選択肢の集合全体への評価です。組み合わせごとが Low でも全体が High になるのは意図した動作で、単独では支えきれなくても全体では支えられるという意味です。") + "</li>"
             "<li>" + bi("The Spot scores are built on Spot placement score (SPS). SPS rates your flexibility as a whole rather than individual combinations, and the Spot aggregate score gives equivalent guidance. If you already use SPS directly, read the aggregate as your Spot signal. The documentation does not say how to read the per-combination Spot values.",
                         "Spot のスコアは Spot placement score (SPS) を土台にしています。SPS は個々の組み合わせではなく、選択肢全体の柔軟性を評価し、Spot の集約スコアが同等の指針になります。すでに SPS を直接使っている場合は、集約スコアを Spot の信号として読みます。組み合わせごとの Spot の値の読み方は、ドキュメントに書かれていません。") + "</li>"
             "<li>" + bi("Run checks when you plan or review a workload rather than on every launch.",
                         "チェックは、起動のたびではなく、ワークロードを計画するときや見直すときに実行します。") + "</li>"
             "<li>" + bi("After an InsufficientCapacityError, check the score again for the same instance type, AZ and amount. High: the combination has capacity but needs to resize hosts to produce instances at your requested size, so launch what you can and retry the rest every few minutes. Medium or Low: the combination has limited available capacity for your request, so launch in another combination that scored High or add more instance types.",
                         "InsufficientCapacityError が出た後は、同じインスタンスタイプ、AZ、要求量でもう一度スコアを確認します。High なら、その組み合わせにキャパシティはあるものの、要求したサイズのインスタンスを作るためにホストのリサイズが必要な状態です。起動できる分を起動し、残りは数分おきに再試行します。Medium か Low なら、要求に対して空きが限られているので、High だった別の組み合わせで起動するか、インスタンスタイプを増やします。") + "</li>"
             "</ul></div>")

    # Scope of this run
    st = ctx["state"]
    attrs = st["attrs"]
    h.append('<div class="card"><h2>' + bi("Scope of this run", "この実行の範囲") + '</h2><div class="kv">')
    kv = [(("Account", "アカウント"), ctx["identity"]["Account"]),
          (("Caller", "呼び出し元"), ctx["identity"]["Arn"]),
          (("Region the API was called in", "API を呼んだ Region"), ctx["region"]),
          (("Capacity Manager status", "Capacity Manager の状態"),
           st.get("status", "unknown")),
          (("Run time (JST)", "実行時刻 (JST)"), ctx["now"]),
          ((f"API requests sent in this run, SDK automatic retries not counted (quota: {QUOTA_PER_HOUR} per account per hour, shared with other runs)", f"この実行で送った API リクエスト数、SDK の自動再試行は含まない (上限: アカウントあたり 1 時間 {QUOTA_PER_HOUR} 回、他の実行と共有)"),
           str(ctx["calls"]))]
    for (ken, kja), v in kv:
        h.append(f"<div><div class='k'>{bi(ken, kja)}</div><div class='v'>{html.escape(str(v))}</div></div>")
    h.append("</div><ul class='plain'>"
             "<li>" + bi("The API is called in the Region where Capacity Manager is enabled; one call can cover Availability Zones in any Region.",
                         "API は Capacity Manager を有効にした Region で呼びます。1 回の呼び出しで、どの Region の Availability Zone も対象にできます。") + "</li>"
             "<li>" + bi("Availability Zones are given as AZ IDs (for example apne1-az4). AWS maps AZ names such as ap-northeast-1c to physical zones separately for each account, while an AZ ID identifies the same physical location in every account (AWS RAM documentation, Availability Zone IDs for your AWS resources).",
                         "Availability Zone は AZ ID (例 apne1-az4) で指定します。AWS は ap-northeast-1c のような AZ 名をアカウントごとに別々に物理ゾーンへ対応付けますが、AZ ID はどのアカウントでも同じ物理的な場所を指します (AWS RAM ドキュメントの Availability Zone IDs for your AWS resources)。") + "</li>"
             "<li>" + bi("Available only to AWS Support customers on the Unified Operations plan. Quotas: 100 queries per account per hour and 100 instance type x AZ combinations per request. The documentation does not say whether other accounts would see the same score, so treat the results as this account's.",
                         "AWS Support の Unified Operations プランのお客様だけが使えます。上限は、アカウントあたり 1 時間 100 クエリ、1 リクエストあたり 100 組のインスタンスタイプと AZ の組み合わせです。他のアカウントでも同じスコアになるかはドキュメントに書かれていないので、結果はこのアカウントのものとして扱います。") + "</li></ul>")
    for en, ja in ctx["log"]:
        h.append(f"<div class='alert info'>{bi(en, ja)}</div>")
    if st.get("needs_enable"):
        h.append("<div class='alert warn'>" + bi_raw(
            "Capacity Manager is not enabled, so no scores were requested. Re-run with <code>--enable</code> to enable it in this Region (allowed in one Region per account).",
            "Capacity Manager が無効なので、スコアは取得していません。この Region で有効にするには <code>--enable</code> を付けて再実行します (1 アカウントにつき 1 Region だけ)。") + "</div>")
    if st.get("status") == "elsewhere":
        h.append("<div class='alert warn'>" + bi(
            "Capacity Manager is enabled in a different Region of this account (it can be enabled in one Region only). Run again with that Region as --region; the Region is named in the message below.",
            "このアカウントでは、別の Region で Capacity Manager が有効です (有効にできるのは 1 つの Region だけです)。その Region を --region にして、もう一度実行してください。Region 名は下のメッセージに出ています。") + "</div>")
    if st["error"]:
        h.append("<div class='alert err'><b>" + bi("Could not read or enable Capacity Manager:", "Capacity Manager の確認または有効化に失敗:")
                 + f"</b> <span class='mono'>{html.escape(st['error'])}</span></div>")
    h.append("</div>")

    dropped = sorted({(m, a, v, e) for m in ctx["markets"] for a in ctx["amounts"]
                      for g in ctx["results"][m][a].groups for v, _kind, e in g.dropped})
    if pf.bad_azs or pf.excluded_types or pf.notes or dropped or (ctx["state"].get("enabled") and not any(
            ctx["results"][m][a].groups for m in ctx["markets"] for a in ctx["amounts"])):
        h.append("<div class='card'><h2>" + bi("Checks before sending", "送信前の確認") + "</h2><ul class='plain'>")
        if pf.bad_azs:
            h.append("<li>" + bi("AZ IDs that EC2 does not know (not sent): ", "EC2 が知らない AZ ID (送信していません): ")
                     + f"<span class='mono'>{html.escape(', '.join(pf.bad_azs))}</span></li>")
        if pf.excluded_types:
            h.append("<li>" + bi("Instance types not offered in any requested AZ (not sent): ", "指定した AZ のどこにも提供されていないインスタンスタイプ (送信していません): ")
                     + f"<span class='mono'>{html.escape(', '.join(pf.excluded_types))}</span></li>")
        for m, a, v, e in dropped:
            h.append("<li>" + bi("The API rejected a value by name, so the request was repeated without it: ",
                                 "API が値を名指しで拒否したので、その値を除いてリクエストをやり直しました: ")
                     + f"<span class='mono'>{html.escape(v)}</span> ({html.escape(m)} / {a:,}) "
                     + f"<span class='mono'>{html.escape(e)}</span></li>")
        for en, ja in pf.notes:
            h.append(f"<li>{bi(en, ja)}</li>")
        if not any(ctx["results"][m][a].groups for m in ctx["markets"] for a in ctx["amounts"]) and ctx["state"].get("enabled"):
            h.append("<li>" + bi("Nothing was left to send, so no Capacity Manager request was made.",
                                 "送信するものが残らなかったので、Capacity Manager へのリクエストはしていません。") + "</li>")
        h.append("</ul></div>")

    errors = [(m, a, i, len(ctx["results"][m][a].groups), g.error)
              for m in ctx["markets"] for a in ctx["amounts"]
              for i, g in enumerate(ctx["results"][m][a].groups, 1) if g.error]
    if errors:
        h.append("<div class='card'><div class='alert err'><b>" + bi("API errors", "API エラー") + "</b><ul class='plain'>"
                 + "".join(f"<li><span class='mono'>{html.escape(m)} / {a:,} {html.escape(ctx['unit'])} / "
                           f"{bi('request', 'リクエスト')} {i}/{n}: {html.escape(e)}</span></li>"
                           for m, a, i, n, e in errors) + "</ul>"
                 + bi("One invalid value makes the whole request fail, so every pair in that request has no score. Fix the value named in the message and run again. ",
                      "1 つでも不正な値があるとリクエスト全体が失敗し、そのリクエストの組み合わせはすべてスコアなしになります。メッセージが示す値を直して、もう一度実行してください。")
                 + bi("These are the raw error texts from the API or the SDK, or messages this tool wrote when a response was not usable (UnexpectedResponse). The documentation does not say which error an account without the Unified Operations plan receives; the checks are available only to AWS Support customers on that plan.",
                      "上は API または SDK が返したエラーの原文か、応答が使えなかったときにこのツールが書いたメッセージ (UnexpectedResponse) です。Unified Operations プランでないアカウントでどのエラーが返るかは、ドキュメントに書かれていません。このチェックは、そのプランの AWS Support のお客様だけが使えます。")
                 + "</div></div>")

    for market in ctx["markets"]:
        res = ctx["results"][market]
        name_en, name_ja = ("On-Demand", "オンデマンド") if market == "on-demand" else ("Spot", "スポット")
        h.append(f"<div class='card'><h2>{bi(name_en, name_ja)} <span class='mono'>({html.escape(market)})</span></h2>")
        if market == "spot":
            split = any(len(res[a].groups) > 1 for a in ctx["amounts"])
            h.append("<div class='alert info'>" + bi(
                "Spot scores are built on Spot placement score (SPS), which rates your flexibility as a whole. If you already use SPS directly, read the aggregate as your Spot signal.",
                "Spot のスコアは Spot placement score (SPS) を土台にしており、SPS は柔軟性の全体を評価します。すでに SPS を直接使っている場合は、集約スコアを Spot の信号として読みます。")
                + bi(" The per-combination values below are shown as returned, and Best is the highest of them; the documentation does not say how to read per-combination Spot values.",
                     " 下の組み合わせごとの値は返ってきた値をそのまま示したもので、「最良」はその中の最高値です。組み合わせごとの Spot の値の読み方は、ドキュメントに書かれていません。")
                + (bi(" This run was split into several requests, so each aggregate covers only its own slice of your options; to get one aggregate, narrow the run to a single request.",
                      " この実行は複数のリクエストに分けたので、各集約スコアは選択肢の一部分だけを対象にしています。1 つの集約スコアを得たい場合は、1 回のリクエストに収まるよう絞り込みます。") if split else "")
                + "</div>")
        types = ctx["types"] or sorted({t for a in ctx["amounts"] for t in res[a].types})
        sent_any = any(res[a].groups for a in ctx["amounts"])
        if not sent_any:
            h.append("<div class='alert warn'>" + bi("No request was sent for this market, so there are no scores to show.",
                                                    "この市場にはリクエストを送っていないので、表示できるスコアはありません。") + "</div>")
            h.append("</div>")
            continue
        h.append("<h3>" + bi("Best score per type as the requested amount grows (best Availability Zone for each type)",
                             "要求量を増やしたときの、タイプごとの最良スコア (各タイプで最も良い Availability Zone)") + "</h3>")
        h.append(sensitivity(res, types, ctx["azs"], ctx["amounts"], pf.not_offered))
        for amt in ctx["amounts"]:
            r = res[amt]
            h.append("<div class='sec'><h3>" + bi(f"Request: {amt:,} {ctx['unit']}", f"要求量: {amt:,} {ctx['unit']}") + "</h3>")
            bad = sum(1 for g in r.groups if g.error or g.dropped)
            if bad:
                h.append("<div class='alert warn'>" + bi(
                    f"{bad} of {len(r.groups)} requests failed or lost a value (see API errors and Checks before sending). Pairs of those requests show as Error"
                    + ("; in attribute-based mode their instance types are unknown, so those rows are missing and every Best value is marked as possibly incomplete." if r.partial else "."),
                    f"{len(r.groups)} 件のリクエストのうち {bad} 件が失敗したか、値を除いて送りました (API エラーと送信前の確認を参照)。それらの組み合わせは Error と表示します"
                    + ("。属性指定ではインスタンスタイプが分からないので、該当する行は表に出ず、すべての最良スコアが不完全かもしれません。" if r.partial else "。")) + "</div>")
            h.append(aggregate_block(r.groups))
            h.append(heatmap(r.cells, types, ctx["azs"], failed_pairs(r), pf.not_offered, r.partial))
            h.append("</div>")
        h.append("</div>")

    h.append("<footer>" + bi(
        "These scores are EC2 Capacity Manager Data under the AWS Service Terms. You may use them solely for your internal capacity planning and workload management. "
        "You may not disclose them to any third party other than contractors or agents acting on your behalf, and you may not use them, or allow others to use them, "
        "directly or indirectly to develop, improve or offer a similar or competing product or service. "
        "AWS may suspend your use of EC2 Capacity Manager if it reasonably believes these terms are violated. "
        "The AWS documentation also states that the results can't be shared with third parties. "
        "This tool runs on your machine, calls the API in your account, and writes the file only to the output path (by default under ~/tmp/supportability/), or, when the run is not complete or the path cannot be used, next to it with a .failed- or .unplaced- name; whether that directory is synced or shared is up to you. "
        "This is a summary, not legal advice; read the current AWS Service Terms.",
        "このスコアは、AWS サービス条件でいう EC2 Capacity Manager Data です。自社の内部のキャパシティ計画とワークロード管理の目的に限って使えます。"
        "あなたのために行動する委託先または代理人を除く第三者には開示できず、同種または競合する製品やサービスの開発、改良、提供に、直接か間接かを問わず、使うことも他者に使わせることもできません。"
        "AWS が違反していると合理的に判断した場合、EC2 Capacity Manager の利用が停止されることがあります。"
        "AWS のドキュメントも、結果を第三者と共有できないと書いています。"
        "このツールは手元のマシンで動き、あなたのアカウントで API を呼び、ファイルは出力パス (既定では ~/tmp/supportability/ の下) にだけ書き出します。実行が完了しなかったとき、またはそのパスが使えないときは、同じディレクトリに .failed- または .unplaced- の付いた別名で書き出します。そのディレクトリが同期や共有の対象かどうかは、利用者の管理です。"
        "これは要約であり、法的な助言ではありません。最新の AWS サービス条件を確認してください。")
        + "<br>" + bi("Generated by", "生成:") + " supportability_report.py</footer></div>"
        f"<script>{JS}</script></body></html>")
    return "".join(h)


# ---------------------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------------------

def _natural(text):
    """Sort key that puts use1-az2 before use1-az10."""
    return [int(t) if t.isdigit() else t for t in re.split(r"(\d+)", text)]


def _clean(parser, option, values):
    out = [v.strip().lower() for v in values]
    if any(not v for v in out):
        parser.error(f"{option} must not contain empty values")
    return out


def parse_args(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--from-json", default=None, metavar="FILE",
                   help="do not call AWS: rebuild the HTML report from a data file written by an earlier run "
                        "(every run writes <report>.json next to the HTML). Use --lang and --out as usual")
    p.add_argument("--region", default=None,
                   help="Region where Capacity Manager is (or will be) enabled; the API is called here. "
                        "Required: it can be enabled in only one Region per account, so a wrong default would steer --enable there")
    p.add_argument("--profile", default=None, help="AWS profile name (default: ambient credentials)")
    p.add_argument("--types", nargs="+", default=None,
                   help="instance types to score (default: a GPU, Trainium and general-purpose sample)")
    p.add_argument("--requirements", default=None,
                   help="JSON for InstanceRequirementsWithMetadata (attribute-based selection); replaces --types. "
                        'The API requires "VirtualizationTypes", e.g. {"ArchitectureTypes":["x86_64"],'
                        '"VirtualizationTypes":["hvm"],"InstanceRequirements":{"VCpuCount":{"Min":4,"Max":4},'
                        '"MemoryMiB":{"Min":16384,"Max":16384}}}')
    p.add_argument("--azs", nargs="+", default=DEFAULT_AZS, help="AZ IDs, e.g. apne1-az4; Regions may be mixed")
    p.add_argument("--markets", nargs="+", default=["on-demand", "spot"], choices=["on-demand", "spot"])
    p.add_argument("--amounts", nargs="+", type=int, default=[1, 10, 100],
                   help="requested amounts; every score is relative to the amount")
    p.add_argument("--unit", default="instances", choices=["instances", "vcpus"])
    p.add_argument("--enable", action="store_true",
                   help="enable Capacity Manager in --region if it is disabled (one Region per account); requires --expect-account")
    p.add_argument("--expect-account", default=None, metavar="ACCOUNT_ID",
                   help="refuse to run unless the caller is in this 12-digit account; required with --enable so the account is "
                        "never changed by accident")
    p.add_argument("--max-calls", type=int, default=QUOTA_PER_HOUR - QUOTA_HEADROOM, metavar="N",
                   help="refuse to start when this run plans more than N API calls (default 95). The quota of 100 per hour is "
                        "shared by the whole account, so lower this when others use it too")
    p.add_argument("--lang", default=None, choices=["en", "ja"],
                   help="display language when the report opens, overriding the language the browser saved "
                        "(default: the saved choice, else English)")
    p.add_argument("--out", default=None,
                   help="output HTML path (default: ~/tmp/supportability/report-<YYYYmmdd-HHMMSS>.html)")
    p.add_argument("--overwrite", action="store_true",
                   help="replace the output file if it already exists (default: refuse)")
    p.add_argument("--open", action="store_true", help="open the report in the default browser when done")
    a = p.parse_args(argv)
    if a.from_json is None and not a.region:
        p.error("--region is required (unless --from-json is used)")
    if a.from_json is not None and (a.enable or a.requirements is not None):
        p.error("--from-json only rebuilds the HTML; --enable and --requirements do not apply")
    if any(x < 1 for x in a.amounts):
        p.error("--amounts must be positive integers")
    if not 1 <= a.max_calls <= QUOTA_PER_HOUR:
        p.error(f"--max-calls must be between 1 and {QUOTA_PER_HOUR}")
    if a.enable and not a.expect_account:
        p.error("--enable requires --expect-account ACCOUNT_ID")
    if a.expect_account is not None and not (a.expect_account.isdigit() and len(a.expect_account) == 12):
        p.error("--expect-account must be a 12-digit account ID")
    # Repeated values would run the same query twice and the later run would overwrite the earlier one.
    a.amounts = sorted(set(a.amounts))
    a.markets = list(dict.fromkeys(a.markets))
    if a.requirements is not None and a.types is not None:
        p.error("--types and --requirements cannot be used together")
    # Trim and lower-case so " M7I.large" and "m7i.large" are one value and an empty value is refused at the entry.
    a.types = list(dict.fromkeys(_clean(p, "--types", a.types if a.types is not None else DEFAULT_TYPES)))
    # Keep the AZs of one Region together so the table's Region headings are not split.
    a.azs = sorted(set(_clean(p, "--azs", a.azs)), key=lambda z: (region_of(z), _natural(z)))
    if a.out is not None and not a.out.strip():
        p.error("--out must not be empty")
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


def exit_status(state, results, pf=None) -> int:
    """0 only when Capacity Manager was usable, nothing asked for was left out and every request returned scores.

    The report is still written so a partial result can be read, but automation sees the failure.
    """
    if not state["enabled"]:
        return 3
    if pf is not None and (pf.bad_azs or pf.excluded_types):
        return 3
    groups = [g for by_amount in results.values() for r in by_amount.values() for g in r.groups]
    return 3 if not groups or any(g.error or g.dropped for g in groups) else 0


def planned_calls(args) -> int:
    per_run = len(plan_calls(None if args.requirements is not None else args.types, args.azs))
    return len(args.markets) * len(args.amounts) * per_run


def new_work_file(path: Path) -> tuple:
    """Create the file the report is written to, owner-only (0600), next to the final path.

    The final path is only ever filled by a run that ended with status 0 (see place_report), so a killed run
    leaves a hidden temporary file at worst and never blocks the next run. The temporary name does not depend
    on the target name, so a long target name cannot make this step fail. The last missing parent directory is
    created with mode 0700 (subject to umask); parents are not otherwise checked.
    """
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = path.parent / f".sr-{os.getpid()}-{os.urandom(4).hex()}.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    return os.fdopen(fd, "w", encoding="utf-8"), tmp


def _side_path(path: Path, label: str, stamp: str) -> Path:
    stem = path.stem[:100]  # keep the side name inside typical file name limits
    return path.with_name(f"{stem}.{label}-{stamp}{path.suffix}")


def place_report(tmp: Path, path: Path, status: int, overwrite: bool, stamp: str, force_side: str | None = None) -> tuple:
    """Move the finished report into place. Returns (final path, note or None, placed_ok).

    Exit status 0: the report goes to `path` (replacing an existing file only with --overwrite; a symbolic
    link there is replaced, not followed). Any other status: the report goes next to `path` as
    `<name>.failed-<time>`, so `path` only ever holds reports of successful runs. If a successful report cannot
    be put at `path` (it appeared meanwhile, or the move failed), it is saved as `<name>.unplaced-<time>`,
    placed_ok is False and the caller turns the exit status into 4.
    """
    def side(label, why):
        target = _side_path(path, label, stamp)
        try:
            os.replace(tmp, target)
            return target
        except OSError:
            return tmp  # leave the finished report where it is rather than lose it

    if force_side:
        target = side(force_side, None)
        return target, f"The data file could not be placed, so this file was saved as {target} to keep the two together.", False
    if status != 0:
        target = side("failed", None)
        return target, f"The run was not complete, so the report was saved as {target} and {path} was not touched.", False
    try:
        if overwrite:
            os.replace(tmp, path)
            return path, None, True
        try:
            os.link(tmp, path)  # atomic and exclusive
        except FileExistsError:
            target = side("unplaced", None)
            return target, f"{path} appeared during the run, so the report was saved as {target}.", False
        except OSError:
            # No hard links on this file system: create the path exclusively and copy the report into it.
            try:
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
            except FileExistsError:
                target = side("unplaced", None)
                return target, f"{path} appeared during the run, so the report was saved as {target}.", False
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as dst, open(tmp, encoding="utf-8") as src:
                    dst.write(src.read())
            except BaseException:
                path.unlink(missing_ok=True)  # never leave a truncated file at the target
                raise
        tmp.unlink(missing_ok=True)
        return path, None, True
    except OSError as e:
        target = side("unplaced", None)
        return target, f"{path} could not be written ({e}), so the report was saved as {target}.", False


def valid_identity(identity) -> bool:
    return isinstance(identity, dict) and isinstance(identity.get("Account"), str) and isinstance(identity.get("Arn"), str)


def summarize(state, results, pf) -> list:
    """Plain-text reasons why a run was not complete (empty when it was)."""
    reasons = []
    if not state["enabled"]:
        reasons.append(f"Capacity Manager is not usable here (status {state.get('status', 'unknown')}): "
                       f"{state.get('error') or 'run again with --enable and --expect-account'}")
    if pf.bad_azs:
        reasons.append(f"AZ IDs EC2 does not know, not sent: {', '.join(pf.bad_azs)}")
    if pf.excluded_types:
        reasons.append(f"Instance types offered in none of the requested AZs, not sent: {', '.join(pf.excluded_types)}")
    for m, by_amount in results.items():
        for amt, r in by_amount.items():
            failed = [g for g in r.groups if g.error]
            dropped = sorted({v for g in r.groups for v, _k, _e in g.dropped})
            if failed:
                reasons.append(f"{m} x{amt:,}: {len(failed)} of {len(r.groups)} requests failed ({failed[0].error[:120]})")
            if dropped:
                reasons.append(f"{m} x{amt:,}: values the API rejected and the request was repeated without: {', '.join(dropped)}")
    if state["enabled"] and not any(r.groups for by in results.values() for r in by.values()):
        reasons.append("nothing was left to send")
    return reasons


_critical = {"on": False, "pending": False}


def _interrupt(signum, frame):
    """End the run like Ctrl-C, except while files are being placed: finish that step first."""
    if _critical["on"]:
        _critical["pending"] = True
        return
    raise KeyboardInterrupt


def main(argv=None) -> int:
    args = parse_args(argv)
    # SIGTERM and SIGHUP end the run the same way Ctrl-C does, so the cleanup below always runs.
    previous = {}
    for name in ("SIGTERM", "SIGHUP"):
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
              "run, the change stays in place.", file=sys.stderr)
        return 130
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def data_path_for(html_path: Path) -> Path:
    """The data file that belongs to a report: <stem>.json, or <stem>.data.json when the report itself ends in .json."""
    return html_path.with_suffix(".json") if html_path.suffix != ".json" else html_path.with_suffix(".data.json")


def refuse_existing(path: Path, overwrite: bool):
    """Return a message when `path` cannot be used as an output, else None."""
    if path.is_dir():
        return f"{path} is a directory. Give --out a file path."
    if os.path.lexists(path) and not overwrite:
        return f"{path} already exists. Use --overwrite to replace it or --out for another path."
    return None


def _render_only(args) -> int:
    """--from-json: rebuild the HTML from a data file. No AWS calls, no credentials needed."""
    try:
        ctx = from_data(load_data(Path(args.from_json).expanduser()), args.lang or "en", args.lang is not None)
    except (ValueError, OSError, RecursionError) as e:
        print(f"Cannot use the data file: {e}", file=sys.stderr)
        return 2
    out = args.out or f"~/tmp/supportability/report-{datetime.now(JST).strftime('%Y%m%d-%H%M%S-%f')}.html"
    path = Path(out).expanduser()
    problem = refuse_existing(path, args.overwrite)
    if not problem and os.path.lexists(path) and os.path.exists(args.from_json) and os.path.samefile(path, Path(args.from_json).expanduser()):
        problem = f"{path} is the data file you are reading; give --out another path."
    if problem:
        print(problem, file=sys.stderr)
        return 4
    try:
        fh, work = new_work_file(path)
    except OSError as e:
        print(f"Cannot create a file next to {path}: {e}.", file=sys.stderr)
        return 4
    done = False
    try:
        fh.write(render(ctx))
        fh.close()
        stamp = datetime.now(JST).strftime("%Y%m%d-%H%M%S-%f")
        # A page made from the data of an incomplete run keeps that fact in its name, like the run itself did.
        final, note, ok = place_report(work, path, ctx["status"], args.overwrite, stamp)
        done = True
    except Exception as e:
        print(f"Unexpected error: {type(e).__name__}: {e}", file=sys.stderr)
        return 5
    finally:
        if not fh.closed:
            fh.close()
        if not done:
            work.unlink(missing_ok=True)
    if note:
        print(note, file=sys.stderr)
    print(f"Wrote {final}")
    if ctx["status"] != 0:
        print(f"Note: the run that produced this data ended with exit status {ctx['status']}; the page says so.", file=sys.stderr)
    if args.open:
        webbrowser.open(final.resolve().as_uri())
    return 0 if (ok or ctx["status"] != 0) else 4


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

    out = args.out or f"~/tmp/supportability/report-{datetime.now(JST).strftime('%Y%m%d-%H%M%S-%f')}.html"
    path = Path(out).expanduser()
    json_path = data_path_for(path)
    for target in (path, json_path):
        problem = refuse_existing(target, args.overwrite)
        if problem:
            print(f"{problem} Nothing was changed in the account.", file=sys.stderr)
            return 4
    try:
        fh, work_path = new_work_file(path)
        try:
            jfh, json_work = new_work_file(json_path)
        except OSError:
            fh.close()
            work_path.unlink(missing_ok=True)
            raise
    except OSError as e:
        print(f"Cannot create files next to {path}: {e}. Nothing was changed in the account.", file=sys.stderr)
        return 4
    print(f"Account {identity['Account']}; {n_calls} calls planned; output {path} and {json_path.name}")

    retry_budget = [max(0, args.max_calls - n_calls)]  # repeats after dropping a rejected value must stay inside the cap
    known_bad = set()
    done = False
    try:
        pf = preflight(session, None if requirements is not None else args.types, args.azs)
        state, log = ensure_manager(ec2, args.enable)
        for en, _ in log:
            print(en)

        results = {m: {} for m in args.markets}
        calls = 0
        for m in args.markets:
            for amt in args.amounts:
                if state["enabled"] and pf.azs and (requirements is not None or pf.types):
                    res = run_query(ec2, m, amt, args.unit, pf.types, pf.azs, requirements, retry_budget, known_bad)
                    calls += res.sent
                    bad = sum(1 for g in res.groups if g.error)
                    print(f"  {m:9s} x{amt:<6d} rows {len(res.cells):3d}  errors {bad}")
                else:
                    res = Result()
                results[m][amt] = res

        status = exit_status(state, results, pf)
        reasons = summarize(state, results, pf)
        collected = {"identity": identity, "region": args.region, "state": state, "log": log, "status": status,
                     "now": datetime.now(JST).strftime("%Y-%m-%d %H:%M:%S"),
                     "types": None if requirements is not None else args.types, "azs": pf.azs, "pf": pf,
                     "markets": args.markets, "amounts": args.amounts, "unit": args.unit,
                     "results": results, "calls": calls, "reasons": reasons}
        # The data file is the single source of the page: write it, read it back, render from what was read.
        text = json.dumps(to_data(collected), indent=2, ensure_ascii=False)
        jfh.write(text + "\n")
        jfh.close()
        ctx = from_data(json.loads(text), args.lang or "en", args.lang is not None)
        fh.write(render(ctx))
        fh.close()
        stamp = datetime.now(JST).strftime("%Y%m%d-%H%M%S-%f")
        _critical["on"] = True
        try:
            # The data file is the source of the page, so it goes first; if it cannot be placed, the page is kept beside it.
            final_json, note_json, ok_json = place_report(json_work, json_path, status, args.overwrite, stamp)
            final, note, ok_html = place_report(work_path, path, status, args.overwrite, stamp,
                                                force_side=None if ok_json or status != 0 else "unplaced")
        finally:
            _critical["on"] = False
        done = True
        notes = [n for n in (note_json, note) if n]
        if status == 0 and not (ok_html and ok_json):
            status = 4  # the run itself was fine, but a file is not at the path that was asked for
        if _critical["pending"]:
            _critical["pending"] = False
            raise KeyboardInterrupt
    except Exception as e:  # report any unexpected failure with its own exit status
        print(f"Unexpected error: {type(e).__name__}: {e}", file=sys.stderr)
        return 5
    finally:
        for handle in (fh, jfh):
            if not handle.closed:
                handle.close()
        if not done:
            # An interrupted or crashed run leaves no half-written file behind and never touches the target paths.
            # If the account was changed before that, the console output above says so.
            work_path.unlink(missing_ok=True)
            json_work.unlink(missing_ok=True)
    if status != 0:
        print(f"RESULT: INCOMPLETE (exit status {status})", file=sys.stderr)
        for r in reasons:
            print(f"  - {r}", file=sys.stderr)
    else:
        print("RESULT: complete")
    for n in notes:
        print(n, file=sys.stderr if status != 0 else sys.stdout)
    print(f"Wrote {final}")
    print(f"Wrote {final_json}")
    if args.open:
        webbrowser.open(final.resolve().as_uri())
    return status


if __name__ == "__main__":
    sys.exit(main())
