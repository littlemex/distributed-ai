# OpenClaw — always-on autonomous agent, backed by self-hosted Qwen3.8-27B

OpenClaw (MIT, openclaw/openclaw) is a self-hosted, always-on personal agent: a Gateway
process (Control UI + agent runtime + cron scheduler + chat channels) that keeps running so
the agent can act on its own. Here it runs as a CPU-pod Deployment on `distai-eks` and uses
the in-cluster vLLM Qwen3.8-27B Service as its model — no cloud LLM, no Kiro subscription.

Why OpenClaw (not Kiro Crew / NemoClaw): all three are the same "autonomous agent" family.
Kiro Crew is a proprietary AWS subscription product; NVIDIA NemoClaw is an alpha secure
sandbox for such agents targeting DGX/WSL (not EKS). OpenClaw is OSS, has a public image,
and ships a bundled vLLM provider — the cleanest fit for an always-on agent in a pod on a
self-hosted model.

## What is deployed

`openclaw.yaml` = Secret (gateway token) + Deployment + Service.
- Image `ghcr.io/openclaw/openclaw:2026.3.1` on the `cpu` pool (`karpenter.sh/do-not-disrupt`
  so the idle-consolidating CPU pool does not evict it).
- Start command seeds config non-interactively (a custom OpenAI-compatible provider `qwen-eks`
  pointed at `http://vllm-qwen-qwen3-8-27b:8000/v1`, primary model `qwen-eks/Qwen/Qwen3.8-27B`)
  then runs `openclaw gateway run`. State is ephemeral (re-seeds on restart — fine for a demo).
- Gateway/Control UI on port 18789.

## Use

```bash
export KCTX=distai-tokyo NAMESPACE=distai
kubectl --context "$KCTX" -n "$NAMESPACE" apply -f openclaw.yaml

# one-shot agent turn (runs against self-hosted Qwen)
POD=$(kubectl --context "$KCTX" -n "$NAMESPACE" get pods -l app=openclaw -o jsonpath='{.items[0].metadata.name}')
kubectl --context "$KCTX" -n "$NAMESPACE" exec "$POD" -- openclaw agent --agent main -m "Reply with one word: pong"

# web Control UI: port-forward, then open the printed URL with the token fragment
kubectl --context "$KCTX" -n "$NAMESPACE" port-forward svc/openclaw 18789:18789 &
# browser: http://127.0.0.1:18789/#token=qwen-demo-token
```

Enter the pod (PFN sshpod style) with `kubectl exec` or a sshpod ProxyCommand for scp/ssh
tooling. Cron/scheduled autonomous jobs: `openclaw cron` (Gateway scheduler).

## Verified

- Deployment ready; `openclaw agent` returns `pong` and the vLLM Service logs the request —
  OpenClaw drives the self-hosted Qwen3.8-27B end to end.
- Control UI reachable via port-forward (root + canvas return 200).

## Notes / gotchas

- `--auth-choice vllm` requires interactive mode (it probes 127.0.0.1:8000). For a headless
  pod use `--auth-choice custom-api-key` with `--custom-base-url` pointed at the Service; the
  harmless "Failed to discover vLLM models" line is that probe, not the working provider.
- Serve Qwen in non-thinking mode (done in the vLLM overlay): thinking + greedy decoding
  endlessly repeats and stalls agent loops.
- Demo posture only: single replica, ephemeral state, token in a plain Secret, port-forward
  access. Persist `~/.openclaw` on a PVC and use a real secret store for anything beyond a demo.
