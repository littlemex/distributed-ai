"""The data file: everything a run collected, as one JSON document, and the checks that read it back.

Every output (table, text, env, json, HTML) is made from this document only, so a saved file reproduces any of them
later without calling AWS.
"""
from __future__ import annotations

import json
from pathlib import Path

import re

from .collect import NAME, RANK, Group, Preflight, Result, az_sort_key, exit_status, failed_pairs, summarize

SCHEMA = "ec2-capacity-supportability-report/2"
# /1 is the same document without the derived lists "result", "scores" and "aggregates"; it is still read.
READABLE_SCHEMAS = ("ec2-capacity-supportability-report/1", SCHEMA)
SCORE_STATES = ("scored", "unknown_az", "not_sent", "not_offered", "failed", "missing")
REGION = re.compile(r"[a-z0-9][a-z0-9\-]*\Z")


def score_rows(ctx: dict) -> list:
    """One row per instance type x AZ pair and per market x amount, flat so a --query can filter it.

    With an explicit type list every requested pair gets a row, AZ IDs that EC2 does not know included, and a pair
    without a score says why, in this order: unknown_az (EC2 does not know the AZ ID, so it was not sent), not_sent
    (no request was sent for this market and amount, for example because Capacity Manager was not usable),
    not_offered (EC2 says the type is not offered there), failed (its request failed or the pair was dropped from it)
    or missing (the request succeeded but the response had no row for it). With attribute-based requirements the
    types are not known in advance, so only the scored pairs have rows.
    """
    pf, rows = ctx["pf"], []
    for market in ctx["markets"]:
        for amount in ctx["amounts"]:
            res = ctx["results"][market][amount]
            failed = failed_pairs(res)
            if ctx["types"] is None:
                pairs = sorted(res.cells)
            else:
                pairs = [(t, az) for t in ctx["types"] for az in requested_azs(ctx)]
            for t, az in pairs:
                score = res.cells.get((t, az))
                if score is not None:
                    state = "scored"
                elif az in pf.bad_azs:
                    state = "unknown_az"
                elif not res.groups:
                    state = "not_sent"
                elif (t, az) in pf.not_offered or t in pf.excluded_types:
                    state = "not_offered"
                elif (t, az) in failed:
                    state = "failed"
                else:
                    state = "missing"
                rows.append({"market": market, "amount": amount, "instance_type": t, "az_id": az,
                             "score": score, "state": state})
    return rows


def requested_azs(ctx: dict) -> list:
    """Every AZ ID that was asked for: the ones sent and the ones EC2 did not know, in the order of the request."""
    return sorted(dict.fromkeys([*ctx["azs"], *ctx["pf"].bad_azs]), key=az_sort_key)


def aggregate_rows(ctx: dict) -> list:
    """One row per request. A run split into several requests has several aggregates and no single one."""
    rows = []
    for market in ctx["markets"]:
        for amount in ctx["amounts"]:
            groups = ctx["results"][market][amount].groups
            for i, g in enumerate(groups, 1):
                rows.append({"market": market, "amount": amount, "request": i, "requests": len(groups),
                             "score": g.aggregate, "error": g.error, "instance_types": g.types, "az_ids": g.azs})
    return rows


def to_data(ctx: dict) -> dict:
    """Turn what a run collected into a plain, JSON-serialisable document.

    Every output is made from this document only (see from_data), so any of them can be rebuilt later without
    calling the API. "scores", "aggregates" and "result" are derived from the other fields; from_data does not read
    them, so reading a document and writing it again always recomputes them from the facts.
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
        "generated_by": "ec2-supportability",
        "generated_at_jst": ctx["now"],
        "result": "complete" if ctx["status"] == 0 else "incomplete",
        "status": ctx["status"],
        "reasons": ctx.get("reasons", []),
        "identity": {"Account": ctx["identity"]["Account"], "Arn": ctx["identity"]["Arn"]},
        "request": {"region": ctx["region"], "markets": ctx["markets"], "amounts": ctx["amounts"], "unit": ctx["unit"],
                    "types": ctx["types"], "requirements": ctx.get("requirements"), "azs": ctx["azs"],
                    "requested_azs": requested_azs(ctx), "calls": ctx["calls"]},
        "state": {"enabled": ctx["state"]["enabled"], "status": ctx["state"].get("status", "unknown"),
                  "error": ctx["state"].get("error"), "needs_enable": bool(ctx["state"].get("needs_enable")),
                  "attrs": {k: attrs[k] for k in ("CapacityManagerStatus", "IngestionStatus")
                            if isinstance(attrs.get(k), str)}},
        "log": [list(x) for x in ctx["log"]],
        "preflight": {"azs": pf.azs, "types": pf.types, "bad_azs": pf.bad_azs, "excluded_types": pf.excluded_types,
                      "not_offered": sorted([t, az] for t, az in pf.not_offered),
                      "notes": [list(n) for n in pf.notes]},
        "results": results,
        "scores": score_rows(ctx),
        "aggregates": aggregate_rows(ctx),
    }


def _need(cond, why):
    if not cond:
        raise ValueError(why)


def _str_list(v, name, allow_none=False):
    if v is None and allow_none:
        return None
    _need(isinstance(v, list) and all(isinstance(x, str) for x in v), f"{name} must be a list of strings")
    return list(v)


def _names(v, name, allow_none=False):
    v = _str_list(v, name, allow_none)
    _need(v is None or all(NAME.match(x) for x in v), f"{name} has a value that is not an instance type or AZ ID")
    _need(v is None or len(set(v)) == len(v), f"{name} has a repeated value")
    return v


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
    _need(data.get("schema") in READABLE_SCHEMAS,
          f"unsupported schema {data.get('schema')!r} (expected one of {', '.join(READABLE_SCHEMAS)})")
    ident = data.get("identity")
    _need(isinstance(ident, dict) and isinstance(ident.get("Account"), str) and isinstance(ident.get("Arn"), str), "identity is missing")
    req = data.get("request")
    _need(isinstance(req, dict), "request is missing")
    markets = _str_list(req.get("markets"), "request.markets")
    _need(all(m in ("on-demand", "spot") for m in markets) and len(set(markets)) == len(markets),
          "request.markets has an unknown or repeated market")
    amounts = req.get("amounts")
    _need(isinstance(amounts, list) and all(isinstance(a, int) and not isinstance(a, bool) and a >= 1 for a in amounts)
          and len(set(amounts)) == len(amounts), "request.amounts must be distinct positive integers")
    _need(isinstance(req.get("region"), str) and REGION.match(req["region"]) is not None
          and req.get("unit") in ("instances", "vcpus"), "request.region or request.unit is invalid")
    _need(type(req.get("calls")) is int, "request.calls must be an integer")
    types = _names(req.get("types"), "request.types", allow_none=True)
    requirements = req.get("requirements")
    _need(requirements is None or isinstance(requirements, dict), "request.requirements must be an object or null")
    azs = _names(req.get("azs"), "request.azs")
    st = data.get("state")
    _need(isinstance(st, dict) and isinstance(st.get("enabled"), bool) and isinstance(st.get("status"), str), "state is invalid")
    _need(st.get("error") is None or isinstance(st.get("error"), str), "state.error must be a string or null")
    _need(type(data.get("status")) is int and data["status"] in (0, 3)
          and isinstance(data.get("generated_at_jst"), str), "status must be 0 or 3, and generated_at_jst a string")
    reasons = _str_list(data.get("reasons", []), "reasons")
    pfd = data.get("preflight")
    _need(isinstance(pfd, dict), "preflight is missing")
    pf = Preflight(azs=_names(pfd.get("azs"), "preflight.azs"), types=_names(pfd.get("types"), "preflight.types", True),
                   bad_azs=_names(pfd.get("bad_azs"), "preflight.bad_azs"),
                   excluded_types=_names(pfd.get("excluded_types"), "preflight.excluded_types"),
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
                _need(isinstance(row, list) and len(row) == 3 and all(isinstance(x, str) for x in row) and row[2] in RANK
                      and NAME.match(row[0]) is not None and NAME.match(row[1]) is not None, "a cell row is invalid")
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
                groups.append(Group(types=_names(g.get("types"), "group.types", True), azs=_names(g.get("azs"), "group.azs"),
                                    aggregate=g.get("aggregate"), error=g.get("error"), dropped=dropped,
                                    all_types=_names(g.get("all_types"), "group.all_types", True),
                                    all_azs=_names(g.get("all_azs"), "group.all_azs")))
            _need(type(r.get("retries", 0)) is int and type(r.get("sent", 0)) is int, "retries and sent must be integers")
            results[market][amount] = Result(cells=cells, groups=groups, retries=r.get("retries", 0), sent=r.get("sent", 0))
    attrs = st.get("attrs") or {}
    _need(isinstance(attrs, dict) and all(isinstance(v, str) for v in attrs.values()), "state.attrs is invalid")
    state = {"enabled": st["enabled"], "status": st["status"], "error": st.get("error"),
             "needs_enable": bool(st.get("needs_enable")), "attrs": attrs}
    # The facts decide whether the run was complete: a status edited to 0 cannot hide a failed request, and the
    # reasons are then rebuilt from the same facts so the output never says "incomplete" without saying why.
    status = max(data["status"], exit_status(state, results, pf))
    if status != data["status"]:
        reasons = summarize(state, results, pf)
    return {"identity": {"Account": ident["Account"], "Arn": ident["Arn"]}, "region": req["region"], "state": state, "log": log,
            "status": status, "requirements": requirements, "now": data["generated_at_jst"], "types": types, "azs": azs, "pf": pf,
            "markets": markets, "amounts": amounts, "unit": req["unit"], "results": results, "calls": req["calls"],
            "reasons": reasons, "lang": lang, "lang_explicit": lang_explicit}


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
