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

## qwen-code (interactive TUI)

```bash
./agents.sh qwen-code                 # kubectl exec -it into the pod, launches `qwen`
```
Qwen Code is Qwen's gemini-cli fork. It reaches the self-hosted Qwen via the `openai` auth type
(OpenAI-compatible), baseUrl set to the in-cluster vLLM Service in `~/.qwen/settings.json`;
`security.auth.selectedType=openai` skips the interactive `/auth`. Web search via the same
bedrock-websearch MCP (AWS creds via Pod Identity). Verified: `qwen -p "..."` reaches the backend,
and `qwen --approval-mode yolo -p "use web_search ..."` invokes the tool and cites a source URL.

## Passthrough and shell-only

Everything after the agent name is forwarded verbatim to the wrapped CLI:

```bash
./agents.sh qwen-code -r <session-id>            # resume a Qwen Code session
./agents.sh qwen-code -p "summarize this repo"    # non-interactive prompt
./agents.sh opencode  run "fix the failing test"
```

`-t` / `--shell` logs into the pod at a bash prompt and stops (no TUI), for manual terminal work:

```bash
./agents.sh -t qwen-code
./agents.sh -t opencode
```

## Multimodal (images / video)

Qwen3.8-27B is a VLM; the production vLLM serves images out of the box (verified: it OCR'd a test
image while MTP + YaRN 1M were active — no serving change needed). The agents read files from the
POD filesystem and base64-embed them, so a local file must first be copied into the pod:

```bash
./agents.sh push ./diagram.png qwen-code     # kubectl-cp into the pod's /root/media/
# -> prints: @/root/media/diagram.png
./agents.sh qwen-code                          # then in the TUI:  @/root/media/diagram.png explain this
```

- qwen-code needs image/video modality declared for a self-hosted model whose name isn't `qwen*-vl-*`
  (its modality gate is name-based). This repo's `qwen-code/pod/settings.json` sets
  `generationConfig.modalities: {image:true, video:true}`, so images work (verified E2E).
- Video: `push` ffmpeg-downsamples it first (vLLM only samples a few frames). Video support across
  the CLIs is uneven — opencode has no video path; qwen-code/hermes can emit it but interop with
  vLLM's `video_url` extension is unverified. Images are the reliable path today.
- opencode/hermes can also take images (base64 from a pod path) but each needs its own config
  (opencode: attach the pod path; hermes: `supports_vision: true`); only qwen-code is verified here.

## OpenClaw (browser)

```bash
./agents.sh openclaw                  # background port-forward + opens the Control UI
./agents.sh down                      # stop the background port-forward
```
Opens `http://127.0.0.1:18789/#token=qwen-demo-token`. Ask it to "research X" — it auto-uses
Bedrock web search.

## Raw kubectl (no script)

```bash
kubectl --context distai-tokyo -n distai exec -it deploy/opencode  -- bash -lc opencode
kubectl --context distai-tokyo -n distai exec -it deploy/hermes    -- bash -lc hermes
kubectl --context distai-tokyo -n distai exec -it deploy/qwen-code -- bash -lc qwen
kubectl --context distai-tokyo -n distai port-forward svc/openclaw 18789:18789   # then open the URL
```

## Notes

- No ssh key is used or needed (kubectl exec covers interactive use). If you later want scp/sftp,
  rsync, or VS Code Remote-SSH into a pod, that is when an sshd + key would be worth adding back.
- Demo posture: single replicas, ephemeral state, gateway token in a plain Secret.
