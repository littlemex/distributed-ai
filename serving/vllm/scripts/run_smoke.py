#!/usr/bin/env python3
"""Smoke test a vLLM OpenAI-compatible endpoint.

Not wired into CI -- run manually against a port-forwarded (or in-cluster) endpoint
before declaring a model "served". Checks three things, in order of importance for an
agent backend:

  1. /v1/models lists the served model.
  2. /v1/chat/completions returns a non-empty text answer.
  3. a tool-enabled request comes back as a structured tool call (finish_reason
     "tool_calls" with valid JSON arguments). OpenAI-compatible != tool-calling
     compatible: if the model/engine has no tool-call parser, this step fails and an
     agent (opencode/kiro) will not work even though chat does.

Usage:
  python3 run_smoke.py --base-url http://localhost:8000 --model Qwen/Qwen3.8-27B
  python3 run_smoke.py ... --skip-tools    # chat-only (e.g. a base model)
"""
import argparse
import json
import sys
import urllib.request


def _post(url, payload, timeout):
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def _get(url, timeout):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.load(r)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", default="http://localhost:8000")
    ap.add_argument("--model", required=True)
    ap.add_argument("--timeout", type=int, default=120)
    ap.add_argument("--skip-tools", action="store_true")
    args = ap.parse_args()
    base = args.base_url.rstrip("/")
    fails = []

    # 1. models
    try:
        ids = [m["id"] for m in _get(f"{base}/v1/models", args.timeout).get("data", [])]
        assert args.model in ids, f"{args.model} not in {ids}"
        print(f"[OK] /v1/models lists {args.model}")
    except Exception as e:
        fails.append(f"models: {e}")

    # 2. chat
    try:
        resp = _post(
            f"{base}/v1/chat/completions",
            {"model": args.model,
             "messages": [{"role": "user", "content": "Reply with the single word: pong"}],
             "max_tokens": 16, "temperature": 0},
            args.timeout,
        )
        text = resp["choices"][0]["message"].get("content") or ""
        assert text.strip(), "empty chat content"
        print(f"[OK] chat completion: {text.strip()[:60]!r}")
    except Exception as e:
        fails.append(f"chat: {e}")

    # 3. tool call
    if not args.skip_tools:
        try:
            tools = [{
                "type": "function",
                "function": {
                    "name": "get_weather",
                    "description": "Get the current weather for a city",
                    "parameters": {
                        "type": "object",
                        "properties": {"city": {"type": "string"}},
                        "required": ["city"],
                    },
                },
            }]
            resp = _post(
                f"{base}/v1/chat/completions",
                {"model": args.model,
                 "messages": [{"role": "user", "content": "What is the weather in Tokyo? Use the tool."}],
                 "tools": tools, "tool_choice": "auto", "max_tokens": 128, "temperature": 0},
                args.timeout,
            )
            choice = resp["choices"][0]
            tcs = choice["message"].get("tool_calls") or []
            assert tcs, f"no tool_calls (finish_reason={choice.get('finish_reason')}); "\
                        "engine likely lacks a tool-call parser for this model"
            json.loads(tcs[0]["function"]["arguments"])  # must be valid JSON
            print(f"[OK] tool call: {tcs[0]['function']['name']}({tcs[0]['function']['arguments']})")
        except Exception as e:
            fails.append(f"tools: {e}")

    if fails:
        print("\n[NG] smoke failed:")
        for f in fails:
            print(f"  - {f}")
        sys.exit(1)
    print("\n[OK] all smoke checks passed")


if __name__ == "__main__":
    main()
