
## The fragility to know about

The upstream pod IPs are rendered at apply time, which means **any redeploy of the serving Deployment
silently breaks this router** — nginx keeps proxying to addresses that no longer exist. It happened once
here: a redeploy replaced both pods, and the router kept its old config until it was re-rendered.

That is a deliberate trade for the A/B — resolving a headless Service inside nginx needs either the
commercial resolver or a sidecar that rewrites the config, and neither belongs in an experiment. But it
means the rule is: **re-render this after every serving deploy**, and if a run reports an unexplained drop
in cache hits, check the upstream list before anything else.
