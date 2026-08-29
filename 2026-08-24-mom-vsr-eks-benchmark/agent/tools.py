"""What the agent can do to the repository, and what each action is a step *of*.

Two jobs here, and the second is the one v3 needs.

The obvious job is a small tool set over `/testbed`. It is deliberately small: every tool
is one the routing question can be asked about, and nothing is provided that would let a
scaffold's cleverness rather than a model's capability decide the outcome.

The other job is the step label. `docs/V3-PLAN.md` rules out *inferred* difficulty — v1
measured a plausible-looking feature, the domain label, carrying no accuracy signal at
p = 0.58 — and rules in the step type on the grounds that a harness does not have to
predict it. That only holds if the label comes from the action rather than from the model's
description of the action, so it is derived here from the tool that was called and a model
cannot relabel its own work by claiming a step was trivial.

The tool syntax is text rather than the provider tool-calling API. The pool spans three
providers reached through one gateway, and each disagrees about tool schemas, streaming of
tool deltas and whether an assistant turn may carry both text and a call. A text protocol
is the same for all of them, which is what makes the arms comparable — the cost is that a
malformed call has to be handled, and it is, by telling the model what went wrong and
charging it the turn.
"""

from __future__ import annotations

import json
import re
import shlex
import subprocess
from dataclasses import dataclass
from pathlib import Path

TESTBED = Path("/testbed")
CONDA = "source /opt/miniconda3/etc/profile.d/conda.sh && conda activate testbed"

# The label attached to a step, from the tool it used. The routing table in `policy.py`
# is written against these names.
STEP_TYPE = {
    "list_dir": "search",
    "search": "search",
    "read_file": "read",
    "run_tests": "verify",
    "write_patch": "patch",
    # Its own type rather than "patch": the worker's handoff turn is cheap investigation
    # ending, and folding its cost into the patch share would inflate the very figure that
    # bounds what role-based routing can save.
    "handoff": "handoff",
    "done": "finish",
}

# The reader's grammar version, and it is part of every result. v1 accepted `key: value` lines
# only. v2 also accepts two encodings of the same pair that models trained on tool-calling emit
# inside the block -- `<parameter=key>value</parameter>` and `<key>value</key>` -- because a
# self-hosted Qwen3.6-35B-A3B wrote 68.8% of its arguments that way and scored zero for it while
# naming the right tool every time.
#
# Frozen 2026-08-29, before the re-run that motivated it, and extended after observing that
# model's output. That is disclosed rather than presented as neutral: the change lifts exactly one
# tier, because the two APIs never emitted these forms (0 of 1330 and 0 of 258 recorded steps) and
# the previous box emitted them 8 times in 640. What it must never do is absorb a real failure, so
# it does not invent values, does not map an invented tool name onto a real one, and does not
# rescue an empty value. Every action records which encodings produced it, and every episode
# counts how many needed a tolerant one, so "the reader learned its dialect" stays separable from
# "the model got better".
GRAMMAR_VERSION = 2

# The argument names each tool owns. A tolerant encoding is honoured only for a name in this
# table: `<dir>/testbed</dir>` is an argument to `list_dir` and `<thinking>...</thinking>` is not,
# and without the table the second becomes an argument called "thinking".
ARG_NAMES = {
    "list_dir": ("dir",),
    "search": ("pattern", "dir"),
    "read_file": ("path", "start"),
    "run_tests": ("target",),
    "write_patch": ("path", "old", "new"),
    "done": ("note",),
    "handoff": ("note",),
}

# Enough to read a definition and its neighbourhood; not enough to page a whole module in
# one turn, which is how a context fills with material no step needed.
MAX_READ_LINES = 400
MAX_OUTPUT_CHARS = 6000
TEST_TIMEOUT_S = 900


@dataclass(frozen=True)
class Action:
    """One parsed tool call."""

    tool: str
    args: dict[str, str]
    raw: str = ""
    # Which serialisation each argument arrived in, most-canonical first. Kept per action rather
    # than per episode so a solved trajectory can be checked for whether it ever needed the
    # tolerant path.
    encodings: tuple[str, ...] = ()

    # The text encodings v1 refused. Named rather than defined by exclusion, so that the
    # function-calling arm -- a different protocol, not a lenient reading of this one -- does not
    # count every one of its actions as a tolerant parse and hide the number that matters.
    TOLERATED = ("parameter-tag", "element-tag")

    @property
    def tolerant(self) -> bool:
        """Did reading this action need a text encoding v1 would have rejected?"""
        return any(e in self.TOLERATED for e in self.encodings)

    @property
    def step_type(self) -> str:
        return STEP_TYPE.get(self.tool, "unknown")

    @property
    def signature(self) -> str:
        """What counts as "the same action again", for loop detection.

        The arguments that name the target are part of it and the ones that only move a
        window are not: re-reading the next hundred lines of a file is progress, while
        reading the same hundred lines four times is the loop the second trigger exists to
        catch.
        """
        keys = ("path", "pattern", "target", "dir")
        named = " ".join(f"{k}={self.args[k]}" for k in keys if k in self.args)
        if "old" in self.args:
            # Three different edits to one file are three actions, not a loop. Without this
            # they share a signature and the loop detector escalates a working agent.
            named += f" old#{abs(hash(self.args['old'])) % 100000:05d}"
        return f"{self.tool}({named})"


@dataclass(frozen=True)
class Observation:
    """What came back, and whether it was the kind of answer that decides anything."""

    text: str
    ok: bool = True
    # Set only by `run_tests`. None means this step said nothing about correctness, which
    # is different from having said the code is fine — the first trigger depends on the
    # distinction.
    tests_passed: bool | None = None


# One entry per tool, so a policy that withholds one removes it exactly. An earlier version
# filtered the description line by line and left the continuation lines of the multi-line
# entry behind, which advertised half a tool that would then be refused — the arm pays for
# the harness being inconsistent with itself.
TOOL_DOCS = {
    "list_dir": "  list_dir      dir: <path>                      what is in a directory",
    "search": "  search        pattern: <regex>  [dir: <path>]  where a name appears in the tree",
    "read_file": "  read_file     path: <path>  [start: <line>]    up to 400 lines from `start`",
    "run_tests": "  run_tests     target: <pytest target>          run tests that already exist here",
    "write_patch": """\
  write_patch   path: <path>                     replace an exact block of a file
                old: <<<
                ...the exact lines to replace...
                >>>
                new: <<<
                ...what to put there...
                >>>""",
    "handoff": """\
  handoff       note: <the fix, and the files it touches>
                you do not write the patch yourself: describe it and hand off""",
    "done": "  done          note: <why you are finished>",
}

# What the main loop offers when nothing is withheld.
DEFAULT_TOOLS = ("list_dir", "search", "read_file", "run_tests", "write_patch", "done")

PROTOCOL_HEAD = """\
{opening}

{example}

The tools:

{tools}

Rules that are enforced rather than requested:

* Editing a test file fails the task. The tests that judge you are not in this checkout;
  they are applied after you finish, so there is nothing to be gained by guessing at them.
{rules}{cadence}"""

# A worked example, chosen from the tools on offer. It carries a real hint that a generic
# `key: value` skeleton does not: paths are relative to the checkout. With the skeleton in
# its place a cheap model sent `/testbed/requests/requests/models.py` and its only edit was
# refused.
EXAMPLES = {
    "read_file": '<action tool="read_file">\npath: requests/models.py\nstart: 120\n</action>',
    "search": '<action tool="search">\npattern: def prepare_body\n</action>',
    "write_patch": (
        '<action tool="write_patch">\npath: requests/models.py\n'
        "old: <<<\n    if length is not None:\n>>>\n"
        "new: <<<\n    if length:\n>>>\n</action>"
    ),
}


ONE_PER_TURN = """\
Reply with exactly one action per turn, in this form and nothing else after it:"""

AS_MANY_AS_NEEDED = """\
Reply with actions in this form and nothing else — as many as the work needs:"""

CADENCE_ONE = """\
* One action per turn. Text before the action is ignored, so put your reasoning there if
  it helps you, but keep it short — it is charged for.
"""

CADENCE_MANY = """\
* Text before the actions is ignored, so put your reasoning there if it helps you, but keep
  it short — it is charged for.
"""

# A rule that only makes sense if the tool is on offer. Shown with it and not otherwise,
# because a prompt is charged for and a rule about a tool the worker does not have is a
# line of confusion it pays for.
TOOL_RULES = {
    "write_patch": (
        "* `old:` must appear exactly once in the file, whitespace included. If it does "
        "not, the\n  edit is refused and you are told so.\n"
    ),
}

def protocol(
    withhold: tuple[str, ...] = (),
    add: tuple[str, ...] = (),
    one_per_turn: bool = True,
) -> str:
    """The protocol text for a policy that does not offer every tool.

    A withheld tool is removed from the description as well as refused at call time.
    Advertising one and then rejecting it costs the arm a turn for nothing.

    `one_per_turn` is a real setting rather than a constant. The patch handoff asks for as
    many edits as the fix needs, and an earlier version embedded a protocol that told the
    same model, twice, to send exactly one action — so the models that follow instructions
    most closely wrote a single-file patch for a two-file fix.
    """
    unknown = sorted((set(withhold) | set(add)) - set(TOOL_DOCS))
    if unknown:
        raise ValueError(f"no tool called {unknown}; the tools are {sorted(TOOL_DOCS)}")
    names = [name for name in DEFAULT_TOOLS if name not in withhold]
    names += [name for name in add if name not in names]
    example = next(
        (EXAMPLES[name] for name in ("read_file", "search", "write_patch") if name in names),
        EXAMPLES["write_patch"],
    )
    return PROTOCOL_HEAD.format(
        opening=ONE_PER_TURN if one_per_turn else AS_MANY_AS_NEEDED,
        example=example,
        cadence=CADENCE_ONE if one_per_turn else CADENCE_MANY,
        tools="\n".join(TOOL_DOCS[name] for name in names),
        rules="".join(TOOL_RULES[name] for name in names if name in TOOL_RULES),
    )


# Kept so callers that want every tool need not spell the list out.
PROTOCOL = protocol()


# The same tools as a JSON schema, for the diagnostic arm that drives the model through its own
# tool-calling interface instead of this text protocol. It exists to answer one question the text
# arm cannot: how much of a model's failure to drive the tools is the protocol's near-miss
# resemblance to the syntax the model was trained on. A Qwen3.6-35B-A3B told to emit
# `<action tool="search">` writes `<parameter=pattern">` -- its native form with the wrapper's
# attribute quoting bleeding in -- so the two are not independent.
#
# Descriptions are the same sentences the text protocol shows, so the arms differ in encoding and
# not in what the model is told the tools do.
_SCHEMA_DESC = {
    "list_dir": "what is in a directory",
    "search": "where a name appears in the tree, as a regex",
    "read_file": "up to 400 lines of a file from `start`",
    "run_tests": "run tests that already exist in this checkout",
    "write_patch": "replace an exact block of a file; `old` must appear exactly once, whitespace included",
    "done": "you are finished, and why",
    "handoff": "describe the fix and the files it touches, without writing the patch yourself",
}
_SCHEMA_ARGS = {
    "dir": ("string", "a path relative to the checkout"),
    "pattern": ("string", "a regex"),
    "path": ("string", "a path relative to the checkout"),
    "start": ("integer", "the first line to show"),
    "target": ("string", "a pytest target"),
    "old": ("string", "the exact lines to replace"),
    "new": ("string", "what to put there"),
    "note": ("string", "one or two sentences"),
}
# Which arguments a tool cannot be called without. `start` and a search's `dir` are optional in the
# text protocol too, so requiring them here would make the arms differ in more than encoding.
_SCHEMA_REQUIRED = {
    "list_dir": ("dir",), "search": ("pattern",), "read_file": ("path",),
    "run_tests": ("target",), "write_patch": ("path", "old", "new"),
    "done": ("note",), "handoff": ("note",),
}


def schemas(withhold: tuple[str, ...] = (), add: tuple[str, ...] = ()) -> list[dict]:
    """The tool schemas for a policy that does not offer every tool.

    Mirrors `protocol()`: a withheld tool is not declared, so the model is never shown a tool it
    would then be refused.
    """
    names = [name for name in DEFAULT_TOOLS if name not in withhold]
    names += [name for name in add if name not in names]
    out = []
    for name in names:
        properties = {
            arg: {"type": _SCHEMA_ARGS[arg][0], "description": _SCHEMA_ARGS[arg][1]}
            for arg in ARG_NAMES[name]
        }
        out.append({
            "type": "function",
            "function": {
                "name": name,
                "description": _SCHEMA_DESC[name],
                "parameters": {
                    "type": "object",
                    "properties": properties,
                    "required": list(_SCHEMA_REQUIRED[name]),
                },
            },
        })
    return out


def from_tool_calls(calls: list[dict]) -> list[Action]:
    """Read structured calls as actions, without repairing them.

    Arguments that are not a JSON object, or whose values are not scalars, are dropped rather than
    coerced -- the point of the arm is to measure whether the model can drive the tools through its
    own interface, and a reader that patched up broken JSON would answer a different question.
    """
    out = []
    for call in calls:
        name = call.get("name") or ""
        if not name:
            continue
        args: dict[str, str] = {}
        try:
            parsed = json.loads(call.get("arguments") or "{}")
        except (json.JSONDecodeError, TypeError):
            parsed = None
        if isinstance(parsed, dict):
            for key, value in parsed.items():
                if not isinstance(value, (str, int, float, bool)):
                    continue
                # An empty value does not claim the name, which is the same rule the text reader
                # applies. Both arms must agree on it: this model fills an optional `dir` with ""
                # and the tools read a missing `dir` as the checkout root, so keeping the empty
                # string would make every function-calling search grep a path that does not exist
                # -- an arm broken by a convention rather than by the model.
                if value == "":
                    continue
                args[str(key)] = str(value)
        out.append(Action(
            tool=name, args=args,
            raw=json.dumps(call)[:2000], encodings=("function-call",),
        ))
    return out


def parse_all(text: str) -> list[Action]:
    """Every action in an assistant turn, in order.

    The main loop takes one per turn; the patch handoff takes all of them, because a fix
    that spans two files in one reply is a fix and not a protocol violation.
    """
    return [
        _action(tool, body)
        for tool, body in re.findall(
            r'<action\s+tool="([a-z_]+)"\s*>(.*?)</action>', text, flags=re.DOTALL
        )
    ]


# Which action decides what kind of step a turn was, when a turn contains several. Most
# consequential first: a turn that patched and then declared itself finished was a patch
# step, and calling it a "finish" step would move the patch cost out of the figure that
# bounds what role-based routing can save.
STEP_PRECEDENCE = ("patch", "verify", "handoff", "read", "search", "finish")


def parse(text: str) -> Action | None:
    """The action a turn is attributed to, when only one is wanted.

    The last one, because a model that reasons out loud sometimes writes an example of the
    syntax before committing to a call. Callers that execute a turn should use `parse_all`
    — the first real run showed a premium model emitting its patch and its `done` in one
    reply, and taking only the last silently threw the patch away and scored the model on
    having done nothing.
    """
    actions = parse_all(text)
    return actions[-1] if actions else None


def principal(actions: list[Action]) -> Action | None:
    """Which of a turn's actions the turn is recorded as."""
    if not actions:
        return None
    return min(
        actions,
        key=lambda a: (
            STEP_PRECEDENCE.index(a.step_type)
            if a.step_type in STEP_PRECEDENCE
            else len(STEP_PRECEDENCE)
        ),
    )


# The two tolerant encodings, in the order they are tried. Both are the same key/value pair in a
# tag rather than on a line, which is what `--tool-call-parser=qwen3_coder` trains a model to emit.
_PARAMETER_TAG = re.compile(r"<parameter=(\w+)\s*>(.*?)</parameter\s*>", re.DOTALL)
_ELEMENT_TAG = re.compile(r"<(\w+)\s*>(.*?)</\1\s*>", re.DOTALL)


def _action(tool: str, body: str) -> Action:
    """Read one action's arguments, recording which serialisation each arrived in.

    The rule across all four encodings is the same: **the first non-empty value for a name wins,
    and nothing is ever synthesised.** A name that ends up empty stays empty and the tool refuses
    it, because `pattern:` with nothing after it is the model failing to name a target and not a
    serialisation this reader should be forgiving about. See GRAMMAR_VERSION for why the tolerant
    encodings exist and what they are not allowed to do.
    """
    args: dict[str, str] = {}
    seen: list[str] = []

    def offer(key: str, value: str, encoding: str) -> None:
        # Empty does not claim the name, so a model that writes the skeleton and then the value in
        # its own dialect is read as it meant; a model that writes only the skeleton still fails.
        if not value or args.get(key):
            return
        args[key] = value
        if encoding not in seen:
            seen.append(encoding)

    # Heredoc first, so a patch body containing "path:" is not re-parsed as an argument.
    for key, value in re.findall(r"^(\w+):\s*<<<\n(.*?)\n>>>\s*$", body, flags=re.DOTALL | re.MULTILINE):
        offer(key, value, "heredoc")
    stripped = re.sub(r"^\w+:\s*<<<\n.*?\n>>>\s*$", "", body, flags=re.DOTALL | re.MULTILINE)

    # The canonical line form, which is what the protocol asks for and what every tier but one
    # sends. Tag bodies are excluded so `<parameter=pattern>\nfoo: bar\n</parameter>` does not
    # also read as a line called "foo".
    lines = _PARAMETER_TAG.sub("", _ELEMENT_TAG.sub("", stripped))
    empty_names: list[str] = []
    for line in lines.splitlines():
        match = re.match(r"^\s*(\w+):\s*(.*)$", line)
        if not match:
            continue
        value = _unquote(match.group(2).strip())
        if not value:
            empty_names.append(match.group(1))
        offer(match.group(1), value, "canonical")

    # The tolerant encodings, for this tool's own argument names only.
    allowed = ARG_NAMES.get(tool, ())
    for pattern, encoding in ((_PARAMETER_TAG, "parameter-tag"), (_ELEMENT_TAG, "element-tag")):
        for key, value in pattern.findall(stripped):
            if key in allowed:
                offer(key, value.strip("\n"), encoding)

    # A name written as an empty line and never supplied by any encoding is the model's failure,
    # and it is recorded as present-but-empty so the tool's own error can name it.
    for key in empty_names:
        args.setdefault(key, "")
    return Action(tool=tool, args=args, raw=body[:2000], encodings=tuple(seen))


def _unquote(value: str) -> str:
    """Strip a pair of surrounding quotes from a scalar argument.

    Models write `path: "requests/models.py"` about as often as they write it bare, and a
    path with quotes in it does not exist, so the edit is refused and the turn is wasted on
    the harness being literal about punctuation.
    """
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def _run(command: str, *, timeout: int) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["/bin/bash", "-lc", f"cd {TESTBED} && {CONDA} && {command}"],
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def _inside(path: str) -> Path:
    """Resolve a path under the checkout, refusing anything that leaves it.

    Not a security boundary — the container is the boundary. It stops an agent from
    reading the instance metadata mounted beside it, which contains the tests and the
    reference patch, and would turn the episode into a memorisation exercise.
    """
    resolved = (TESTBED / path).resolve()
    # `is_relative_to` rather than a string prefix, which would also accept a sibling
    # directory called `/testbed-something`. An absolute argument replaces the base
    # entirely under pathlib, so `/data/instance.json` lands here and is refused.
    if not resolved.is_relative_to(TESTBED):
        raise ValueError(f"{path} is outside the checkout")
    return resolved


def read_within(path: str, limit: int = 20_000) -> str:
    """A file from the checkout, for a caller outside the tool loop.

    Exists so nothing else has to join a path onto `TESTBED` by hand. The one place that
    did could be handed `/data/instance.json` — which holds the tests and the reference
    patch — and would have posted it to a model.
    """
    return _inside(path).read_text(errors="replace")[:limit]


# Anything that decides whether the suite runs, or what it reports. Not only test files:
# a `conftest.py` that skips everything makes pytest exit zero, which would read as a fix.
# The names are matched here and in `score.py` through this one function, because the two
# disagreeing means an edit the agent was allowed to make voids its own episode.
TEST_CONFIG_FILES = frozenset(
    {"conftest.py", "pytest.ini", "setup.cfg", "tox.ini", "pyproject.toml"}
)


def is_test_path(path: str) -> bool:
    name = path.rsplit("/", 1)[-1]
    return bool(
        re.search(r"(^|/)(tests?|testing)/", path)
        or re.match(r".*test_[^/]*\.py$", path)
        or re.match(r".*_test\.py$", path)
        or name in TEST_CONFIG_FILES
    )


# What a filled-in call looks like, per tool, for the error that says an argument is missing. A
# rejection that restates only the requirement ("search needs a pattern") leaves the model to guess
# at the syntax, and the guess it made was its own tool-calling dialect -- so the harness's error
# message pushed it further off contract than it started. The form is shown filled in rather than
# as a skeleton, because a skeleton is what it was already sending back empty.
_FILLED = {
    "list_dir": 'dir: astropy/io/ascii',
    "search": 'pattern: def _read_table',
    "read_file": 'path: astropy/io/ascii/qdp.py',
    "run_tests": 'target: astropy/io/ascii/tests/test_qdp.py',
    "write_patch": 'path: astropy/io/ascii/qdp.py\nold: <<<\n...the exact lines...\n>>>\nnew: <<<\n...what to put there...\n>>>',
    "done": 'note: the reader now accepts lower-case commands',
    "handoff": 'note: qdp.py line 62 upper-cases the command before matching',
}


def _needs(tool: str, what: str) -> Observation:
    """Refuse a call for a missing argument, and show the exact form that would work."""
    return Observation(
        f"{tool} needs {what}, and none was given. Reply with exactly this, filled in:\n"
        f'<action tool="{tool}">\n{_FILLED[tool]}\n</action>',
        ok=False,
    )


def execute(action: Action) -> Observation:
    """Carry out one action and describe what happened."""
    try:
        return _execute(action)
    except subprocess.TimeoutExpired:
        return Observation("the command did not finish in time", ok=False)
    except (OSError, ValueError) as exc:
        return Observation(f"{type(exc).__name__}: {exc}", ok=False)


def _execute(action: Action) -> Observation:
    args = action.args
    if action.tool == "list_dir":
        target = _inside(args.get("dir") or ".")
        if not target.is_dir():
            return Observation(f"{args.get('dir')} is not a directory", ok=False)
        names = sorted(
            (p.name + ("/" if p.is_dir() else "")) for p in target.iterdir()
            if not p.name.startswith(".")
        )
        return Observation("\n".join(names[:400]) or "(empty)")

    if action.tool == "search":
        pattern = args.get("pattern")
        if not pattern:
            return _needs("search", "a pattern")
        where = shlex.quote(args.get("dir") or ".")
        result = _run(
            f"grep -rn --include='*.py' -E {shlex.quote(pattern)} {where} | head -60",
            timeout=120,
        )
        return Observation(_clip(result.stdout) or "no match")

    if action.tool == "read_file":
        path = args.get("path")
        if not path:
            return _needs("read_file", "a path")
        target = _inside(path)
        if not target.is_file():
            return Observation(f"{path} is not a file", ok=False)
        lines = target.read_text(errors="replace").splitlines()
        start = max(1, int(args.get("start") or 1))
        window = lines[start - 1 : start - 1 + MAX_READ_LINES]
        numbered = "\n".join(f"{start + i:>6}  {line}" for i, line in enumerate(window))
        tail = (
            f"\n... {len(lines) - (start - 1 + len(window))} more lines"
            if start - 1 + len(window) < len(lines)
            else ""
        )
        return Observation(_clip(numbered) + tail)

    if action.tool == "run_tests":
        target = args.get("target")
        if not target:
            return _needs("run_tests", "a target")
        # `; exit ${PIPESTATUS[0]}` because the exit status is the verdict and a pipe
        # through `tail` would replace it with tail's own success.
        result = _run(
            f"{test_command(target)} 2>&1 | tail -60; exit ${{PIPESTATUS[0]}}",
            timeout=TEST_TIMEOUT_S,
        )
        return Observation(
            _clip(result.stdout), ok=True, tests_passed=_verdict(result.returncode)
        )

    if action.tool == "write_patch":
        return _write_patch(args)

    if action.tool in ("done", "handoff"):
        return Observation(args.get("note") or args.get("reason") or "")

    return Observation(
        f"there is no tool called {action.tool!r}; the tools are {sorted(STEP_TYPE)}. "
        'Call one of those, as <action tool="NAME">, with its arguments one per line.',
        ok=False,
    )


# Django ships no pytest and runs its suite through its own script, so `python -m pytest`
# answers "No module named pytest" on every Django image — which read as an instance this
# environment cannot score, and left the agent unable to test its own patch. Django is 46% of
# SWE-bench Verified, so that is not a corner to leave open. Detected from the checkout rather
# than from the instance name: what matters is what this repository actually runs.
DJANGO_RUNNER = "tests/runtests.py"
# Mirrors the official evaluation: an in-memory SQLite settings module, one process so the
# per-test lines are not interleaved, and verbosity 2 so there are per-test lines at all.
DJANGO_COMMAND = "./tests/runtests.py --verbosity 2 --settings=test_sqlite --parallel 1"


def _cached(fn):
    """One-shot memo. The answer is a property of the image, and asking costs a subprocess."""
    answer = {}

    def inner():
        if "value" not in answer:
            answer["value"] = fn()
        return answer["value"]

    inner.forget = answer.clear
    return inner


@_cached
def uses_django_runner() -> bool:
    return (
        (Path(TESTBED) / DJANGO_RUNNER).is_file()
        and _run("python -c 'import pytest'", timeout=120).returncode != 0
    )


def django_label(target: str) -> str:
    """A pytest-shaped target as Django's runner wants it: a dotted label under `tests/`.

    Models write `tests/queries/tests.py` because that is what the repository looks like, and
    the runner wants `queries.tests`. Translating is better than refusing: the alternative is
    an arm that cannot run a test on the repository that is nearly half the corpus.
    """
    path, _, rest = target.strip().partition("::")
    if path.endswith(".py"):
        path = path[: -len(".py")]
    label = ".".join(part for part in (path.strip("/").replace("/", "."), *rest.split("::")) if part)
    for prefix in ("tests.", "."):
        if label.startswith(prefix):
            label = label[len(prefix) :]
    return label


def test_command(target: str) -> str:
    """How this repository runs the tests it already has, for one target."""
    if uses_django_runner():
        return f"{DJANGO_COMMAND} {shlex.quote(django_label(target))}"
    return f"python -m pytest {shlex.quote(target)} -x -q"


def _verdict(returncode: int) -> bool | None:
    """What a pytest exit status says about the code, including when it says nothing.

    pytest's own codes, and the distinction matters because the first escalation trigger
    reads this: 0 is a pass, 1 is a failure, 5 is "collected nothing". A target that
    matched no test has said nothing about correctness, and reporting that as a failure
    would escalate an episode on the agent having mistyped a path.

    Read from the status rather than the text, because a suite reporting `1 xfailed`
    contains the word "failed" and passed.
    """
    if returncode == 0:
        return True
    # 5 is "collected nothing" and 4 is "the command line was wrong". Neither says anything
    # about the code, and reporting either as a failure escalates an episode on the agent
    # having mistyped a path.
    if returncode in (4, 5):
        return None
    return False


def _write_patch(args: dict[str, str]) -> Observation:
    path, old, new = args.get("path"), args.get("old"), args.get("new")
    if not path or old is None or new is None:
        return _needs("write_patch", "path, old and new")
    # A block that was opened and never closed leaves the marker itself as the value, and
    # applying that writes `<<<` into the repository: one episode replaced a method definition
    # in Django's query.py with it, and every test then failed to import. The usual cause is a
    # turn cut off at the output limit, so the refusal says so.
    for name, value in (("old", old), ("new", new)):
        if value.strip() in ("<<<", ">>>"):
            return Observation(
                f"the {name} block was opened with <<< and never closed with >>>, so there is "
                "nothing to apply. Send it again — and if the turn was cut off at the output "
                "limit, send a smaller edit.",
                ok=False,
            )
    if is_test_path(path):
        # Refused here as well as failed at scoring time. The scorer is the guarantee;
        # this is so a model that tries it is told, rather than discovering at the end
        # that the episode was void.
        return Observation(
            f"{path} is a test file. Editing the tests fails the task — fix the library "
            "instead.",
            ok=False,
        )
    target = _inside(path)
    if not target.is_file():
        return Observation(f"{path} is not a file", ok=False)
    text = target.read_text(errors="replace")
    occurrences = text.count(old)
    if occurrences == 0:
        return Observation(
            "that exact block is not in the file — whitespace and indentation have to "
            "match. Read the region again and copy it.",
            ok=False,
        )
    if occurrences > 1:
        return Observation(
            f"that block appears {occurrences} times, so the edit is ambiguous. Include "
            "more surrounding lines.",
            ok=False,
        )
    target.write_text(text.replace(old, new))
    return Observation(f"{path} updated")


def current_diff() -> str:
    """The agent's edits, as the patch the scorer will be handed.

    Tracked files only. An earlier version ran `git add -A -N` first, to catch new files —
    and swept in the untracked `build/` tree that ships inside several of these images,
    producing an 867 KB "patch" that could not be applied to anything. The tool set cannot
    create a file (`write_patch` requires one that exists), so tracked modifications are
    exactly the agent's work.
    """
    return _run("git diff", timeout=120).stdout


def _clip(text: str) -> str:
    if len(text) <= MAX_OUTPUT_CHARS:
        return text
    half = MAX_OUTPUT_CHARS // 2
    return f"{text[:half]}\n... [{len(text) - MAX_OUTPUT_CHARS} characters cut] ...\n{text[-half:]}"
