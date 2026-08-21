# Accessing the agents

The shell agents are entered with `kubectl exec`, authenticated by your kubeconfig and AWS
credentials. No ssh key or sshd. Only OpenClaw's browser UI uses a background port-forward.

## Install the launcher

The one-shot installer deploys the stack and puts `qa` on your PATH in a single command; see the
README Quickstart. To install only the launcher without deploying:

```bash
curl -fsSL https://raw.githubusercontent.com/littlemex/distributed-ai/feat/serving-vllm-qwen/2026-08-19-qwen3-8-27b-vllm-eks/client/install.sh | bash -s -- --no-deploy
```

`qa` resolves the context from `$QWEN_KUBE_CONTEXT`, defaulting to the current kubeconfig context,
the namespace from `$QWEN_NAMESPACE` (default `qwen`), and the region from the context's EKS ARN. No
env file is required. Prereqs: `kubectl`, `aws` CLI, `curl`, `python3`, and active AWS credentials.

## Interactive TUIs

```bash
qa opencode
qa qwen-code
qa hermes
```

`opencode` is the opencode coding CLI, `qwen-code` is Qwen Code, a gemini-cli fork whose binary is
`qwen`, and `hermes` is the Hermes assistant CLI.

Each reaches Qwen through the in-cluster `qwen-serving` Service. Web search is opt-in: when the stack
is deployed with `--websearch`, the agents also get the bedrock-websearch tool, which authenticates
to Bedrock via EKS Pod Identity. Without it, the agents run without web search.

## Passthrough and shell-only

Arguments after the agent name are forwarded to the wrapped CLI. `-t` / `--shell` drops you at a
pod shell instead of launching the TUI.

```bash
qa qwen-code -r <session-id>
qa qwen-code -p "summarize this repo"
qa -t opencode
```

The first resumes a Qwen Code session, the second runs a non-interactive prompt, and `-t` shells
into the pod instead of launching the TUI.

## Multimodal (images / video)

Agents read files from the pod filesystem and base64-embed them, so a local file is copied into the
pod first:

```bash
qa push ./diagram.png qwen-code
qa qwen-code
```

`push` kubectl-cp's the file into the pod's media directory and prints the pod path; reference that
path in the TUI, for example `@<pod-path> explain this`.

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
