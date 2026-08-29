"""One model call, from inside the evaluation image, on the standard library only.

The episode runs inside the official SWE-bench image, and installing packages into it
would change the environment the result is attributed to. So this speaks HTTP with
`http.client` rather than aiohttp, and the streaming path is hand-rolled.

Streaming is not a preference. The gateway caps a non-streaming read at 50 seconds so a
slow call fails as a parseable error instead of as a CDN timeout page, and a premium model
thinking about a patch exceeds that easily. It is also the only path on which the usage
block arrives with the cache split, and the cache split is most of the bill in a session
this long.

The deadline is a watchdog on *progress*, and progress means an SSE event rather than a
byte. A keep-alive comment is a byte arriving, so a byte-level deadline treats a hung
upstream as a healthy one; and the first event legitimately takes minutes on a provider
that buffers its thinking, so the wait for it gets its own, longer window. This mirrors
`bench/harness/client.py`, which learned both of those the expensive way.
"""

from __future__ import annotations

import http.client
import json
import socket
import ssl
import time
from dataclasses import dataclass, field
from urllib.parse import urlparse

# A response that is not the model's answer: the model was never reached, so asking again
# is not a second sample of the same step.
RETRYABLE_STATUS = frozenset({408, 425, 429, 500, 502, 503, 504})


class Unreachable(RuntimeError):
    """The call failed in a way that leaves the episode unable to continue.

    It carries what the failed attempts were billed. Raising without them meant an episode
    that died on its last retry lost every attempt's cost from the totals — and the tier
    with the strictest rate limits is the premium one, so the loss was not evenly spread.
    """

    def __init__(self, message: str, billed: list[dict] | None = None) -> None:
        super().__init__(message)
        self.billed = billed or []


@dataclass
class Reply:
    """What one call produced and what it will be billed for."""

    model: str
    text: str = ""
    finish_reason: str | None = None
    served_model: str | None = None

    # Billed quantities, kept apart because they have four different prices and a prompt
    # token whose cache state is unknown cannot be priced at all.
    prompt_tokens: int = 0
    cached_prompt_tokens: int = 0
    cache_write_tokens: int = 0
    completion_tokens: int = 0
    reasoning_tokens: int = 0

    latency_ms: float = 0.0
    ttft_ms: float | None = None
    attempts: int = 0
    http_status: int | None = None
    error: str | None = None

    # Usage from attempts that were abandoned and retried. They were billed, so dropping
    # them would under-report exactly the tiers whose streams break most often — which
    # makes an unreliable cheap tier look cheaper than it is.
    abandoned: list[dict] = field(default_factory=list)
    # Set when the cost of this call is an approximation rather than the provider's own
    # figure, which happens when a stream breaks before the usage chunk.
    estimated: bool = False
    # Structured calls, when the request declared tools. Accumulated from the stream rather
    # than read whole: a tool call arrives as fragments of its own JSON arguments, and taking
    # only the first fragment yields a call whose arguments are half a JSON object.
    tool_calls: list[dict] = field(default_factory=list)

    @property
    def fresh_prompt_tokens(self) -> int:
        """Prompt tokens re-read at full price, and neither cached nor stored.

        The gateway normalises to the OpenAI convention, where `prompt_tokens` is the
        whole input: fresh plus cache reads plus what was written to the cache. So both
        of the other two are subtracted, because `call_cost` charges cache writes on
        their own line and counting them here as well bills the same token twice — and it
        would do so only on the long-lived threads, which is the baseline.

        Clamped at zero: a provider that changes its mind about the convention must not
        be able to produce a negative bill.
        """
        return max(0, self.prompt_tokens - self.cached_prompt_tokens - self.cache_write_tokens)

    @property
    def priced(self) -> bool:
        """Whether the provider told us what this call cost.

        Usage arrives only in the terminal chunk, so a stream that broke half way reports
        nothing — and a call priced at zero is a free step that also slips past the spend
        ceiling. Long streams break more often, which means the arms that think longest
        would be the ones discounted.
        """
        return self.prompt_tokens > 0 or self.completion_tokens > 0

    def estimate_usage(self, request_chars: int, cached_share: float | None = None) -> None:
        """Fill in an approximation when the provider never reported one.

        Four characters to a token, which is a convention rather than a measurement, so the
        row is flagged and the episode says how much of its bill was estimated. The
        alternative — leaving it at zero — is not a smaller error, it is a wrong number that
        looks exact.

        `cached_share` is the share of input the same tier served from cache on its last
        *reported* call. Without it the whole prompt would be priced as fresh, which is ten
        times the cache price and would fall hardest on the long-lived premium thread — the
        baseline — because that is exactly where streams are longest and break most.
        """
        if self.priced:
            return
        self.prompt_tokens = max(1, request_chars // 4)
        if cached_share:
            self.cached_prompt_tokens = int(self.prompt_tokens * min(1.0, cached_share))
        self.completion_tokens = max(0, len(self.text) // 4)
        self.estimated = True

    @property
    def usage_anomaly(self) -> str | None:
        """A usage block that cannot be priced as it stands.

        Reasoning tokens reported outside the completion count would silently under-charge
        a reasoning arm, which is the baseline. Flagged rather than corrected, because
        guessing at a provider's convention is how a cost column becomes fiction.
        """
        if self.reasoning_tokens > self.completion_tokens:
            return (
                f"reasoning_tokens {self.reasoning_tokens} exceeds completion_tokens "
                f"{self.completion_tokens}: this provider reports thinking outside the "
                "completion count and the output charge is too low"
            )
        return None


@dataclass
class Endpoint:
    """Where to call and with what key. One object so a policy can only change the model."""

    url: str
    api_key: str | None = None
    connect_timeout_s: float = 30.0
    # Waiting for the first event is waiting for the model to think, which is the work
    # being measured. Cutting there deletes the step and pays for it anyway.
    first_event_s: float = 900.0
    idle_s: float = 120.0
    # A loose backstop so one wedged call cannot hold an episode open forever.
    ceiling_s: float = 2400.0
    # Five attempts with doubling backoff from two seconds is about half a minute of
    # patience. Three attempts over three seconds was not enough: the premium tier is the
    # one with the strictest rate limits, so a short-tempered retry policy quietly deletes
    # premium episodes and calls it a quality result.
    max_attempts: int = 5
    backoff_s: float = 2.0
    # "chat" for /v1/chat/completions, "responses" for the OpenAI Responses API. The second exists
    # for one reason: this gateway refuses function tools together with any reasoning_effort other
    # than "none" on chat completions, and gpt-5.6-terra's text arm ran at "high" with 63.3% of its
    # output tokens being reasoning. Comparing protocols on a model whose reasoning had to be
    # switched off compares two things at once, so the arm that keeps reasoning needs this wire.
    api: str = "chat"

    def connect(self) -> http.client.HTTPConnection:
        parsed = urlparse(self.url)
        host, port = parsed.hostname, parsed.port
        if parsed.scheme == "https":
            return http.client.HTTPSConnection(
                host, port or 443, timeout=self.connect_timeout_s,
                context=ssl.create_default_context(),
            )
        return http.client.HTTPConnection(host, port or 80, timeout=self.connect_timeout_s)

    @property
    def path(self) -> str:
        return urlparse(self.url).path or "/v1/chat/completions"


def complete(
    endpoint: Endpoint,
    *,
    model: str,
    messages: list[dict],
    max_tokens: int,
    reasoning_effort: str | None = None,
    tool_schemas: list[dict] | None = None,
    template_kwargs: dict | None = None,
) -> Reply:
    """Send one chat completion and stream it back.

    Retries only what means the model was never reached. A stream that produced anything
    is never retried: those tokens were generated and billed, and asking again buys the
    step a second attempt that no other policy's step got.
    """
    body = json.dumps(
        _responses_body(model, messages, max_tokens, reasoning_effort, tool_schemas)
        if endpoint.api == "responses"
        else {
            "model": model,
            "messages": messages,
            "max_tokens": max_tokens,
            "stream": True,
            # The gateway injects this for its own accounting and then swallows the
            # terminal usage-only chunk unless the caller asked for it, so asking is what
            # makes the cache split visible here.
            "stream_options": {"include_usage": True},
            **({"reasoning_effort": reasoning_effort} if reasoning_effort else {}),
            **({"tools": tool_schemas, "tool_choice": "auto"} if tool_schemas else {}),
            # vLLM's own knob, overriding whatever the server was started with.
            **({"chat_template_kwargs": template_kwargs} if template_kwargs else {}),
        }
    ).encode()
    headers = {"content-type": "application/json"}
    if endpoint.api_key:
        headers["authorization"] = f"Bearer {endpoint.api_key}"

    backoff = endpoint.backoff_s
    billed: list[dict] = []
    for attempt in range(1, endpoint.max_attempts + 1):
        reply = Reply(model=model, attempts=attempt)
        started = time.perf_counter()
        connection = endpoint.connect()
        try:
            connection.request("POST", endpoint.path, body=body, headers=headers)
            response = connection.getresponse()
            reply.http_status = response.status
            if response.status != 200:
                detail = response.read(2000).decode("utf-8", "replace")
                reply.error = f"http {response.status}: {detail[:500]}"
                if response.status in RETRYABLE_STATUS and attempt < endpoint.max_attempts:
                    # The provider's own figure when it gives one: guessing shorter than
                    # asked is how a 429 becomes a permanent failure.
                    told = response.getheader("retry-after")
                    wait = backoff
                    if told:
                        try:
                            wait = max(backoff, min(60.0, float(told)))
                        except ValueError:
                            pass
                    time.sleep(wait)
                    backoff *= 2
                    continue
                raise Unreachable(reply.error, billed)
            _consume(reply, connection, response, started, endpoint)
            if not reply.text and not reply.error and not reply.priced:
                # A 200 that carried no content, no finish reason and no usage block. Whatever
                # went wrong is on the far side, and treating it as the model's turn is worse
                # than useless: the loop reads an empty reply as a malformed answer, charges an
                # approximation for it, and asks again, which is how one episode spent
                # thirty turns and most of its budget on nothing.
                reply.error = "the provider answered 200 with an empty stream"
            if reply.error and reply.text == "":
                # No visible content, so nothing was sampled and a retry is not a second
                # attempt at the step. But the prompt was read and any thinking was done,
                # so the usage is carried into the next attempt rather than dropped.
                billed.append(_billed(reply, len(body)))
                if attempt >= endpoint.max_attempts:
                    # Every attempt came back empty. Ending the episode says so; returning the
                    # last empty reply would file a provider failure as a model that could not
                    # follow the format.
                    raise Unreachable(reply.error, billed)
                time.sleep(backoff)
                backoff *= 2
                continue
            reply.abandoned = billed
            return reply
        except (OSError, http.client.HTTPException) as exc:
            reply.latency_ms = (time.perf_counter() - started) * 1000
            reply.error = f"{type(exc).__name__}: {exc}"[:500]
            if reply.text:
                # Billed and partly delivered. Kept as the step's outcome.
                reply.abandoned = billed
                return reply
            if attempt >= endpoint.max_attempts:
                raise Unreachable(reply.error, billed) from exc
            billed.append(_billed(reply, len(body)))
            time.sleep(backoff)
            backoff *= 2
        finally:
            connection.close()

    raise Unreachable("exhausted attempts without a reply", billed)


def _billed(reply: Reply, request_chars: int = 0) -> dict:
    """What an abandoned attempt is still owed for.

    An attempt that broke before the usage chunk reports nothing, and reporting nothing is
    reporting zero. Approximated from the request when that happens, for the same reason the
    final attempt is.
    """
    if not reply.priced and request_chars:
        reply.estimate_usage(request_chars)
    return {
        "fresh_in": reply.fresh_prompt_tokens,
        "cache_read": reply.cached_prompt_tokens,
        "cache_write": reply.cache_write_tokens,
        "out": reply.completion_tokens,
        "error": reply.error,
    }


def _consume(
    reply: Reply,
    connection: http.client.HTTPConnection,
    response: http.client.HTTPResponse,
    started: float,
    endpoint: Endpoint,
) -> None:
    """Read the SSE stream, keeping whatever arrived if it breaks half way."""
    parts: list[str] = []
    seen_event = False
    last_progress = time.perf_counter()
    try:
        while True:
            elapsed = time.perf_counter() - started
            if elapsed > endpoint.ceiling_s:
                raise socket.timeout(f"stream exceeded the {endpoint.ceiling_s:.0f}s ceiling")
            limit = endpoint.idle_s if seen_event else endpoint.first_event_s
            window = limit - (time.perf_counter() - last_progress)
            if window <= 0:
                raise socket.timeout(f"no SSE event for {limit:.0f}s")
            if connection.sock is not None:
                # Set per read, so the window shrinks as it is consumed rather than
                # resetting on every byte that happens to arrive.
                connection.sock.settimeout(min(window, endpoint.ceiling_s - elapsed))
            raw = response.readline()
            if not raw:
                break
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                # A comment or keep-alive. Deliberately not progress.
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
            if event.get("error"):
                # A gateway that fails after the headers are out cannot use a status code, so
                # it streams the failure as an event instead. Ignoring that field is how a
                # provider-side refusal arrives as a 200 with nothing in it, and how the first
                # astropy episode charged thirty premium turns for empty replies.
                detail = event["error"]
                message = detail.get("message") if isinstance(detail, dict) else detail
                reply.error = f"error event: {str(message)[:300]}"
            if event.get("model"):
                reply.served_model = event["model"]
            if event.get("usage"):
                _usage(reply, event["usage"])
            if endpoint.api == "responses":
                _responses_event(reply, event, started, parts)
                continue
            for choice in event.get("choices") or []:
                if choice.get("finish_reason"):
                    reply.finish_reason = choice["finish_reason"]
                for fragment in ((choice.get("delta") or {}).get("tool_calls") or []):
                    slot = int(fragment.get("index") or 0)
                    while len(reply.tool_calls) <= slot:
                        reply.tool_calls.append({"id": "", "name": "", "arguments": ""})
                    call = reply.tool_calls[slot]
                    call["id"] = fragment.get("id") or call["id"]
                    function = fragment.get("function") or {}
                    call["name"] = function.get("name") or call["name"]
                    call["arguments"] += function.get("arguments") or ""
                    if reply.ttft_ms is None:
                        reply.ttft_ms = (time.perf_counter() - started) * 1000
                piece = (choice.get("delta") or {}).get("content")
                if not piece:
                    # Role-only or reasoning-only. For a reasoning model the thinking
                    # precedes any visible token, and calling that first content would
                    # report a latency nobody experiences.
                    continue
                if reply.ttft_ms is None:
                    reply.ttft_ms = (time.perf_counter() - started) * 1000
                parts.append(piece)
    except (OSError, http.client.HTTPException) as exc:
        reply.error = f"broken mid-stream: {type(exc).__name__}: {exc}"[:300]
    finally:
        reply.latency_ms = (time.perf_counter() - started) * 1000
        reply.text = "".join(parts)


# The Responses stream names its events instead of nesting deltas under a choice, so the pieces of a
# call arrive as three different event types rather than as fragments of one.
_RESPONSES_TERMINAL = ("response.completed", "response.incomplete", "response.failed")


def _responses_event(reply: Reply, event: dict, started: float, parts: list[str]) -> None:
    """Fold one Responses stream event into the reply.

    Visible text goes into `parts`, not into `reply.text`: the caller assigns `reply.text` from that
    list when the stream ends, so writing to `reply.text` here is silently undone. That is not
    hypothetical -- it cost this project a whole judge pass, where every verdict came back unparseable
    because the reply carried no text at all while the usage block showed tokens had been generated.
    """
    kind = event.get("type") or ""
    if kind == "response.output_item.added":
        item = event.get("item") or {}
        if item.get("type") == "function_call":
            reply.tool_calls.append({
                "id": item.get("call_id") or item.get("id") or "",
                "name": item.get("name") or "",
                "arguments": item.get("arguments") or "",
            })
            if reply.ttft_ms is None:
                reply.ttft_ms = (time.perf_counter() - started) * 1000
    elif kind == "response.function_call_arguments.delta":
        if reply.tool_calls:
            reply.tool_calls[-1]["arguments"] += event.get("delta") or ""
    elif kind == "response.output_text.delta":
        parts.append(event.get("delta") or "")
        if reply.ttft_ms is None:
            reply.ttft_ms = (time.perf_counter() - started) * 1000
    elif kind in _RESPONSES_TERMINAL:
        response = event.get("response") or {}
        if response.get("usage"):
            _usage(reply, response["usage"])
        if response.get("model"):
            reply.served_model = response["model"]
        # `status` is the Responses spelling of a finish reason, and "incomplete" carries the
        # reason the loop needs: a turn cut off at the output limit must not be filed as the model
        # failing to follow a format.
        status = response.get("status") or ""
        detail = (response.get("incomplete_details") or {}).get("reason")
        reply.finish_reason = (
            "length" if detail == "max_output_tokens"
            else "stop" if status == "completed"
            else detail or status or None
        )
        if response.get("error"):
            error = response["error"]
            message = error.get("message") if isinstance(error, dict) else error
            reply.error = f"response error: {str(message)[:300]}"
    elif kind == "error":
        reply.error = f"error event: {str(event.get('message') or event)[:300]}"


def _responses_body(
    model: str,
    messages: list[dict],
    max_tokens: int,
    reasoning_effort: str | None,
    tool_schemas: list[dict] | None,
) -> dict:
    """The same turn as a Responses request.

    The loop keeps one message list, in the chat shape, and the translation happens here: which
    wire a tier speaks is a serialisation concern and letting it reach the loop would give the
    harness a third dialect of its own history to keep consistent.

    Two shape differences that are not stylistic. A tool is declared flat -- `{"type": "function",
    "name": ...}` rather than nested under `"function"` -- and a turn's history is items rather than
    messages: an assistant tool call becomes a `function_call` item and its result a
    `function_call_output` item keyed by the same `call_id`. The model's own `reasoning` items are
    deliberately not echoed back; the gateway accepts the history without them, and carrying
    encrypted reasoning across turns would put content in the prompt that the token accounting
    cannot see.
    """
    items: list[dict] = []
    for message in messages:
        role = message.get("role")
        if role == "assistant" and message.get("tool_calls"):
            if message.get("content"):
                items.append({"role": "assistant", "content": message["content"]})
            for call in message["tool_calls"]:
                function = call.get("function") or {}
                items.append({
                    "type": "function_call",
                    "call_id": call.get("id") or "",
                    "name": function.get("name") or "",
                    "arguments": function.get("arguments") or "{}",
                })
        elif role == "tool":
            items.append({
                "type": "function_call_output",
                "call_id": message.get("tool_call_id") or "",
                "output": message.get("content") or "",
            })
        elif message.get("content") is not None:
            items.append({"role": role, "content": message["content"]})
    body = {
        "model": model,
        "input": items,
        "max_output_tokens": max_tokens,
        "stream": True,
    }
    if reasoning_effort:
        body["reasoning"] = {"effort": reasoning_effort}
    if tool_schemas:
        body["tools"] = [
            {"type": "function", **(schema.get("function") or {})} for schema in tool_schemas
        ]
        body["tool_choice"] = "auto"
    return body


def _usage(reply: Reply, usage: dict) -> None:
    """Read one usage block, in whichever spelling it arrives.

    Every spelling is read because a call whose cache state is unknown cannot be priced,
    and the cache state is the term that decides whether escalation can pay for itself.
    """
    reply.prompt_tokens = int(
        usage.get("prompt_tokens") or usage.get("input_tokens") or reply.prompt_tokens
    )
    reply.completion_tokens = int(
        usage.get("completion_tokens") or usage.get("output_tokens") or reply.completion_tokens
    )
    out_details = usage.get("completion_tokens_details") or usage.get("output_tokens_details") or {}
    reply.reasoning_tokens = int(
        out_details.get("reasoning_tokens") or reply.reasoning_tokens
    )
    in_details = usage.get("prompt_tokens_details") or usage.get("input_tokens_details") or {}
    for key in ("cached_tokens", "cacheReadInputTokens", "cache_read_input_tokens"):
        value = in_details.get(key, usage.get(key))
        if value is not None:
            reply.cached_prompt_tokens = int(value)
            break
    for key in ("cache_write_tokens", "cacheWriteInputTokens", "cache_creation_input_tokens"):
        value = in_details.get(key, usage.get(key))
        if value is not None:
            reply.cache_write_tokens = int(value)
            break
