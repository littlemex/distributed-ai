# Access the agents (self-hosted Qwen3.8-27B backend)

Keyless: the shell agents are entered with `kubectl exec` (authenticated by your kubeconfig /
AWS creds) — no ssh key, no sshd. Only OpenClaw's browser UI uses a background port-forward.

One-shot launchers live in `client/`. Copy `client/agents.sh` + `client/agents.env.example`
anywhere on your Mac (no repo checkout needed):

```bash
cp agents.env.example agents.env      # edit if your cluster/profile differ
./agents.sh setup                     # one-time: create the kubeconfig context
```

Prereqs: `kubectl`, `aws` CLI, `curl`, `python3`, and active AWS credentials in your shell.

## opencode (interactive TUI)

```bash
./agents.sh opencode                  # kubectl exec -it into the pod, launches opencode
```
Reaches Qwen via the in-cluster Service; web search via the bedrock-websearch MCP (AWS creds via
Pod Identity). Verified: `opencode run --pure --auto "..."` uses the `web_search` tool and cites
sources.

## hermes (interactive TUI)

```bash
./agents.sh hermes                    # kubectl exec -it into the pod, launches hermes
```
Model is `ollama/Qwen/Qwen3.8-27B` = the self-hosted Qwen via the OpenAI-compatible "ollama"
provider override. Hermes requires >=64K context, so vLLM serves max_model_len 65536.

## OpenClaw (browser)

```bash
./agents.sh openclaw                  # background port-forward + opens the Control UI
./agents.sh down                      # stop the background port-forward
```
Opens `http://127.0.0.1:18789/#token=qwen-demo-token`. Ask it to "research X" — it auto-uses
Bedrock web search.

## Raw kubectl (no script)

```bash
kubectl --context distai-tokyo -n distai exec -it deploy/opencode -- bash -lc opencode
kubectl --context distai-tokyo -n distai exec -it deploy/hermes   -- bash -lc hermes
kubectl --context distai-tokyo -n distai port-forward svc/openclaw 18789:18789   # then open the URL
```

## Notes

- No ssh key is used or needed (kubectl exec covers interactive use). If you later want scp/sftp,
  rsync, or VS Code Remote-SSH into a pod, that is when an sshd + key would be worth adding back.
- Demo posture: single replicas, ephemeral state, gateway token in a plain Secret.
