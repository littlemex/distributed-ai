"""What a self-hosted model costs per token, which is a function of load.

A rented GPU is billed by the hour whether it is busy or not, so its cost per token
is `hourly rate / tokens per hour achieved` — a number that moves with how hard the
server is driven and with how long the answers are. Quoting a flat per-token price for
one is the mistake this module exists to prevent: the rate table this project started
from priced a self-hosted member at $0.20 per million tokens, and the measured figure
at the deployed configuration was $8.80.

Two consequences shape the interface.

**Throughput has to be measured, not assumed.** `LoadPoint` is one observed operating
point — a batch setting and an offered concurrency, with the request rate, token rates
and latency percentiles that came out. A cost model is a set of those plus the hourly
rate, and nothing else.

**The price depends on which latency you are willing to accept.** Driving deeper
batches buys token throughput and pays for it in per-stream latency, so "the cheapest
setting" is meaningless until a service level is named. `cheapest_meeting` takes an SLO
and returns the best point that satisfies it, which is what removes the argument about
whether a favourable setting was chosen to make the numbers look good: the service
level chooses the setting.

Prefill and decode are priced separately where the sweep can identify them. They
consume the same GPU at very different rates, so a single blended per-token price
misattributes cost between a long prompt and a long answer — and answer length is
exactly what a router would arbitrage. But the split is a local shadow price under a
fixed scheduler, workload mix, service level and arrival process, not a physical
constant, and it needs a sweep that varies prompt and output length independently.
Where that sweep does not exist, `split_prices` raises instead of returning a number
that looks derived.

The headline price is the saturated replacement cost at the highest-throughput point
that meets the service level. Average realised cost and marginal spare-capacity cost
belong in an analysis table, not in a headline and not in what a router is told: the
first is a function of whatever traffic happened to arrive, and the second treats a
machine you are still paying for as free.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Sequence

SECONDS_PER_HOUR = 3600
TOKENS_PER_MILLION = 1_000_000


@dataclass(frozen=True)
class LoadPoint:
    """One measured operating point of a self-hosted deployment.

    `arrival` and `workload` are not documentation. A capacity measured by holding a
    fixed number of requests in flight is capacity *at that depth*: the closed loop
    throttles itself when latency degrades, so it cannot find the rate at which the
    queue runs away. An open-loop Poisson arrival can, and only it supports a claim
    about what the deployment sustains. A price derived from one is a price for that
    arrival process and that mix of prompt and output lengths, and quoting it without
    them is how a flat per-token number gets invented.
    """

    max_num_seqs: int
    offered_concurrency: int
    # "closed-loop@N" | "open-loop-poisson@R" | "trace-replay:<name>"
    arrival: str = "unspecified"
    # Mean prompt and output length this point was driven with; the price does not
    # transfer to a workload with a different shape.
    workload: str = "unspecified"
    requests_per_s: float = 0.0
    prompt_tokens_per_s: float = 0.0
    output_tokens_per_s: float = 0.0
    ttft_p50_ms: float = 0.0
    ttft_p95_ms: float = float("inf")
    tpot_p50_ms: float = 0.0
    tpot_p95_ms: float = float("inf")
    # Time a request spent waiting rather than generating. Reported separately
    # because at depth it is most of the latency and none of the work.
    queue_p95_ms: float = 0.0
    note: str = ""

    @property
    def total_tokens_per_s(self) -> float:
        return self.prompt_tokens_per_s + self.output_tokens_per_s


@dataclass(frozen=True)
class SLO:
    """A service level a deployment must meet to be considered at all."""

    name: str
    ttft_p95_ms: float | None = None
    tpot_p95_ms: float | None = None

    def admits(self, point: LoadPoint) -> bool:
        if self.ttft_p95_ms is not None and point.ttft_p95_ms > self.ttft_p95_ms:
            return False
        if self.tpot_p95_ms is not None and point.tpot_p95_ms > self.tpot_p95_ms:
            return False
        return True


@dataclass(frozen=True)
class TokenPrices:
    """Per-token prices, in USD per million tokens."""

    prompt_per_1m: float
    completion_per_1m: float
    basis: str

    def cost_usd(self, prompt_tokens: int, completion_tokens: int) -> float:
        return (
            prompt_tokens * self.prompt_per_1m + completion_tokens * self.completion_per_1m
        ) / TOKENS_PER_MILLION


class ServingCostError(RuntimeError):
    """The measurements cannot support the price being asked for."""


@dataclass(frozen=True)
class ServingCostModel:
    """Prices for a self-hosted deployment, derived from what it actually served."""

    hourly_usd: float
    points: tuple[LoadPoint, ...]

    def __post_init__(self) -> None:
        if self.hourly_usd <= 0:
            raise ServingCostError("hourly_usd must be positive")
        if not self.points:
            raise ServingCostError(
                "a serving cost model needs at least one measured operating point; "
                "there is no defensible price for a machine nobody drove"
            )

    @property
    def usd_per_second(self) -> float:
        return self.hourly_usd / SECONDS_PER_HOUR

    def blended_prices(self, point: LoadPoint) -> TokenPrices:
        """One price for both directions, from the total token rate at this point.

        The honest fallback when a sweep cannot separate prefill from decode. It
        under-prices long answers and over-prices long prompts relative to the split
        model, so it is reported as blended rather than presented as a rate card.
        """
        if point.total_tokens_per_s <= 0:
            raise ServingCostError(f"point {point.note or point.max_num_seqs} served nothing")
        per_1m = self.usd_per_second / point.total_tokens_per_s * TOKENS_PER_MILLION
        return TokenPrices(
            prompt_per_1m=per_1m,
            completion_per_1m=per_1m,
            basis=f"blended at max_num_seqs={point.max_num_seqs}, "
            f"{point.total_tokens_per_s:.0f} tok/s",
        )

    def output_only_prices(self, point: LoadPoint) -> TokenPrices:
        """Charge the whole machine to output tokens, prompt tokens free.

        The conservative bound for a decode-bound deployment: it is the highest
        per-output-token price the measurements support, so a member that is off the
        frontier even here is off it under any attribution.
        """
        if point.output_tokens_per_s <= 0:
            raise ServingCostError("point produced no output tokens")
        per_1m = self.usd_per_second / point.output_tokens_per_s * TOKENS_PER_MILLION
        return TokenPrices(
            prompt_per_1m=0.0,
            completion_per_1m=per_1m,
            basis=f"output-only at max_num_seqs={point.max_num_seqs}, "
            f"{point.output_tokens_per_s:.0f} out tok/s",
        )

    def split_prices(self) -> TokenPrices:
        """Separate prefill and decode prices, fitted across the sweep.

        The machine is one resource that both phases occupy, so a point's occupancy is
        `prompt_rate / prefill_capacity + output_rate / decode_capacity = 1` when
        saturated. Two unknowns, so two operating points with *different prompt-to-output
        ratios* identify them; points that merely differ in depth do not, and asking for
        a split from those raises rather than returning a number that looks derived.
        """
        saturated = [p for p in self.points if p.total_tokens_per_s > 0]
        if len(saturated) < 2:
            raise ServingCostError("a split needs at least two saturated points")

        ratios = {round(p.prompt_tokens_per_s / max(p.output_tokens_per_s, 1e-9), 2) for p in saturated}
        if len(ratios) < 2:
            raise ServingCostError(
                "every point has the same prompt-to-output ratio, so prefill and decode "
                "capacity are not separately identified; use blended or output-only "
                "prices and say which"
            )

        # Least squares on 1 = x * prompt_rate + y * output_rate, where x and y are the
        # reciprocals of the two capacities.
        s11 = sum(p.prompt_tokens_per_s**2 for p in saturated)
        s22 = sum(p.output_tokens_per_s**2 for p in saturated)
        s12 = sum(p.prompt_tokens_per_s * p.output_tokens_per_s for p in saturated)
        b1 = sum(p.prompt_tokens_per_s for p in saturated)
        b2 = sum(p.output_tokens_per_s for p in saturated)
        determinant = s11 * s22 - s12 * s12
        if abs(determinant) < 1e-18:
            raise ServingCostError("the sweep is collinear; capacities are not identified")
        x = (b1 * s22 - b2 * s12) / determinant
        y = (b2 * s11 - b1 * s12) / determinant
        if x <= 0 or y <= 0:
            raise ServingCostError(
                "the fit implies a non-positive capacity, which means the sweep is not "
                "in the saturated regime it assumes"
            )
        return TokenPrices(
            prompt_per_1m=self.usd_per_second * x * TOKENS_PER_MILLION,
            completion_per_1m=self.usd_per_second * y * TOKENS_PER_MILLION,
            basis=f"prefill/decode split fitted over {len(saturated)} points",
        )

    def cheapest_meeting(self, slo: SLO) -> LoadPoint:
        """The highest-throughput point that satisfies a service level.

        This is what makes the setting a consequence of the SLO rather than a choice
        the operator makes to flatter the price.
        """
        admitted = [p for p in self.points if slo.admits(p)]
        if not admitted:
            raise ServingCostError(
                f"no measured operating point meets SLO {slo.name!r}; the deployment "
                "cannot serve this tier at any batch depth that was tried"
            )
        return max(admitted, key=lambda p: p.total_tokens_per_s)

    def break_even_output_tokens_per_s(self, competitor_completion_per_1m: float) -> float:
        """Output throughput needed to match a commercial per-token price.

        The number that says whether self-hosting is a plan or a wish: compare it
        against what the sweep actually reached.
        """
        if competitor_completion_per_1m <= 0:
            raise ServingCostError("a competitor price must be positive")
        return self.usd_per_second / (competitor_completion_per_1m / TOKENS_PER_MILLION)

    def utilisation_for(self, requests_per_s: float, point: LoadPoint) -> float:
        """What fraction of the capacity a given offered load would occupy.

        The link between a price and a deployment: the prices above assume the machine
        is busy, and real traffic decides whether it is. A router that sends 3% of its
        requests to a dedicated GPU is paying for the other 97%.
        """
        if point.requests_per_s <= 0:
            raise ServingCostError("point served no requests")
        return requests_per_s / point.requests_per_s
