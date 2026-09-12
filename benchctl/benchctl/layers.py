"""Calling a layer, and charging for it.

One implementation covers both kinds of layer, because both speak the OpenAI chat API: the gateway in
front of the frontier models and the vLLM server on the box. What differs is not the protocol but the
accounting, and that difference is the reason this module exists rather than a bare HTTP call.

An API layer is billed per token by its provider, and the provider says how many were fresh, cached and
written. The box is billed by the hour, so its per-request figure is derived: the tokens it read and
wrote, priced at rates that came from measured throughput. The two are kept in separate ledgers all the
way through — `api_cost` and `box_cost` — because collapsing them into one number is how "what we paid"
and "what it cost" get confused, and only one of those is comparable across layers.
"""

from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field

from .spec import Layer


@dataclass
class Reply:
    text: str
    prompt_tokens: int = 0
    completion_tokens: int = 0
    cached_prompt_tokens: int = 0
    latency_s: float = 0.0
    finish_reason: str | None = None
    error: str | None = None
    http_status: int | None = None
    attempts: int = 1

    @property
    def usable(self) -> bool:
        """Whether this reply is the layer's answer, as opposed to the transport's failure.

        A call that produced no text and reported no usage is not an answer the model gave. Counting it
        as a wrong answer charges the layer for the network, which is how a provider's bad afternoon
        becomes a quality result.
        """
        return bool(self.text) and self.error is None

    @property
    def fresh_prompt_tokens(self) -> int:
        return max(0, self.prompt_tokens - self.cached_prompt_tokens)


@dataclass
class Cost:
    """Two ledgers, never added together."""

    api_usd: float = 0.0
    box_seconds: float = 0.0
    box_usd_at_full_utilisation: float = 0.0
    detail: dict = field(default_factory=dict)


def _to_anthropic(prompt: "str | list[dict]") -> "str | list[dict]":
    """Translate OpenAI content parts into Anthropic's, because the gateway's shim refuses images.

    The gateway says so in as many words on a 400: "image_url content parts are not supported; use the
    Anthropic /v1/messages endpoint with base64 images". The box, serving the same OpenAI protocol,
    accepts them. So the two layers are not symmetric for a multimodal family, and the asymmetry lives
    here rather than in the task, which should not have to know who it is talking to.
    """
    if isinstance(prompt, str):
        return prompt
    out: list[dict] = []
    for part in prompt:
        if part.get("type") == "text":
            out.append({"type": "text", "text": part.get("text", "")})
            continue
        url = (part.get("image_url") or {}).get("url", "")
        if not url.startswith("data:"):
            raise ValueError("anthropic image parts need an inline data URI, not a remote URL")
        head, _, data = url.partition(",")
        media_type = head[len("data:"):].split(";", 1)[0] or "image/jpeg"
        out.append({"type": "image",
                    "source": {"type": "base64", "media_type": media_type, "data": data}})
    return out


def _from_anthropic(payload: dict, status: int | None, attempt: int, latency_s: float) -> Reply:
    """Anthropic's reply shape, mapped onto the same Reply the rest of the harness reads."""
    blocks = payload.get("content") or []
    text = "".join(b.get("text", "") for b in blocks if b.get("type") == "text")
    usage = payload.get("usage") or {}
    return Reply(
        text=text,
        prompt_tokens=int(usage.get("input_tokens") or 0),
        completion_tokens=int(usage.get("output_tokens") or 0),
        # Anthropic reports cache reads separately; both names have appeared in the wild.
        cached_prompt_tokens=int(usage.get("cache_read_input_tokens")
                                 or usage.get("cache_read_tokens") or 0),
        latency_s=latency_s,
        finish_reason=payload.get("stop_reason"),
        http_status=status,
        attempts=attempt,
    )


class LayerClient:
    """One layer, callable. Retries only what is worth retrying, and says when it gave up."""

    RETRYABLE = frozenset({408, 425, 429, 500, 502, 503, 504})

    def __init__(self, layer: Layer, *, timeout_s: float = 600.0, max_attempts: int = 4) -> None:
        self.layer = layer
        self.timeout_s = timeout_s
        self.max_attempts = max_attempts
        self.api_key = os.environ.get(layer_api_key_env(layer)) if layer.kind == "api" else None

    def complete(self, prompt: "str | list[dict] | None" = None, *, max_tokens: int,
                 temperature: float = 0.0, messages: "list[dict] | None" = None,
                 correlation_id: "str | None" = None) -> Reply:
        """`prompt` is text, or a list of OpenAI content parts for a multimodal family.

        Passing the list straight through is what keeps the image path from becoming a second client:
        a text-only task still hands over a string and never learns that images exist, and an OCR task
        builds the parts itself because only it knows how its images should be attached.

        `correlation_id` is sent as `X-Correlation-ID` and is what the conversation-affinity router in front
        of the box hashes on, so a conversation's turns reach the replica holding its prefix. Without it the
        plain Service round-robins and every prefix ends up cached on both replicas, which halves the KV a
        session can occupy before eviction. AIPerf sends the same header for the same reason.

        `messages` is the alternative for traffic that is a conversation rather than a question, and it is
        not a convenience. Prompt caching on this gateway attaches to a *turn boundary*: the same 5,600-token
        preamble inside one user message with a varying tail caches nothing on a Claude layer, while the same
        content as a growing user/assistant array caches 99.9% of every turn after the first. A harness that
        can only send one user message cannot measure the traffic whose economics turn on that.
        """
        if messages is not None:
            if prompt is not None:
                raise ValueError("pass either prompt or messages, not both")
        elif prompt is None:
            raise ValueError("complete() needs a prompt or a messages array")
        has_image = isinstance(prompt, list) and any(
            part.get("type") != "text" for part in prompt)
        anthropic = has_image and self.layer.image_style == "anthropic"
        url = self.layer.messages_endpoint if anthropic else self.layer.endpoint
        wire_messages = (messages if messages is not None
                         else [{"role": "user", "content": prompt}])
        payload_out = (
            {
                "model": self.layer.model,
                "messages": (messages if messages is not None
                             else [{"role": "user", "content": _to_anthropic(prompt)}]),
                "max_tokens": max_tokens,
            }
            if anthropic else
            {
                "model": self.layer.model,
                "messages": wire_messages,
                "max_tokens": max_tokens,
            }
        )
        if self.layer.sends_temperature:
            payload_out["temperature"] = temperature
        body = json.dumps(payload_out).encode()
        headers = {"content-type": "application/json"}
        if correlation_id:
            headers["X-Correlation-ID"] = correlation_id
        if self.api_key:
            headers["authorization"] = f"Bearer {self.api_key}"

        backoff = 2.0
        for attempt in range(1, self.max_attempts + 1):
            started = time.perf_counter()
            request = urllib.request.Request(url, data=body, headers=headers)
            try:
                with urllib.request.urlopen(request, timeout=self.timeout_s) as response:
                    payload = json.load(response)
                    status = response.status
            except urllib.error.HTTPError as exc:
                detail = exc.read(1200).decode("utf-8", "replace")
                # A 5xx that wraps a validation error is permanent, and retrying it is pure waste.
                # The gateway returns 502 for a Bedrock ValidationException, so sending `temperature`
                # to a model that rejects it cost four attempts and fourteen seconds of backoff on
                # every one of 278 items — forty minutes of a run spent re-asking a settled question,
                # with the cause hidden behind the retries.
                permanent = any(m in detail for m in
                                ("ValidationException", "is deprecated", "invalid_request_error",
                                 "unsupported_content"))
                if permanent:
                    return Reply(text="", error=f"http {exc.code} (not retried, permanent): "
                                               f"{detail[:400]}",
                                 http_status=exc.code, attempts=attempt,
                                 latency_s=time.perf_counter() - started)
                if exc.code in self.RETRYABLE and attempt < self.max_attempts:
                    time.sleep(backoff)
                    backoff *= 2
                    continue
                return Reply(text="", error=f"http {exc.code}: {detail[:400]}",
                             http_status=exc.code, attempts=attempt,
                             latency_s=time.perf_counter() - started)
            except (OSError, json.JSONDecodeError) as exc:
                if attempt < self.max_attempts:
                    time.sleep(backoff)
                    backoff *= 2
                    continue
                return Reply(text="", error=f"{type(exc).__name__}: {exc}", attempts=attempt,
                             latency_s=time.perf_counter() - started)

            if anthropic:
                return _from_anthropic(payload, status, attempt, time.perf_counter() - started)
            choice = (payload.get("choices") or [{}])[0]
            usage = payload.get("usage") or {}
            details = usage.get("prompt_tokens_details") or {}
            reply = Reply(
                text=((choice.get("message") or {}).get("content") or ""),
                prompt_tokens=int(usage.get("prompt_tokens") or 0),
                completion_tokens=int(usage.get("completion_tokens") or 0),
                cached_prompt_tokens=int(details.get("cached_tokens") or 0),
                latency_s=time.perf_counter() - started,
                finish_reason=choice.get("finish_reason"),
                http_status=status,
                attempts=attempt,
            )
            # A 200 with no content and no usage is the far side failing quietly. Retried rather than
            # recorded, because recorded it looks like the model answering badly.
            if not reply.text and not reply.prompt_tokens and attempt < self.max_attempts:
                time.sleep(backoff)
                backoff *= 2
                continue
            if not reply.text and not reply.prompt_tokens:
                reply.error = "the provider answered 200 with no content and no usage"
            return reply
        return Reply(text="", error="exhausted attempts", attempts=self.max_attempts)

    def cost(self, reply: Reply) -> Cost:
        million = 1_000_000
        if self.layer.kind == "api":
            fresh = reply.fresh_prompt_tokens
            cached = reply.cached_prompt_tokens
            cache_rate = self.layer.cache_read_usd_per_mtok
            usd = (
                fresh / million * (self.layer.input_usd_per_mtok or 0.0)
                + cached / million * (cache_rate if cache_rate is not None
                                      else (self.layer.input_usd_per_mtok or 0.0))
                + reply.completion_tokens / million * (self.layer.output_usd_per_mtok or 0.0)
            )
            return Cost(api_usd=usd, detail={
                "fresh_prompt_tokens": fresh,
                "cached_prompt_tokens": cached,
                "completion_tokens": reply.completion_tokens,
                "pricing_status": self.layer.pricing_status,
            })

        # The box. Its per-token rates are derived from measured throughput, so the money figure is a
        # statement about a fully occupied machine and is labelled as such: at half that occupancy the
        # same work costs twice as much, and "the marginal cost is zero" is a different claim again.
        #
        # Cached prompt tokens are charged at their own rate, when one has been measured. Charging them at
        # the fresh rate was the ledger's one structural bias against the box: on the cache-ablation run it
        # served 72.5% of its prompt tokens from its prefix cache and paid full price for all of them, while
        # the api branch above discounts a cache read explicitly. `benchctl/cached_prefill_rate.py` measures
        # the rate rather than assuming it — 224,620 tok/s of cached prefill against 18,417 fresh at the same
        # concurrency, which is 8.2% of a fresh token, close to the tenth the APIs charge for theirs.
        cached = reply.cached_prompt_tokens
        cache_rate = self.layer.cache_read_usd_per_mtok
        fresh = (reply.prompt_tokens - cached) if cache_rate is not None else reply.prompt_tokens
        usd = (
            fresh / million * (self.layer.input_usd_per_mtok or 0.0)
            + (cached / million * cache_rate if cache_rate is not None else 0.0)
            + reply.completion_tokens / million * (self.layer.output_usd_per_mtok or 0.0)
        )
        seconds = usd / (self.layer.hourly_usd or 1.0) * 3600 if self.layer.hourly_usd else 0.0
        return Cost(
            box_usd_at_full_utilisation=usd,
            box_seconds=seconds,
            detail={
                "fresh_prompt_tokens": fresh,
                "cached_prompt_tokens": cached,
                "prompt_tokens": reply.prompt_tokens,
                "completion_tokens": reply.completion_tokens,
                "hourly_usd": self.layer.hourly_usd,
                "utilisation_assumption": 1.0,
                "note": "box_usd is at full occupancy; divide by the real utilisation to get the bill",
            },
        )


def layer_api_key_env(layer: Layer) -> str:
    """Which environment variable holds this layer's key. Keys never live in a spec."""
    return "BENCHCTL_API_KEY"
