"""Collecting the scores: request planning, the free preflight checks, the Capacity Manager state and the queries.

Nothing here formats output. Every function returns plain objects that document.to_data turns into the data file.
"""
from __future__ import annotations

import re
import sys
import time
from dataclasses import dataclass, field
from datetime import timedelta, timezone

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
# Instance types and AZ IDs: lower-case letters, digits, "." and "-" (p6-b200.48xlarge, usw2-lax1-az1). Anything else
# is refused at the entry and in a data file, so no value can break a tab-separated record or a table column.
NAME = re.compile(r"[a-z0-9][a-z0-9.\-]*\Z")

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

def _natural(text):
    """Sort key that puts use1-az2 before use1-az10."""
    return [int(t) if t.isdigit() else t for t in re.split(r"(\d+)", text)]


def az_sort_key(az_id: str):
    """Keep the AZs of one Region together, in natural order."""
    return region_of(az_id), _natural(az_id)


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
                      and row["Score"] in RANK and NAME.match(row["InstanceType"]) is not None
                      and NAME.match(row["AvailabilityZoneId"]) is not None)
                if ok:
                    res.cells[(row["InstanceType"], row["AvailabilityZoneId"])] = row["Score"]
                else:
                    bad_rows += 1
            if bad_rows:
                group.error = f"UnexpectedResponse: {bad_rows} score rows were malformed and were left out"
            break
    return res


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


def exit_status(state, results, pf=None) -> int:
    """0 only when Capacity Manager was usable, nothing asked for was left out and every request returned scores.

    The scores that were collected are still printed and saved, but automation sees the failure. A data file
    read back with --from-json is held to the same rule, so an edited status cannot claim a complete run.
    """
    if not state["enabled"]:
        return 3
    if pf is not None and (pf.bad_azs or pf.excluded_types):
        return 3
    groups = [g for by_amount in results.values() for r in by_amount.values() for g in r.groups]
    return 3 if not groups or any(g.error or g.dropped for g in groups) else 0


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
    print("Ran enable-capacity-manager; the change stays in place.", file=sys.stderr, flush=True)
    log.append(("Ran enable-capacity-manager. This starts data ingestion and can be done in one Region per account; the change stays in place.",
                "enable-capacity-manager を実行しました。データの取り込みが始まります。有効にできるのは 1 アカウントにつき 1 Region だけで、この変更は残ります。"))
    time.sleep(4)
    status, attrs, error = read_status(ec2)
    if status != "enabled":
        return {"enabled": False, "status": status, "attrs": {}, "error": error or "enable-capacity-manager was sent but the status could not be confirmed as enabled; the change may still be taking effect, so check get-capacity-manager-attributes and run again"}, log
    return {"enabled": True, "status": "enabled", "attrs": attrs, "error": None}, log
