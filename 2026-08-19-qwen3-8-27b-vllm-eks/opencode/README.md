# opencode -> self-hosted Qwen3.8-27B (vLLM on EKS)

opencode is pointed at the vLLM OpenAI-compatible endpoint as a custom provider
(`@ai-sdk/openai-compatible`). Verified end to end: chat and a tool loop (opencode's `read`
tool) both complete against the self-hosted model.

## Connect

```bash
export KCTX=distai-tokyo NAMESPACE=distai
# forward the served model to localhost:8000 (see ../scripts/port-forward.sh)
kubectl --context "$KCTX" -n "$NAMESPACE" port-forward svc/vllm-qwen-qwen3-8-27b 8000:8000 &

# use this directory's opencode.json (baseURL http://localhost:8000/v1)
opencode run --pure --auto --model vllm-local/Qwen/Qwen3.8-27B \
  "Use your read tool to read note.txt and reply with only the secret code it contains."
# -> EMERALD-42
```

In-cluster (opencode running in a pod), replace the baseURL with the Service DNS:
`http://vllm-qwen-qwen3-8-27b.distai.svc.cluster.local:8000/v1`.

## Gotchas (all observed on this bring-up)

- `--pure`: run without external plugins. Plugin loading intermittently hangs the headless
  run; `--pure` avoids it.
- If a headless run hangs right after `init` with no request reaching vLLM, clear stale
  session state and retry: `rm -rf ~/.local/share/opencode/{project,storage}`.
- `--auto`: auto-approve tool permissions (non-interactive runs otherwise block on approval).
- Serve in non-thinking mode (`enable_thinking=false`, set server-side in the overlay): the
  Qwen3-family thinking mode + greedy/low-temp decoding endlessly repeats and stalls the loop.
- `limit.output` in opencode.json must leave headroom under the 32768 context (opencode
  otherwise requests ~32000 output tokens and vLLM rejects the overflow).
