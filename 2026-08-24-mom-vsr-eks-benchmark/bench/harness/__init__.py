"""Measurement harness for the Mixture-of-Models benchmark.

The expensive measurement is one thing only: a correctness matrix over
(question, member), collected by asking every member every question through the
router with the model pinned. Most of the reference lines the report needs —
best single member, cheapest member, an existential upper bound, a uniform
random choice, and any offline per-domain assignment policy — are functions of
that matrix and cost nothing more to produce.

What genuinely needs its own traffic is the router deciding for itself: the
selector's latency and load terms move with live traffic, and end-to-end latency
and failures exist only on the data path.
"""

__all__ = ["catalog", "classify", "client", "dataset", "runner", "score"]
