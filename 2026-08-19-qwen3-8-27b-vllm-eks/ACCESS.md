# Access: browser -> OpenClaw, ssh -> opencode

Both agents run in the `distai` namespace on `distai-eks` (ap-northeast-1) and use the
self-hosted Qwen3.8-27B (vLLM) as their model, with web search via Bedrock (Pod Identity).
Use the `distai-tokyo` kube context (from `aws eks update-kubeconfig --name distai-eks --region ap-northeast-1`).

## Browser -> OpenClaw (always-on agent, Control UI)

```bash
kubectl --context distai-tokyo -n distai port-forward svc/openclaw 18789:18789
```
Then open: http://127.0.0.1:18789/#token=qwen-demo-token
(Chat, cron/autonomous jobs, memory. Ask it anything; "research X" auto-uses Bedrock web search.)

## SSH -> opencode (interactive coding agent)

```bash
kubectl --context distai-tokyo -n distai port-forward deploy/opencode-ssh 2222:22
# in another terminal (private key from setup):
ssh -p 2222 -i /Users/akazawt/tmp/qwen/ssh/opencode_ed25519 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost
# inside the pod:
opencode                                   # interactive TUI, model vllm-local/Qwen/Qwen3.8-27B
# or non-interactive:
opencode run --pure --auto "Use web_search to find the latest Go version and cite the source."
```

Notes:
- The opencode pod reaches Qwen via the in-cluster Service (no port-forward needed for the model),
  and web search via the bedrock-websearch MCP (AWS creds via Pod Identity).
- Demo posture: single replica, ephemeral state, gateway token in a plain Secret, key-based ssh.
