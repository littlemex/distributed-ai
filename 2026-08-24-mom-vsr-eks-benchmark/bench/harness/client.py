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


@dataclass
class Call:
    """The full record of one request. Written to JSONL as-is."""

    arm: str
    requested_model: str
    question_id: str
    dataset: str
    category: str
    fold: str

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
                timeout=aiohttp.ClientTimeout(total=timeout_s),
            ) as response:
                record.http_status = response.status
                record.headers = {
                    key: response.headers.get(header, "")
                    for key, header in VSR_HEADERS.items()
                    if response.headers.get(header) is not None
                }
                if response.status == 200 and stream:
                    await _consume_stream(record, response, started)
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
                    if response.status == 400 and "reasoning_effort" in payload_text:
                        record.arm_unsupported = True
                    return record

                _fill_from_payload(record, payload_text)
                record.error = None
                return record

        except (aiohttp.ClientError, asyncio.TimeoutError) as exc:
            record.latency_ms = (time.perf_counter() - started) * 1000
            record.error = f"{type(exc).__name__}: {exc}"[:500]
            if attempt < max_attempts:
                await asyncio.sleep(backoff)
                backoff *= 2
                continue
            return record

    return record


async def _consume_stream(record: Call, response: Any, started: float) -> None:
    """Read an SSE stream, timing the visible content and keeping the usage chunk.

    Streaming is not a preference here. The gateway caps a non-streaming read at 50
    seconds so that a slow call fails as a parseable error rather than as the CDN's
    HTML timeout, and a high reasoning effort exceeds that: one probe spent 4,093
    tokens thinking over 45 seconds and a larger budget was cut outright. Bytes
    flowing keep the window open per read, so this path is the only one on which the
    top of the effort dial can be measured at all.
    """
    import json

    parts: list[str] = []
    chunks = 0
    async for raw in response.content:
        line = raw.decode("utf-8", "replace").strip()
        if not line.startswith("data:"):
            continue
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
                # A role-only or reasoning-only delta. Deliberately not counted as
                # first content: for a reasoning arm the thinking happens before any
                # visible token, and calling that moment "time to first token" would
                # report a number no reader ever experiences.
                continue
            now = (time.perf_counter() - started) * 1000
            if record.ttft_ms is None:
                record.ttft_ms = now
            record.last_content_ms = now
            chunks += 1
            parts.append(piece)

    record.stream_close_ms = (time.perf_counter() - started) * 1000
    record.latency_ms = record.stream_close_ms
    record.content_chunks = chunks
    record.text = "".join(parts)
    if not parts:
        # Ran out of budget while thinking, which is an outcome of this arm at this
        # budget rather than a transport failure.
        record.error = None


def _fill_from_payload(record: Call, payload_text: str) -> None:
    import json

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
