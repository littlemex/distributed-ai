"""One call to the router, recorded as one row.

Every arm — a pinned member and a routed request alike — goes through the same
function against the same address, so the two differ only in the model name in
the body. That is the point: a baseline that skipped the router would be
measuring a different data path and could not be subtracted from a routed run.

The routing decision comes back in response headers rather than the body, so
they are recorded verbatim. `x-vsr-response-path` matters most: a cache hit
would otherwise be indistinguishable from a model call, with a latency and a
cost that belong to neither.
"""

from __future__ import annotations

import asyncio
import json
import time
from dataclasses import asdict, dataclass, field
from typing import Any

import aiohttp

VSR_HEADERS = {
    "vsr_selected_model": "x-vsr-selected-model",
    "vsr_selected_decision": "x-vsr-selected-decision",
    "vsr_selected_confidence": "x-vsr-selected-confidence",
    "vsr_selected_algorithm": "x-vsr-selected-algorithm",
    "vsr_response_path": "x-vsr-response-path",
    "vsr_injected_system_prompt": "x-vsr-injected-system-prompt",
}

# A response that is not the model's answer. Retried because the model was never
# reached, so a retry is not a second sample of the same question.
RETRYABLE_STATUS = frozenset({408, 425, 429, 500, 502, 503, 504})

# How a provider spells "I do not take that effort level". Matched on a 400 only, and
# on more than one spelling on purpose: the harness retires an arm on this signal, so
# a spelling it fails to recognise means paying the same 400 once per question for the
# rest of the run. The names are matched, not the surrounding prose, because prose is
# what changes between providers.
EFFORT_REJECTION_MARKERS = (
    "reasoning_effort",
    "reasoning.effort",
    "reasoningeffort",
    "reasoning effort",
    "thinking.budget",
)

# Without a named parameter to go on, the field being mentioned is not enough: a 400
# that lists the accepted fields mentions it too, and retiring an arm on that would
# throw away a working one. The body has to say the field was refused.
REFUSAL_WORDS = (
    "unsupported",
    "not supported",
    "does not support",
    "not accept",
    "unrecognized",
    "unrecognised",
    "unknown",
    "invalid",
    "must be",
    "not allowed",
)


def rejected_the_effort_level(payload_text: str, status: int) -> bool:
    """Whether this 400 says the arm's effort level does not exist.

    Two ways to be wrong, both expensive. Too narrow and the harness pays the same
    400 once per remaining question for an arm that no longer exists. Too wide and it
    retires an arm that is alive, which deletes a row of the matrix and cannot be
    noticed in the output. So the provider's own named parameter decides when there is
    one, and otherwise the body has to both name the field and say it was refused.
    """
    if status != 400:
        return False
    lowered = payload_text.lower()
    try:
        payload = json.loads(payload_text)
    except (json.JSONDecodeError, TypeError):
        payload = None
    if isinstance(payload, dict):
        error = payload.get("error")
        named = ""
        if isinstance(error, dict):
            named = str(error.get("param") or error.get("parameter") or "")
        if named:
            return any(marker in named.lower() for marker in EFFORT_REJECTION_MARKERS)
    names_the_field = any(marker in lowered for marker in EFFORT_REJECTION_MARKERS)
    says_refused = any(word in lowered for word in REFUSAL_WORDS)
    return names_the_field and says_refused


@dataclass
class Call:
    """The full record of one request. Written to JSONL as-is."""

    arm: str
    requested_model: str
    question_id: str
    dataset: str
    category: str
    fold: str

    # What was asked for, recorded on the row rather than inferred from the arm name.
    # Two arms can share a name across runs — a default-effort arm in v2 is spelled
    # exactly as the same member was in v1 — while having been measured on a
    # different path, with a different budget. Without these fields a resumed or
    # concatenated file mixes the two and nothing downstream can tell.
    requested_effort: str | None = None
    stream: bool = False
    max_tokens: int | None = None
    temperature: float | None = None
    # Recorded because it decides where a slow call gets censored, and a file whose
    # slow arms were cut at different points has a truncation and failure profile
    # that is a function of when it was collected.
    stream_idle_s: float | None = None

    started_at: float = 0.0
    latency_ms: float = 0.0
    http_status: int | None = None
    attempts: int = 0
    error: str | None = None
    # Set when the provider rejected the arm's own configuration, which means the arm
    # is gone rather than this call having failed.
    arm_unsupported: bool = False

    # Streaming timings, all measured from the moment the request was sent. Separated
    # because they answer different questions and get conflated otherwise: `E2E /
    # output tokens` is not a per-token decode rate, it is an amortised latency that
    # has queueing, prefill and hidden thinking folded into it.
    ttft_ms: float | None = None          # first chunk carrying visible content
    last_content_ms: float | None = None  # last chunk carrying visible content
    stream_close_ms: float | None = None  # connection closed, usage chunk included
    content_chunks: int | None = None

    text: str | None = None
    finish_reason: str | None = None
    served_model: str | None = None
    prompt_tokens: int | None = None
    completion_tokens: int | None = None
    total_tokens: int | None = None
    reasoning_tokens: int | None = None

    headers: dict[str, str] = field(default_factory=dict)

    # Filled in by the scorer, not the client.
    extracted: str | None = None
    correct: bool | None = None

    @property
    def visible_tpot_ms(self) -> float | None:
        """Mean gap between visible tokens, or None when it is not defined.

        Uses reported completion tokens rather than chunk count, because a chunk may
        carry several tokens and counting chunks would make this a property of the
        provider's flushing rather than of its decode rate. For a reasoning arm the
        thinking is inside TTFT, so this measures only the visible tail — which is what
        a reader experiences, and not comparable across arms as "generation speed".
        """
        if self.ttft_ms is None or self.last_content_ms is None:
            return None
        visible = (self.completion_tokens or 0) - (self.reasoning_tokens or 0)
        if visible < 2:
            return None
        return (self.last_content_ms - self.ttft_ms) / (visible - 1)

    def to_json(self) -> dict[str, Any]:
        out = asdict(self)
        out["visible_tpot_ms"] = self.visible_tpot_ms
        return out


async def call_once(
    session: aiohttp.ClientSession,
    url: str,
    *,
    stream: bool = False,
    arm: str,
    model: str,
    prompt: str,
    item_id: str,
    dataset: str,
    category: str,
    fold: str,
    max_tokens: int,
    temperature: float | None,
    reasoning_effort: str | None = None,
    max_attempts: int = 3,
    timeout_s: float = 300.0,
    stream_idle_s: float = 90.0,
    stream_first_event_s: float = 600.0,
    stream_ceiling_s: float = 1800.0,
    extra_headers: dict[str, str] | None = None,
) -> Call:
    """POST one chat completion and return its record.

    Retries only transport failures and the statuses that mean the model was
    never reached. A 4xx that the model produced (a refusal, a context overflow)
    is kept as the answer it is: retrying it would quietly resample a question
    that other arms only got one attempt at.
    """
    record = Call(
        arm=arm,
        requested_model=model,
        question_id=item_id,
        dataset=dataset,
        category=category,
        fold=fold,
        requested_effort=reasoning_effort,
        stream=stream,
        max_tokens=max_tokens,
        temperature=temperature,
        stream_idle_s=stream_idle_s if stream else None,
    )
    body = {
        "model": model,
        "max_tokens": max_tokens,
        "messages": [{"role": "user", "content": prompt}],
    }
    # Sent only when asked for. This pool cannot agree on a temperature: Claude 5
    # rejects the field as deprecated, GPT-5.6 accepts only its default of 1, and
    # the rest accept 0. Since no single value is legal everywhere, the harness
    # sends none and every member decodes at its own default. That costs
    # determinism, and the alternative — a different value per member — would cost
    # comparability, which is the thing being measured.
    if temperature is not None:
        body["temperature"] = temperature
    # Passed through by the gateway to the provider. Omitted entirely for the default
    # arm, because "no field" is a distinct setting from any value and is the only one
    # the whole pool accepts.
    if reasoning_effort is not None:
        body["reasoning_effort"] = reasoning_effort
    if stream:
        body["stream"] = True
        # Asked for explicitly. The gateway injects this itself for its own accounting
        # and then swallows the terminal usage-only chunk unless the caller wanted it —
        # so requesting it is what makes token counts available to the client, and
        # counts are what keep a per-token timing from becoming a count of chunks.
        body["stream_options"] = {"include_usage": True}
    headers = {"content-type": "application/json", **(extra_headers or {})}

    # On the streaming path a total deadline would cut exactly the arms this
    # benchmark exists to price — a high reasoning effort against a large budget
    # legitimately runs for minutes — and a cut connection is billed by the provider
    # for every token it had already generated. So the streaming deadline is a
    # watchdog on *progress*, enforced inside `_consume_stream`, plus a loose ceiling
    # that stops one call from holding a concurrency slot forever.
    #
    # Neither half is expressible as `sock_read`, which is why it is not used: a
    # keep-alive comment is a byte arriving, so a hung upstream that pings would look
    # alive, and the first body byte legitimately takes minutes on a provider that
    # buffers its thinking, so a per-read deadline would kill the slowest arms.
    timeout = (
        aiohttp.ClientTimeout(total=stream_ceiling_s, sock_connect=30.0)
        if stream
        else aiohttp.ClientTimeout(total=timeout_s)
    )

    backoff = 1.0
    record.started_at = time.time()
    for attempt in range(1, max_attempts + 1):
        record.attempts = attempt
        started = time.perf_counter()
        try:
            async with session.post(
                url,
                json=body,
                headers=headers,
                timeout=timeout,
            ) as response:
                record.http_status = response.status
                record.headers = {
                    key: response.headers.get(header, "")
                    for key, header in VSR_HEADERS.items()
                    if response.headers.get(header) is not None
                }
                if response.status == 200 and stream:
                    await _consume_stream(
                        record,
                        response,
                        started,
                        idle_s=stream_idle_s,
                        first_event_s=stream_first_event_s,
                    )
                    # A stream that closed is this arm's answer, including an empty
                    # one from an arm that spent the whole budget thinking. Cleared
                    # explicitly because an earlier attempt may have left an error.
                    record.error = None
                    return record

                payload_text = await response.text()
                record.latency_ms = (time.perf_counter() - started) * 1000

                if response.status in RETRYABLE_STATUS and attempt < max_attempts:
                    record.error = f"http {response.status}: {payload_text[:200]}"
                    await asyncio.sleep(backoff)
                    backoff *= 2
                    continue

                if response.status != 200:
                    record.error = f"http {response.status}: {payload_text[:500]}"
                    # A provider refusing this effort level is the arm ceasing to
                    # exist, not a question going unanswered. Flagged so the analysis
                    # drops the arm rather than scoring it on a subset.
                    record.arm_unsupported = rejected_the_effort_level(
                        payload_text, response.status
                    )
                    return record

                _fill_from_payload(record, payload_text)
                record.error = None
                return record

        except (aiohttp.ClientError, asyncio.TimeoutError) as exc:
            record.latency_ms = (time.perf_counter() - started) * 1000
            record.error = f"{type(exc).__name__}: {exc}"[:500]
            # A stream that had already produced tokens was billed for them. Asking
            # again would pay for the same generation a second time, and the retry is
            # a second sample of a question every other arm was asked once, so the
            # partial answer is kept as the outcome it is.
            if record.ttft_ms is not None or record.text:
                record.error = f"broken mid-stream: {record.error}"[:500]
                return record
            # A deadline says nothing about whether the provider did the work. It
            # very likely did and billed for it, so asking again pays twice — and it
            # would give this question a second sample that no other arm got. Only a
            # connection-level failure with nothing produced is retried.
            if isinstance(exc, asyncio.TimeoutError):
                record.error = f"deadline: {record.error}"[:500]
                return record
            if attempt < max_attempts:
                await asyncio.sleep(backoff)
                backoff *= 2
                continue
            return record

    return record


async def _consume_stream(
    record: Call,
    response: Any,
    started: float,
    *,
    idle_s: float = 90.0,
    first_event_s: float = 600.0,
) -> None:
    """Read an SSE stream, timing the visible content and keeping the usage chunk.

    Streaming is not a preference here. The gateway caps a non-streaming read at 50
    seconds so that a slow call fails as a parseable error rather than as the CDN's
    HTML timeout, and a high reasoning effort exceeds that: one probe spent 4,093
    tokens thinking over 45 seconds and a larger budget was cut outright. So this
    path is the only one on which the top of the effort dial can be measured at all.

    The two deadlines here are different quantities on purpose. `first_event_s` is
    generous because a provider that buffers its thinking sends nothing at all while
    the arm does the work being measured; cutting there would delete the arm and bill
    for it. `idle_s` starts once the stream has said something, and is measured
    between *events*, not between bytes: a keep-alive comment is a byte arriving, so
    a byte-level deadline would treat a hung upstream as a healthy one.

    Whatever arrived before an exception stays on the record. A broken stream was
    still generated and billed, so the fragment is the evidence of what was paid for.
    """
    parts: list[str] = []
    seen_event = False
    last_progress = time.perf_counter()

    def _window() -> float:
        limit = idle_s if seen_event else first_event_s
        return limit - (time.perf_counter() - last_progress)

    try:
        while True:
            window = _window()
            if window <= 0:
                raise asyncio.TimeoutError(
                    "stream produced no event for "
                    f"{idle_s if seen_event else first_event_s:.0f}s"
                )
            raw = await asyncio.wait_for(
                response.content.readline(), timeout=window
            )
            if not raw:
                break
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                # A comment or a keep-alive. Deliberately not progress: counting it
                # would make a silent upstream indistinguishable from a working one.
                continue
            seen_event = True
            last_progress = time.perf_counter()
            data = line[5:].strip()
            if data == "[DONE]":
                continue
            try:
                event = json.loads(data)
            except json.JSONDecodeError:
                continue

            usage = event.get("usage")
            if usage:
                record.prompt_tokens = usage.get("prompt_tokens")
                record.completion_tokens = usage.get("completion_tokens")
                record.total_tokens = usage.get("total_tokens")
                details = usage.get("completion_tokens_details") or {}
                record.reasoning_tokens = details.get("reasoning_tokens")
            if event.get("model"):
                record.served_model = event["model"]

            for choice in event.get("choices") or []:
                if choice.get("finish_reason"):
                    record.finish_reason = choice["finish_reason"]
                piece = (choice.get("delta") or {}).get("content")
                if not piece:
                    # A role-only or reasoning-only delta. Deliberately not counted
                    # as first content: for a reasoning arm the thinking happens
                    # before any visible token, and calling that moment "time to
                    # first token" would report a number no reader experiences.
                    continue
                now = (time.perf_counter() - started) * 1000
                if record.ttft_ms is None:
                    record.ttft_ms = now
                record.last_content_ms = now
                parts.append(piece)
    finally:
        # Written in `finally` so that a stream broken half way still carries what it
        # produced: those tokens were generated and billed, and the fragment is the
        # only record of what the money bought.
        record.stream_close_ms = (time.perf_counter() - started) * 1000
        record.latency_ms = record.stream_close_ms
        record.content_chunks = len(parts)
        record.text = "".join(parts)


def _fill_from_payload(record: Call, payload_text: str) -> None:
    try:
        payload = json.loads(payload_text)
    except json.JSONDecodeError as exc:
        record.error = f"undecodable body: {exc}"
        return

    record.served_model = payload.get("model")
    usage = payload.get("usage") or {}
    record.prompt_tokens = usage.get("prompt_tokens")
    record.completion_tokens = usage.get("completion_tokens")
    record.total_tokens = usage.get("total_tokens")
    details = usage.get("completion_tokens_details") or {}
    record.reasoning_tokens = details.get("reasoning_tokens")

    choices = payload.get("choices") or []
    if not choices:
        record.error = "no choices in response"
        return
    choice = choices[0]
    record.finish_reason = choice.get("finish_reason")
    message = choice.get("message") or {}
    content = message.get("content")
    if content in (None, "") and message.get("reasoning_content"):
        # A model that spent its whole budget thinking. Kept, not retried: the
        # empty answer is the outcome of this decoding config.
        content = ""
    record.text = content
