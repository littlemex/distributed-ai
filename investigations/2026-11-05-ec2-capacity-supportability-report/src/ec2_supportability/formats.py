"""Standard-output formats: table (for people), json, text (tab-separated, for awk and cut) and env (for eval).

Each format reads the data document made by document.to_data. With a JMESPath --query, the query runs on that
document and the format prints the query's result instead of the default view.
"""
from __future__ import annotations

import json
import re
import shlex

import jmespath
from jmespath.exceptions import JMESPathError

FORMATS = ("table", "json", "text", "env")
LABEL = {"high": "High", "medium": "Medium", "low": "Low"}
STATE_LABEL = {"missing": "N/A", "not_offered": "Not offered", "failed": "Error", "not_sent": "Not sent",
               "unknown_az": "Unknown AZ"}
STATE_HELP = {
    "N/A": "the request succeeded but its response had no row for this pair. It is not Low.",
    "Not offered": "EC2 says this instance type is not offered in this AZ, so it was not asked about.",
    "Error": "the request for this pair failed, or the API rejected a value and the pair was left out.",
    "Not sent": "no request was sent (see the messages on standard error).",
    "Unknown AZ": "EC2 does not know this AZ ID, so it was not sent.",
    "-": "no row for this pair; attribute-based requests list only the pairs they scored.",
}
ANSI = {"High": "32", "Medium": "33", "Low": "31"}
_ENV_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")
# Names that change how a shell, the dynamic linker or Python behave. A prefix plus a --query key can spell them
# (prefix P and key ath give PATH), so --output env refuses to print them whatever the prefix.
_UNSAFE_ENV = re.compile(r"(PATH|IFS|ENV|BASH_ENV|CDPATH|HOME|SHELL|SHELLOPTS|BASHOPTS|PROMPT_COMMAND|PS[1-4]"
                         r"|LD_\w*|DYLD_\w*|BASH_FUNC_\w*|PYTHON\w*)\Z")


class OutputError(ValueError):
    """The query result cannot be printed in the chosen format."""


def dumps(value) -> str:
    """JSON text in ASCII, so it prints the same through any terminal or pipe encoding (Windows code pages included)."""
    return json.dumps(value, indent=2, ensure_ascii=True)


def compile_query(expression: str):
    """Compile a JMESPath expression; raises ValueError so a typo is refused before any AWS call."""
    try:
        return jmespath.compile(expression)
    except JMESPathError as e:
        raise ValueError(f"--query is not a valid JMESPath expression: {e}") from e


def check_env_prefix(prefix: str) -> None:
    # Not empty: without a prefix a --query key could name PATH, IFS or BASH_ENV, and eval would replace it.
    if not _ENV_NAME.match(prefix):
        raise ValueError("--env-prefix must not be empty, must start with a letter or _, and may contain only "
                         "letters, digits and _")


def render(doc: dict, fmt: str, query=None, env_prefix: str = "CS_", color: bool = False) -> str:
    """Return the text to print (without a trailing newline)."""
    if query is not None:
        try:
            value = query.search(doc)
        except JMESPathError as e:  # a well-formed expression can still fail on the data, e.g. length(`null`)
            raise OutputError(f"--query failed on this data: {e}") from e
        if fmt == "json":
            return dumps(value)
        if fmt == "table":
            return _table_of(value)
        if fmt == "text":
            return _text_of(value)
        return _env_of(value, env_prefix)
    if fmt == "json":
        return dumps(doc)
    if fmt == "table":
        return _table(doc, color)
    if fmt == "text":
        return _text(doc)
    return _env(doc, env_prefix)


# --------------------------------------------------------------------------------------- default views

def _cell_label(row) -> str:
    return LABEL[row["score"]] if row["score"] else STATE_LABEL[row["state"]]


def _aggregate_label(row) -> str:
    return LABEL[row["score"]] if row["score"] else "Error"


def _paint(text: str, width: int, color: bool) -> str:
    padded = text.ljust(width)
    code = ANSI.get(text) if color else None
    return f"\x1b[{code}m{text}\x1b[0m" + padded[len(text):] if code else padded


def _blocks(doc):
    """(market, amount, score rows, aggregate rows) in request order."""
    req = doc["request"]
    for market in req["markets"]:
        for amount in req["amounts"]:
            yield (market, amount,
                   [r for r in doc["scores"] if r["market"] == market and r["amount"] == amount],
                   [g for g in doc["aggregates"] if g["market"] == market and g["amount"] == amount])


def _unit(unit: str, amount: int) -> str:
    word = "vCPU" if unit == "vcpus" else "instance"
    return word if amount == 1 else word + "s"


def _table(doc: dict, color: bool) -> str:
    req = doc["request"]
    out = [f"Check supportability  {req['region']}  {doc['generated_at_jst'][:16]} JST  result: {doc['result']}"]
    azs, used = req.get("requested_azs") or req["azs"], set()
    for market, amount, rows, aggs in _blocks(doc):
        name = "On-Demand" if market == "on-demand" else "Spot"
        if not aggs:
            agg = "aggregate: not sent"
        elif len(aggs) == 1:
            agg = f"aggregate: {_aggregate_label(aggs[0])}"
        else:
            agg = "aggregate per request: " + ", ".join(f"{g['request']}/{g['requests']} {_aggregate_label(g)}" for g in aggs)
        out += ["", f"{name}, {amount:,} {_unit(req['unit'], amount)}   {agg}"]
        types = list(dict.fromkeys(r["instance_type"] for r in rows))
        if not types:
            out.append("  (no scores)")
            continue
        by = {(r["instance_type"], r["az_id"]): r for r in rows}
        labels = {(t, z): _cell_label(by[(t, z)]) if (t, z) in by else "-" for t in types for z in azs}
        used.update(v for v in labels.values() if v in STATE_HELP)
        w0 = max(len("INSTANCE TYPE"), *map(len, types)) + 2
        wz = max(len("Medium"), *map(len, azs), *map(len, labels.values())) + 2
        out.append(("  " + "INSTANCE TYPE".ljust(w0) + "".join(z.ljust(wz) for z in azs)).rstrip())
        for t in types:
            cells = "".join(_paint(labels[(t, z)], wz, color) for z in azs)
            out.append(("  " + t.ljust(w0) + cells).rstrip())
        if len(aggs) > 1:
            out.append("  The run was split into several requests to stay within the per-request limits; "
                       "each aggregate belongs to its own request and there is no single one.")
    if used:
        out.append("")
        out += [f"{k}: {v}" for k, v in STATE_HELP.items() if k in used]
    return "\n".join(out)


def _na(v) -> str:
    return "n/a" if v is None else str(v)


def _text(doc: dict) -> str:
    req = doc["request"]
    lines = [f"RESULT\t{doc['result']}\t{doc['status']}\t{req['region']}\t{req['unit']}"]
    lines += [f"AGGREGATE\t{g['market']}\t{g['amount']}\t{g['request']}\t{g['requests']}\t{_na(g['score'])}"
              for g in doc["aggregates"]]
    lines += [f"SCORE\t{r['market']}\t{r['amount']}\t{r['instance_type']}\t{r['az_id']}\t{_na(r['score'])}\t{r['state']}"
              for r in doc["scores"]]
    return "\n".join(lines)


def _env_key(prefix: str, *parts) -> str:
    return prefix + re.sub(r"[^A-Z0-9]+", "_", "_".join(str(p) for p in parts).upper()).strip("_")


def _env(doc: dict, prefix: str) -> str:
    req = doc["request"]
    pairs = [(_env_key(prefix, "RESULT"), doc["result"]), (_env_key(prefix, "REGION"), req["region"]),
             (_env_key(prefix, "UNIT"), req["unit"])]
    for market, amount, rows, aggs in _blocks(doc):
        # The plain name is always printed, and empty unless one request covered the whole market and amount, so a
        # split run can never leave a whole-set aggregate from an earlier eval in the shell.
        single = aggs[0]["score"] if len(aggs) == 1 else None
        pairs.append((_env_key(prefix, "AGGREGATE", market, amount), single or ""))
        if len(aggs) > 1:
            pairs += [(_env_key(prefix, "AGGREGATE", market, amount, g["request"]), g["score"] or "") for g in aggs]
        for level in ("high", "medium", "low"):
            hits = [f"{r['instance_type']}:{r['az_id']}" for r in rows if r["score"] == level]
            pairs.append((_env_key(prefix, level, market, amount), " ".join(hits)))
    return "\n".join(f"export {k}={shlex.quote(v)}" for k, v in pairs)


# --------------------------------------------------------------------------------------- query results

_ESCAPES = str.maketrans({"\\": "\\\\", "\t": "\\t", "\n": "\\n", "\r": "\\r"})


def _scalar(v) -> str:
    """One field of a text record: backslash, tab and line breaks are escaped, so a field never splits a record."""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (dict, list)):
        return json.dumps(v, ensure_ascii=True, separators=(",", ":"))
    return _na(v).translate(_ESCAPES)


def _plain(v) -> str:
    """A value as the shell should hold it: shlex.quote makes any text safe, so nothing is escaped here."""
    if isinstance(v, bool):
        return "true" if v else "false"
    return "n/a" if v is None else str(v)


def _text_of(v) -> str:
    if isinstance(v, list):
        if all(not isinstance(x, (list, dict)) for x in v):
            return "\t".join(_scalar(x) for x in v)
        return "\n".join("\t".join(_scalar(y) for y in (x.values() if isinstance(x, dict) else x))
                         if isinstance(x, (list, dict)) else _scalar(x) for x in v)
    if isinstance(v, dict):
        return "\t".join(_scalar(x) for x in v.values())
    return _scalar(v)


def _table_of(v) -> str:
    if isinstance(v, dict):
        v = [v]
    if not isinstance(v, list):
        return _scalar(v)
    if v and all(isinstance(x, dict) for x in v):
        cols = list(dict.fromkeys(k for x in v for k in x))
        rows = [[c.upper() for c in cols]] + [[_scalar(x.get(c)) for c in cols] for x in v]
    else:
        rows = [[_scalar(y) for y in x] if isinstance(x, list) else [_scalar(x)] for x in v]
    if not rows:
        return ""
    width = [max(len(r[i]) for r in rows if i < len(r)) for i in range(max(map(len, rows)))]
    return "\n".join("  ".join(c.ljust(width[i]) for i, c in enumerate(r)).rstrip() for r in rows)


def _env_of(v, prefix: str) -> str:
    if not isinstance(v, dict):
        raise OutputError("--output env needs --query to return an object, for example "
                          "\"{aggregate: aggregates[0].score}\"; this query returned a " + type(v).__name__)
    pairs, seen = [], {}
    for k, x in v.items():
        name = _env_key(prefix, k)
        if not _ENV_NAME.match(name):
            raise OutputError(f"the key {k!r} does not make a valid variable name ({name!r}); rename it in --query")
        if _UNSAFE_ENV.match(name):
            raise OutputError(f"the key {k!r} makes {name}, which would change how the shell or programs run; "
                              "rename it in --query or change --env-prefix")
        if name in seen:
            raise OutputError(f"the keys {seen[name]!r} and {k!r} both become {name}; rename one in --query")
        seen[name] = k
        if isinstance(x, list):
            if any(isinstance(y, (list, dict)) for y in x):
                raise OutputError(f"the value of {k!r} is a list that holds lists or objects; env takes strings, "
                                  "numbers and flat lists")
            value = " ".join(_plain(y) for y in x)
        elif isinstance(x, dict):
            raise OutputError(f"the value of {k!r} is an object; env takes strings, numbers and flat lists")
        else:
            value = "" if x is None else _plain(x)
        pairs.append((name, value))
    return "\n".join(f"export {k}={shlex.quote(x)}" for k, x in pairs)
