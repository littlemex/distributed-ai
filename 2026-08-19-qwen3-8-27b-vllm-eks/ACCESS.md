# Accessing the agents

The shell agents are entered with `kubectl exec`, authenticated by your kubeconfig and AWS
credentials. No ssh key or sshd. Only OpenClaw's browser UI uses a background port-forward.

## Install the launcher

```bash
install -m 755 <(curl -fsSL <commit-pinned-raw-url>/client/qwen-agents.sh) ~/.local/bin/qwen-agents
ln -sf ~/.local/bin/qwen-agents ~/.local/bin/qa
```

`qa` resolves the target cluster from `$QWEN_KUBE_CONTEXT`, defaulting to the current kubeconfig
context, and the namespace from `$QWEN_NAMESPACE` (default `qwen`). No env file is required. Prereqs:
`kubectl`, `aws` CLI, `curl`, `python3`, and active AWS credentials.

## Interactive TUIs

```bash
qa opencode      # opencode coding CLI
qa qwen-code     # Qwen Code (gemini-cli fork; binary `qwen`)
qa hermes        # Hermes assistant CLI
```

Each reaches Qwen through the in-cluster `qwen-serving` Service and web search through the
bedrock-websearch MCP tool, which authenticates to Bedrock via EKS Pod Identity.

## Passthrough and shell-only

Arguments after the agent name are forwarded to the wrapped CLI. `-t` / `--shell` drops you at a
pod shell instead of launching the TUI.

```bash
qa qwen-code -r <session-id>          # resume a Qwen Code session
qa qwen-code -p "summarize this repo" # non-interactive prompt
qa -t opencode                        # shell into the pod
```

## Multimodal (images / video)

Agents read files from the pod filesystem and base64-embed them, so a local file is copied into the
pod first:

```bash
qa push ./diagram.png qwen-code       # kubectl-cp into the pod's media dir; prints the pod path
qa qwen-code                          # then in the TUI:  @<pod-path> explain this
```

qwen-code handles both image and video (video is ffmpeg-downsampled by `push`, since the server
samples only a few frames). Its modality gate is model-name based, so `agents/qwen-code/settings.json`
declares `generationConfig.modalities: {image, video}` for the self-hosted model name. opencode takes
images but has no video path; Hermes needs `supports_vision: true`.

## OpenClaw (browser)

```bash
qa openclaw      # background port-forward + open the Control UI
qa down          # stop the background port-forward
```

## Raw kubectl

```bash
kubectl -n "$QWEN_NAMESPACE" exec -it deploy/opencode  -- bash -lc opencode
kubectl -n "$QWEN_NAMESPACE" exec -it deploy/qwen-code -- bash -lc qwen
kubectl -n "$QWEN_NAMESPACE" port-forward svc/openclaw 18789:18789
```

Demo posture: single replicas, ephemeral state, gateway token in a plain Secret.
