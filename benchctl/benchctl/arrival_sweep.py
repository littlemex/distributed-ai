"""Where, if anywhere, the box is simultaneously busy enough to be cheap and quiet enough to stay cached.

Every cost this project has published for the box divides an hourly machine rate by a throughput measured at
some concurrency and calls the result a price. That hides an assumption which two advisors independently said
was the weakest thing in the whole result: **the box is cheap only if it is busy, and cheap only if its cache
hits, and those pull in opposite directions.** Occupancy comes from concurrent conversations; concurrent
conversations evict each other's prefixes. `results-prefix-survival.md` measured the eviction side — 99% of a
prefix survives up to twelve conversations, 71% at twenty, **0% at thirty-two** — and
`results-prefix-reuse-cost.md` measured the break-even the box needs, 71.4% at the ratio it was run at. Those
two numbers nearly touch, and they were never put on one axis because no run varied load.

So this varies load, and it removes the assumption rather than restating it:

    box cost per request = hourly_usd x wall_clock_seconds / requests_completed

No occupancy term, no throughput measured elsewhere. If the box is idle, the arithmetic charges it for being
idle, which is what a machine on an hourly rate actually costs. That single change is the point of this
instrument; everything else is the traffic needed to make it mean something.

## Open loop, because a closed loop answers a different question

Arrivals are Poisson and independent of how the box is coping. A closed loop — hold N conversations in flight,
start the next turn when the last returns — silently converts a latency collapse into a throughput reduction
and reports a machine that never queues. This project has been caught by that before: the co-residency work
found that a closed loop and an open loop *reverse* which configuration wins. So sessions arrive on a clock and
the queue grows if the box cannot keep up, which is the failure this is looking for.

In-flight requests are capped anyway, generously, because an unbounded queue eventually means the process dies
rather than the measurement completing. A point that hits the cap is reported as invalid rather than averaged
in: past that arrival rate the load generator is the bottleneck and the number would describe this script.

## What a session is

A conversation, because reuse is a property of a session and not of a request. Each one arrives, runs its turns
with a think time between them, and grows: turn N carries every earlier turn verbatim. Its `X-Correlation-ID`
is stable, which is what the affinity router hashes on — so a session's turns reach the replica holding its
prefix. Run it against the plain Service instead and the same traffic caches every prefix on *both* replicas,
which halves the sessions the pool can hold. Both paths are worth sweeping and the difference is the router's
value under load, which the existing A/B measured only at one arrival rate.
"""

from __future__ import annotations

import argparse
import json
import random
import statistics
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from benchctl import spec                                        # noqa: E402
from benchctl.layers import LayerClient                          # noqa: E402
from benchctl.prefix_reuse_cost import answer_instruction, _CLAUSE   # noqa: E402


@dataclass
class Turn:
    session: int
    turn: int
    arrived: float
    latency_s: float
    prompt_tokens: int
    cached_prompt_tokens: int
    completion_tokens: int
    usable: bool


@dataclass
class Point:
    """One arrival rate, measured."""

    sessions_per_s: float
    window_s: float
    turns: list[Turn] = field(default_factory=list)
    capped: bool = False
    max_in_flight: int = 0

    def usable(self) -> list[Turn]:
        return [t for t in self.turns if t.usable]

    def summary(self, hourly_usd: float, slo_s: float) -> dict:
        done = self.usable()
        prompt = sum(t.prompt_tokens for t in done)
        cached = sum(t.cached_prompt_tokens for t in done)
        latencies = sorted(t.latency_s for t in done)
        within = [t for t in done if t.latency_s <= slo_s]
        # The whole point: an hourly rate over what actually completed, with no occupancy assumption.
        usd_per_request = (hourly_usd * self.window_s / 3600 / len(done)) if done else None
        usd_per_slo_request = (hourly_usd * self.window_s / 3600 / len(within)) if within else None
        return {
            "sessions_per_s": self.sessions_per_s,
            "window_s": self.window_s,
            "requests_completed": len(done),
            "requests_failed": len(self.turns) - len(done),
            "requests_per_hour": len(done) / self.window_s * 3600 if self.window_s else 0.0,
            "max_in_flight": self.max_in_flight,
            "load_generator_capped": self.capped,
            "prompt_tokens": prompt,
            "cached_prompt_tokens": cached,
            "cached_share": (cached / prompt) if prompt else 0.0,
            "completion_tokens": sum(t.completion_tokens for t in done),
            "latency_p50_s": statistics.median(latencies) if latencies else None,
            "latency_p95_s": latencies[min(len(latencies) - 1, int(0.95 * (len(latencies) - 1)))]
            if latencies else None,
            "within_slo": len(within),
            "slo_attainment": (len(within) / len(done)) if done else 0.0,
            "box_usd_per_request": usd_per_request,
            "box_usd_per_slo_request": usd_per_slo_request,
        }


def session_messages(*, session: int, turns: int, preamble_tokens: int, turn_tokens: int,
                     output_words: int) -> list[list[dict]]:
    """The message arrays for one session's turns. The preamble is shared; the history is the session's own."""
    shared = _CLAUSE * max(1, preamble_tokens // 12)
    ask = answer_instruction(output_words)
    messages = [{"role": "user", "content":
                 f"System context (identical for every conversation):\n{shared}\n\n"
                 f"Session {session}: describe the first step you would take. {ask}"}]
    out = [list(messages)]
    for turn in range(2, turns + 1):
        history = _CLAUSE * max(1, turn_tokens // 12)
        messages = messages + [
            {"role": "assistant", "content": f"Step {turn - 1} noted."},
            {"role": "user", "content": f"Tool output for step {turn - 1}:\n{history}\n\n"
                                        f"Session {session}, turn {turn}: what next? {ask}"},
        ]
        out.append(list(messages))
    return out


def measure_point(layer, *, sessions_per_s: float, window_s: float, turns: int, preamble_tokens: int,
                  turn_tokens: int, output_words: int, max_tokens: int, think_time_s: float,
                  in_flight_cap: int, seed: int, use_correlation_id: bool) -> Point:
    client = LayerClient(layer)
    point = Point(sessions_per_s=sessions_per_s, window_s=window_s)
    lock = threading.Lock()
    in_flight = 0
    stop = threading.Event()
    rng = random.Random(seed)
    threads: list[threading.Thread] = []
    started = time.perf_counter()

    def run_session(session: int) -> None:
        nonlocal in_flight
        arrays = session_messages(session=session, turns=turns, preamble_tokens=preamble_tokens,
                                  turn_tokens=turn_tokens, output_words=output_words)
        # Stable for every turn, which is what the affinity router hashes on.
        corr = f"sweep-{seed}-{session}"
        for index, messages in enumerate(arrays, start=1):
            if stop.is_set():
                return
            with lock:
                in_flight += 1
                point.max_in_flight = max(point.max_in_flight, in_flight)
            arrived = time.perf_counter() - started
            try:
                reply = client.complete(messages=messages, max_tokens=max_tokens, temperature=0.0,
                                        correlation_id=corr if use_correlation_id else None)
                latency, usable = reply.latency_s, reply.usable
                prompt, cached, completion = (reply.prompt_tokens, reply.cached_prompt_tokens,
                                              reply.completion_tokens)
            except Exception:                                    # noqa: BLE001
                latency, usable, prompt, cached, completion = 0.0, False, 0, 0, 0
            finally:
                with lock:
                    in_flight -= 1
            with lock:
                point.turns.append(Turn(session=session, turn=index, arrived=arrived,
                                        latency_s=latency, prompt_tokens=prompt,
                                        cached_prompt_tokens=cached, completion_tokens=completion,
                                        usable=usable))
            if index < len(arrays):
                time.sleep(think_time_s)

    session = 0
    while True:
        elapsed = time.perf_counter() - started
        if elapsed >= window_s:
            break
        with lock:
            current = in_flight
        if current >= in_flight_cap:
            # The generator, not the box, is now the constraint. Recorded rather than smoothed over.
            point.capped = True
        else:
            thread = threading.Thread(target=run_session, args=(session,), daemon=True)
            thread.start()
            threads.append(thread)
            session += 1
        # Poisson arrivals: exponential gaps, independent of how the box is coping.
        time.sleep(rng.expovariate(sessions_per_s) if sessions_per_s > 0 else 1.0)

    stop.set()
    deadline = time.perf_counter() + 300
    for thread in threads:
        thread.join(timeout=max(0.0, deadline - time.perf_counter()))
    point.window_s = time.perf_counter() - started
    return point


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--layers-file", type=Path, required=True)
    ap.add_argument("--layer", required=True)
    ap.add_argument("--endpoint", default=None, help="override the layer's endpoint, e.g. the affinity router")
    ap.add_argument("--lambdas", type=float, nargs="+", required=True,
                    help="session arrival rates, sessions per second")
    ap.add_argument("--window", type=float, default=180.0)
    ap.add_argument("--turns", type=int, default=6)
    ap.add_argument("--preamble-tokens", type=int, default=12000)
    ap.add_argument("--turn-tokens", type=int, default=1500)
    ap.add_argument("--output-words", type=int, default=200)
    ap.add_argument("--max-tokens", type=int, default=400)
    ap.add_argument("--think-time", type=float, default=2.0)
    ap.add_argument("--in-flight-cap", type=int, default=96)
    ap.add_argument("--slo-s", type=float, default=10.0)
    ap.add_argument("--correlation-id", action="store_true",
                    help="send X-Correlation-ID, which the affinity router hashes on")
    ap.add_argument("--seed", type=int, default=20260829)
    ap.add_argument("--out", type=Path, default=None)
    args = ap.parse_args(argv)

    layers = spec.load_layers(args.layers_file)
    if args.layer not in layers:
        print(f"no layer {args.layer!r}; have {sorted(layers)}", file=sys.stderr)
        return 2
    layer = layers[args.layer]
    if args.endpoint:
        from dataclasses import replace
        layer = replace(layer, endpoint=args.endpoint)
    hourly = layer.hourly_usd or 0.0

    print(f"{args.layer} at {layer.endpoint}")
    print(f"correlation id: {'sent' if args.correlation_id else 'not sent'}   "
          f"SLO {args.slo_s}s   window {args.window}s   {args.turns} turns/session\n")
    print(f"{'λ sess/s':>9} {'done':>5} {'fail':>5} {'req/h':>8} {'inflight':>9} {'cached':>7} "
          f"{'p50':>7} {'p95':>8} {'SLO':>6} {'$/req':>9} {'$/SLO req':>10}  note")

    points = []
    for rate in args.lambdas:
        point = measure_point(layer, sessions_per_s=rate, window_s=args.window, turns=args.turns,
                              preamble_tokens=args.preamble_tokens, turn_tokens=args.turn_tokens,
                              output_words=args.output_words, max_tokens=args.max_tokens,
                              think_time_s=args.think_time, in_flight_cap=args.in_flight_cap,
                              seed=args.seed, use_correlation_id=args.correlation_id)
        s = point.summary(hourly, args.slo_s)
        points.append(s)
        note = "GENERATOR CAPPED — invalid" if s["load_generator_capped"] else ""
        per = f"{s['box_usd_per_request']*1000:9.3f}" if s["box_usd_per_request"] else "        -"
        slo = f"{s['box_usd_per_slo_request']*1000:10.3f}" if s["box_usd_per_slo_request"] else "         -"
        print(f"{rate:9.3f} {s['requests_completed']:5d} {s['requests_failed']:5d} "
              f"{s['requests_per_hour']:8.0f} {s['max_in_flight']:9d} {s['cached_share']:6.1%} "
              f"{s['latency_p50_s'] or 0:6.2f}s {s['latency_p95_s'] or 0:7.2f}s "
              f"{s['slo_attainment']:5.0%} {per} {slo}  {note}", flush=True)

    if args.out:
        args.out.write_text(json.dumps({"layer": args.layer, "endpoint": layer.endpoint,
                                        "settings": {k: str(v) for k, v in vars(args).items()},
                                        "points": points}, indent=2))
        print(f"\n[OK] wrote {args.out}")
    print("\n$/req and $/SLO req are per thousand requests, and are an hourly rate over what completed in "
          "the window.\nNo occupancy is assumed: an idle box is charged for being idle.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
