# What the router should be, from six independent designs against the measured record

**Written 2026-08-30.** Three pairs of advisors — `claude-fable-5` and `gpt-5.6-sol`, independently, on
three framings (architecture, decision theory, adversarial) — were given the whole measured record and one
hard constraint: **the design must not depend on these particular models.** The current tier list is an
acceptable default, not an assumption. A new checkpoint, a new vendor, a price change, a different
tool-calling dialect, or a different cache behaviour must all be admissible without re-deriving the
mechanism.

All six converged on a design smaller than "router" usually implies. This page records it, the two places
they disagreed, the one idea none of the earlier work had, and a correction they made to a claim this
project has been publishing.

## The design

> **Offline, per traffic family: assign the cheapest tier whose measured outcome on that family's frozen
> benchmark set is non-inferior to the family's reference tier at a margin fixed in advance, scored out of
> fold. Online, per request: map it to a family, send it to the assigned tier, and escalate only on
> observable failure. Never escalate on a soft judgement of quality.**

Six pieces make that model-agnostic.

### 1. A tier is a record of measurements, not a model name

```
tier = { adapter and measured protocol compliance,
         price card per request shape (fresh / cached / output),
         latency distribution (not a mean),
         failure rate φ with the distribution of spend sunk before death,
         per-family outcome vector,
         cache behaviour measured under intervening traffic,
         hard eligibility: context window, modalities, residency, tool semantics }
```

Nothing in the routing logic reads a model name, a vendor, or a published figure where a measured one
exists. Advertised numbers are inadmissible on the record's own evidence: the reusable prefix cache
measured at 7-14% of the engine's advertised capacity, and a gateway's own rate card once priced one model
17× wrong.

### 2. The decision unit is the family, decided offline; the request is only classified into one

The record is one-sided on this. On the held-out eight all three tiers solved the same eight instances and
missed the same one, at a 20× price spread — the value was in *the set*, not in any per-request property.
Meanwhile a learned per-request router lost 3.6 accuracy points, added 12.8 s, and its selector named one
member for 96% of requests, which is a family assignment made expensively. And an offline per-domain
assignment overfit and lost 2.5 points out of fold.

Family assignment needs only "is tier A non-inferior to the reference on this set?", which ~20 paired
instances can answer at a coarse margin. Per-request selection needs a difficulty signal validated at
finer resolution than that, and no such signal exists in the record.

**A tier is never switched inside an agentic episode on a hunch about an intermediate turn.** That changes
the intervention being measured and complicates state, caching and attribution.

### 3. Escalation fires only on observable failure

The only precision-1.00 signals the record shows to exist are mechanical:

- a transport error, or a 200 with an empty stream;
- an unusable action stream (adapter-level malformation);
- budget exhausted — steps, tokens, or wall clock — **with no artifact produced**;
- any check that can *reject* with certainty: a patch that does not apply, output that does not parse
  against a declared schema, a required field absent.

All of these are in the safe polarity: a spurious escalation costs one attempt. The dangerous direction —
keeping a wrong answer — cannot be triggered by any of them.

**The slot for a semantic success detector exists in the rule and is empty.** Three families were closed
against a pre-registered keep-precision bar of 1.00 (best 0.78, with every error in the dangerous
direction). If one ever clears that bar on a held-out fold, it plugs in as an additional escalation
trigger; it does not become a redesign.

### 4. Retries are dollars, and latency is priced rather than ranked

Effective cost of calling tier *t* is **not** its bill:

```
c_eff(t) = bill(t) + φ_t/(1 − φ_t) · E[spend sunk before death]
```

With the measured φ = 4/24 and mean sunk $4.4212 that is $0.8842 of expected extra per attempted call, and
it is what re-ranked the arrangements: the chain that calls the unreliable tier four times beats the one
that calls it six, even though the latter had the lower bill. **Putting retries in the cost function makes
that fall out of the arithmetic instead of being a special case.**

Latency enters as a per-family shadow price λ applied to the *SLO percentile*, not the mean — chains stack
tails, and one tier's p95 is 501 s against another's 130 s. On this record the no-box arrangement and the
box-first arrangement cross at roughly **$0.16 per minute of median task time**; above that the
arrangement with no machine wins on the same data that says it costs 19% more.

### 5. Fixed capacity is an hourly amortisation switch, not a per-request decision

A self-hosted tier's effective rate is `max(measured token rates, hourly cost ÷ realised tasks per hour)`.
On this record the switch flips at 319 tasks an hour against a measured 616 at sixteen concurrent
episodes. So a fixed-cost tier is admissible as a prefix tier **only while fleet utilisation is certified
above its break-even**, and that is decided per hour from realised throughput, never per request.

### 6. The cascade lives in a gateway, and the ledger records what failures cost

Not the client — every client would re-implement retries and no one could centralise cost accounting. Not
a per-model sidecar — the decision spans tiers.

For the arrangement arithmetic to survive contact with production:

- **attempts are hermetic**: a fresh sandboxed workspace per attempt, so a retry is a restart and tool
  side-effects need no cross-attempt idempotence — the workspace is the idempotence boundary;
- **sunk spend is a first-class ledger entry**, because a ledger that records only successful bills would
  have ranked these arrangements wrong;
- **failure rates are tracked live per tier**, because which tier is currently unreliable is an empirical
  and changing fact, and the ordering must be recomputed from it;
- **budget caps per attempt**, since late death is the expensive failure mode;
- **every decision is reproducible** from versioned inputs, so an incident can be replayed.

## Where the six disagreed, and the reconciliation

**Per-request refinement.** One pair-1 advisor wants family assignment only; the other wants a family
policy with optional per-request refinement **and an abstain region**. These reconcile if abstention
defaults to the family's assigned tier: refinement is allowed to move a request to a *cheaper* tier only
where held-out evidence supports non-inferiority for that region, and abstains otherwise. That way the
mechanism degrades to family assignment when no such evidence exists, which is today.

**What the small model is for.** Neither pair-1 advisor will let a BERT-class classifier choose tiers on
this evidence, and both give the same reasons: no production labels, ~20 labelled instances per family, and
a measured base rate of learned routers losing here. They differ on what it *is* good for:

- as a **family identifier**, when request metadata is insufficient to map traffic to a family. Its target
  is a coarse auditable label, its failure mode is bounded by the worst family assignment, and if metadata
  suffices it is deleted;
- as an **abstaining pairwise sufficiency estimator** — frozen embeddings plus regularised logistic
  regression, not a fine-tune — predicting whether a cheaper candidate is safe *relative to a reference
  tier for this family*, trained only on paired offline evaluations of the same items across tiers.

Both are admissible; neither is the router. The gate for either is the same and is pre-registered:
**leave-one-family-out validation, a final untouched holdout, a non-inferiority margin and threshold fixed
in advance, and a lower confidence bound on routed quality inside that margin.** Classifier AUC is not the
metric; routed outcome is. Failing the gate means zero routing authority.

## The one idea none of the earlier work had

The record diagnosed why the in-repository test signal is inverted: **SWE-bench's judging tests are
`fail_to_pass` tests, which by construction are absent from the checkout.** One advisor turned that around:

> **A requester-supplied failing reproduction test *is* a `fail_to_pass` test, present at inference time.**

Where a request arrives with an executable acceptance check, the oracle that the whole cascade analysis
assumed and could not find **exists**, and the 15.9% saving becomes realisable for that traffic. The
verification problem stops being "build a detector" and becomes **"measure what fraction of production
requests carry their own acceptance check, and route those differently."**

That is the first measurement to make on real traffic, it needs no model work, and it is the only thing in
this design that could reopen the cheap-first cascade.

## A correction to a claim this project has been publishing

Two advisors independently caught the same overreach. This project has been writing "**routing cannot
raise quality**", justified by the strict nesting found between tiers. The nesting is real for the
**pairs** measured — zero counterexamples in twenty, on two corpora. But the knowledge-question round also
recorded an `oracle: any correct` accuracy of **0.9596** against the best single member's **0.9105**, over
a ten-member pool. That gap is only possible if some questions are answered correctly by members other
than the best one — **so nesting does not hold over the pool, only over the chains tested.**

The claim is therefore narrowed wherever it appears: *routing cannot raise quality along a chain whose
tiers are nested, and nesting is a per-family, per-pair empirical property that has to be re-certified at
admission rather than assumed.* The 4.9 points of oracle headroom on that corpus were never captured by
any implemented router, which is why the design still does not chase them — but "cannot" was the wrong
word and it is withdrawn.

## Defaults

The mechanism above, instantiated on what is measured today:

| family | reference tier | assigned tier | escalation |
|---|---|---|---|
| agentic coding | `claude-fable-5` | **`claude-fable-5`** | observable failure only |
| agentic coding, if a request carries an executable acceptance check | `claude-fable-5` | **self-hosted box → `gpt-5.6-terra` → `claude-fable-5`** | the check, plus observable failure |
| knowledge questions | best single member on the calibration fold | **that single member** | observable failure only |

The self-hosted tier is otherwise **not assigned**: its saving needs a signal that does not exist for
unverified traffic, its latency is worse than the cheap API's at every percentile, and its fixed cost needs
utilisation above 319 tasks an hour. The three-stage chain is the default *only* for verifier-bearing
traffic, because that is where the oracle the arithmetic assumes actually exists — and it is the chain that
wins once retries are priced.

## Parameters this design needs and nobody has measured

Named so they are requested rather than assumed: the value of a second per family (λ); the cost of an
escaped defect per family, which decides everything — at $1 the cheap tier ships, at $100 the required
keep-precision is 0.993, at $10,000 it is 0.99993 and no affordable sample can certify it; the production
family mix and arrival distribution, for the amortisation switch; the fraction of requests carrying an
executable acceptance check; cache hit rates under real request shapes; and the joint, not marginal,
outcome distribution between tiers.

Until λ and the defect cost are supplied there is no unique optimum — only a Pareto frontier, and this
page's defaults are the corner of it that assumes defects are expensive and seconds are cheap.
