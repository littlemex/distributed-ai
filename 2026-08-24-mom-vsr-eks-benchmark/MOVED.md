# The harness and the routing work moved

This directory is a **dated experiment record**, and by this repository's own rule that means it is
append-only: it records what was true when it ran. Two things in it stopped obeying that rule.

**The episode harness (`agent/`) became a maintained asset.** It was rewritten four times in one week — a
tolerant argument grammar, a second wire protocol, a per-tier thinking switch, a per-tier tiers file — so
the date on this directory had stopped being true of it.

**The routing design was never an experiment record at all.** It is a design that reads the measurements
this directory produced.

Both now live in **[`tierbook`](https://github.com/littlemex/tierbook)**, whose line is *a ledger of what
each inference tier was measured to do, and a router that only reads it.* They are not in this repository
because this one is infrastructure and experiment records; they are not in
[`stratoclave`](https://github.com/littlemex/stratoclave) because its own subtitle says model routing stays
external.

| what | where it is now |
|---|---|
| the routing rule, the tier registry and its schema | `tierbook` — `routing/`, `registry/` |
| the design, and what it deliberately does not claim | `tierbook` — `docs/DESIGN.md` |
| the episode harness | moving to `tierbook` — `harness/` |
| **the measurements, the pre-registrations and the results** | **here, frozen** |

## What stays here, and why it stays

Everything under `docs/` is the record: the pre-registrations that fixed each reading before it was taken,
the results pages, and the corrections in place. `tierbook` cites this directory at a commit rather than
copying it, because a record that can be edited from another repository is not a record.

`vsr/` stays as the configuration of the router that was measured and lost to a single-model baseline. The
harness's own history stays here too — it was rewritten inside this directory, and that history is part of
what happened.

## Reproducing what this directory reports

Use the harness at the revision this directory was frozen at, not the current one in `tierbook`. The
figures here were produced by code that has since changed on purpose: the grammar, the wire, and the
thinking switch all moved the numbers, and each move is documented in `docs/PROTOCOL.md` and
`docs/results-function-calling-arm.md`.
