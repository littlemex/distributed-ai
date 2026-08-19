# Access the agents (self-hosted Qwen3.8-27B backend)

One-shot launchers live in `client/`. Copy `client/agents.sh` + `client/agents.env.example`
anywhere on your Mac (no repo checkout needed), then:

```bash
cp agents.env.example agents.env      # edit if your cluster/profile differ
./agents.sh setup                     # one-time: kubeconfig + ssh key (auto) + ~/.ssh/config
```

Prereqs: `kubectl`, `aws` CLI, `ssh`, `nc`, `python3` (standard on macOS + your AWS setup). You
need active AWS credentials (default profile or SSO) in your shell — the ssh ProxyCommand uses
them to reach EKS.

## ssh into opencode (one shot)

```bash
ssh opencode                          # port-forward is automatic (ProxyCommand); lands in the pod
# then:  opencode
```
Or launch the TUI directly:
```bash
./agents.sh opencode
```
The pod reaches Qwen via the in-cluster Service and does web search via the bedrock-websearch
MCP (AWS creds via Pod Identity). Verified: `opencode run --pure --auto "..."` uses the
`web_search` tool and cites sources.

## OpenClaw in the browser (one shot)

```bash
./agents.sh openclaw                  # background port-forward + opens the Control UI
```
Opens `http://127.0.0.1:18789/#token=qwen-demo-token`. Ask it to "research X" — it auto-uses
Bedrock web search. Stop background port-forwards with `./agents.sh down`.

## ssh into hermes (Nous Research Hermes Agent)

```bash
ssh hermes            # or ./agents.sh hermes
# then:  hermes        (interactive TUI, model ollama/Qwen/Qwen3.8-27B = self-hosted Qwen)
```
Hermes requires >=64K context, so vLLM serves the model at max_model_len 65536. Hermes reaches
Qwen via its OpenAI-compatible "ollama" provider override (OLLAMA_BASE_URL -> in-cluster vLLM).

## Notes

- `agents.sh setup` creates the ssh key (`SSH_KEY` in agents.env) if missing and syncs the public
  key into the pods for you; re-run it any time to re-sync or after redeploying.
- Demo posture: single replicas, ephemeral state, gateway token in a plain Secret, key-based ssh.
