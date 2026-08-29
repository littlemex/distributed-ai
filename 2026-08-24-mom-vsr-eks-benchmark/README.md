# Where the cheap tier can replace the expensive one, measured twice

Two questions were asked in this directory, with different units and different answers.

**Per question, on knowledge work** (`docs/RESULTS.md`): 693 MMLU-Pro questions, ten pool members
through one gateway. Routing did not buy accuracy; choosing a better single model bought 40% of the cost.

**Per solved task, on agentic coding** (this page): SWE-bench Verified instances attempted end to end by
one tier at a time, scored by each repository's own tests. **Capability is nested along the chain measured, so
routing cannot raise quality along it — and the arrangement that wins depends on which axis you price.**

## The agentic result as it now stands

Twenty-four instances selected by a rule fixed in advance, twenty usable after dropping episodes lost to
transport. Three tiers: a self-hosted `Qwen3.6-35B-A3B-FP8` box (g6e.12xlarge, $15.2174/h),
`gpt-5.6-terra` and `claude-fable-5` through one gateway. Function calling on every tier, reasoning on
every tier.

| tier | solved | bill | per solved task | p50 latency |
|---|---|---|---|---|
| box | 14/20 | $0.8997 | $0.0643 | 76 s |
| `gpt-5.6-terra` | 16/20 | $2.9545 | $0.1847 | 66 s |
| `claude-fable-5` | 20/20 | $14.5899 | $0.7295 | 97 s |

**Capability is strictly nested with zero counterexamples in twenty.** Everything the box solved, terra
solved; everything terra solved, fable solved. **Narrowed 2026-08-30:** that is a property of these pairs,
not of a model pool — the knowledge-question round's any-correct oracle over ten members reached 0.9596
against the best single member's 0.9105, which requires some questions to be answered by members other than
the best. Nesting is re-certified per family at admission rather than assumed; see `docs/ROUTING-DESIGN.md`. So the only saving available is "attempt a cheap tier,
escalate what it fails", and three things decide whether that is worth doing.

**In dollars, with a perfect failure signal**, the box earns 15.9% over an arrangement with no machine in
it ($5.0412 against $5.9960), and needs 319 tasks an hour to cover its own bill — inside its measured
throughput of 616 an hour at sixteen concurrent episodes.

**In seconds, the arrangement with no box is fastest** at every percentile (p50 67 s against 82 s). The
remote cheap API is faster than the local GPU, because the box needs about 31 steps where terra needs 15.

**In failures, the ordering inverts.** The premium tier failed 4 of 24 episodes — always the gateway
answering 200 with an empty stream — and the $17.6850 sunk on those four exceeds its entire successful
bill, because they die at 5, 12, 25 and 28 steps. Priced as retries, the three-stage cascade becomes
cheapest at $8.7831 and box → expensive becomes dearest at $10.3467, because it calls the unreliable tier
six times where the others call it four.

**And the 15.9% cannot be collected**, because it needs a signal saying when to keep the box's patch.
Three families of candidate were eliminated against bars fixed before looking: signals inside the episode
reach keep-precision 0.77, self-consistency cannot pay for itself at any k above 2.06, and a cheap-tier
judge on the patch reaches 0.78 with every error in the dangerous direction.

**So: do not self-host for this traffic.** Four things would change that, and each is stated as a
measurement rather than an argument — sustained volume above ~320 tasks an hour on prefix-reusing
traffic, a verification signal from outside the repository's own tests, a traffic family where the box's
solve set is *not* a subset, or a requirement the APIs cannot meet at any price.

## Read in this order

| document | what it settles |
|---|---|
| `docs/PROTOCOL.md` | the harness's own text protocol was costing one tier 42% of its actions; the grammar, frozen, and the diagnostic arm that measured it |
| `docs/results-function-calling-arm.md` | the three tiers on one footing, and the two comparators that had to be un-handicapped first |
| `docs/results-escalation-and-the-box.md` | the arrangements priced, the volume the machine needs, and the three closed signal families |
| `docs/results-time-and-reliability.md` | the same arrangements in seconds and in failures, where the ordering inverts |
| `docs/PREREG-failure-signal.md` | what was fixed before each look, including the readings that would have overturned the conclusion |
| `docs/ROUTING-DESIGN.md` | what the router should be, from six independent designs, with the defaults and the parameters nobody has measured |
| `docs/PREREG-kv-cliff.md` | why advertised cache capacity is not reusable capacity, and why the engine's occupancy gauge is not an alarm |
| `agent/README.md` | the harness itself |
| `docs/V3-PLAN.md`, `docs/PILOT.md`, `docs/POWER.md` | what was pre-registered before any of it ran |

## Numbers that have been superseded, and by what

Six figures in this directory were wrong at some point and are corrected in place. They are listed here
so a reader who found one in an older commit knows it moved, and why.

| was | is | why it moved |
|---|---|---|
| box solves 0, "cannot hold the format" | 14/20 under function calling | the text protocol was a near-miss of the syntax the model was trained to emit |
| box costs 2.61× terra per solved task | box costs **2.61× less** | the first figure priced a grammar, not a model |
| box's solve set is a *superset* of terra's | a strict **subset** | the comparator had been run with its reasoning switched off |
| the box's thinking should be on | off, at this budget | 3.4× the output tokens, 1.90× the bill, one solve fewer |
| unusable actions 45.2% | 41.9% | a successful `list_dir` with no argument was being counted as a failure |
| "share of the oracle gap recovered" per rule | withdrawn | bills may only be compared at equal quality; a rule that ships a wrong patch is not cheaper |

Two of those were caused by measuring a weakened comparator, in opposite directions, three weeks apart.
That is the failure mode this directory is most prone to, and it is why every later reading was written
down before the data was opened.

## What is deliberately not here

**The agentic family is not in `benchctl/specs/routing-table.json`.** That table holds per-item verdicts
for families whose unit is an item — a page, a document, a question — and merges new models into existing
items. An agentic episode's unit is a task attempted end to end by a policy, and its cost depends on the
trajectory rather than on the item, so putting it in the table would need a mapping that does not exist.
The agentic verdicts live in the pages above.

**No claim about the target traffic.** Everything here is a public benchmark. The project's own rule is
that no admission can be made until the work actually being routed is measured, and that has not
happened.
