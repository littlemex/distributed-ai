#!/usr/bin/env python3
"""run_smoke.py — submit a ComfyUI API-format workflow, wait, and download the video.

Drives a ComfyUI instance reached over `kubectl port-forward` (default
http://localhost:8188). It posts an API-format workflow to /prompt, polls /history for
completion, and downloads every produced video (or image/audio) via /view. This is
model-agnostic: point it at the MiniMax-H3 T2V API workflow to generate one clip end to end.

Why API format: the /prompt endpoint needs the flat API JSON, not the UI template. Export it
once from the Web UI (Save (API Format)) — see ../workflows/README.md.

Usage:
  # 1) port-forward in another shell:
  #    kubectl -n comfyui port-forward svc/comfyui 8188:8188
  # 2) run one generation:
  python3 run_smoke.py ../workflows/video_minimax_h3_t2v.api.json --out ./out

  # override the prompt text / seed without editing the JSON:
  python3 run_smoke.py wf.api.json --prompt "a red fox running through snow, cinematic" --seed 42

Only depends on the Python 3 standard library (urllib) — no pip install needed.
"""
import argparse
import json
import os
import sys
import time
import urllib.request
import urllib.parse
import urllib.error


def http_json(url, payload=None, timeout=30):
    data = json.dumps(payload).encode() if payload is not None else None
    headers = {"Content-Type": "application/json"} if data else {}
    req = urllib.request.Request(url, data=data, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())


def http_bytes(url, timeout=120):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return r.read()


def find_text_and_seed_nodes(wf):
    """Discover candidate prompt-text and seed inputs. Returns (text_keys, seed_keys) as lists
    of (node_id, input_name). A typical T2V graph has BOTH a positive and a negative text node,
    and both match the text heuristic — so the caller must NOT blindly write --prompt to every
    hit (that would clobber the negative prompt). main() handles the ambiguity explicitly."""
    text_keys, seed_keys = [], []
    for nid, node in wf.items():
        inputs = node.get("inputs", {})
        for name, val in inputs.items():
            lname = name.lower()
            if isinstance(val, str) and ("prompt" in lname or lname == "text") and len(val) > 8:
                text_keys.append((nid, name))
            if lname in ("seed", "noise_seed") and isinstance(val, (int, float)):
                seed_keys.append((nid, name))
    return text_keys, seed_keys


def main():
    ap = argparse.ArgumentParser(description="Submit a ComfyUI API workflow and fetch the output.")
    ap.add_argument("workflow", help="path to an API-format workflow JSON (Save (API Format) from the UI)")
    ap.add_argument("--server", default=os.environ.get("COMFYUI_SERVER", "http://localhost:8188"),
                    help="ComfyUI base URL (default http://localhost:8188 — the port-forward)")
    ap.add_argument("--out", default="./out", help="directory to write outputs into")
    ap.add_argument("--prompt", default=None, help="override the positive prompt text")
    ap.add_argument("--prompt-node", default=None,
                    help="node id whose text input --prompt writes to. REQUIRED when the workflow "
                         "has more than one text input (positive + negative) — otherwise --prompt "
                         "would clobber the negative prompt too. Run --list-text-nodes to see them.")
    ap.add_argument("--list-text-nodes", action="store_true",
                    help="print the candidate text/seed nodes in the workflow and exit")
    ap.add_argument("--seed", type=int, default=None, help="override the sampler seed")
    ap.add_argument("--timeout", type=int, default=3600, help="max seconds to wait for the run (default 1h)")
    ap.add_argument("--poll", type=float, default=3.0, help="history poll interval seconds")
    args = ap.parse_args()

    with open(args.workflow) as f:
        wf = json.load(f)
    if "nodes" in wf and "class_type" not in next(iter(wf.values()), {}):
        sys.exit("This looks like a UI-format workflow (has 'nodes'). Export API format from the "
                 "ComfyUI Web UI (Save (API Format)) — see ../workflows/README.md.")

    text_keys, seed_keys = find_text_and_seed_nodes(wf)

    if args.list_text_nodes:
        print("Text inputs (node_id.input : class_type : current value preview):")
        for nid, name in text_keys:
            cls = wf[nid].get("class_type", "?")
            val = str(wf[nid]["inputs"][name])[:60].replace("\n", " ")
            print(f"  {nid}.{name}  [{cls}]  {val!r}")
        print("Seed inputs:")
        for nid, name in seed_keys:
            print(f"  {nid}.{name}  = {wf[nid]['inputs'][name]}")
        return

    # Optional overrides.
    if args.prompt is not None:
        if args.prompt_node is not None:
            targets = [(nid, name) for nid, name in text_keys if nid == args.prompt_node]
            if not targets:
                sys.exit(f"--prompt-node {args.prompt_node} matches no text input. "
                         f"Run --list-text-nodes to see valid ids.")
        elif len(text_keys) == 0:
            sys.exit("--prompt given but no prompt-text input found. Run --list-text-nodes.")
        elif len(text_keys) > 1:
            ids = ", ".join(sorted({nid for nid, _ in text_keys}))
            sys.exit(f"--prompt is ambiguous: {len(text_keys)} text inputs (nodes: {ids}). A T2V "
                     f"workflow has both a positive and a negative prompt — writing to all of them "
                     f"would clobber the negative. Pass --prompt-node <id> (see --list-text-nodes), "
                     f"or edit the workflow JSON directly.")
        else:
            targets = text_keys
        for nid, name in targets:
            wf[nid]["inputs"][name] = args.prompt
            print(f"[set ] prompt -> node {nid}.{name}")
    if args.seed is not None:
        if not seed_keys:
            print("[warn] --seed given but no seed input found; using the workflow's own seed")
        for nid, name in seed_keys:
            wf[nid]["inputs"][name] = args.seed
            print(f"[set ] seed {args.seed} -> node {nid}.{name}")

    os.makedirs(args.out, exist_ok=True)
    server = args.server.rstrip("/")

    # Submit.
    print(f"[post] {server}/prompt")
    try:
        resp = http_json(f"{server}/prompt", {"prompt": wf})
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        sys.exit(f"/prompt rejected the workflow (HTTP {e.code}). ComfyUI validation error:\n{body}")
    except urllib.error.URLError as e:
        sys.exit(f"cannot reach ComfyUI at {server} ({e.reason}). Is the port-forward running? "
                 f"See scripts/port-forward.sh.")
    pid = resp.get("prompt_id")
    if not pid:
        sys.exit(f"no prompt_id in response: {resp}")
    print(f"[ ok ] queued prompt_id={pid}")

    # Poll for completion. A history entry appears only once the run finishes; while it is
    # queued/running the entry is absent, so relying on entry.status alone can hang. We treat
    # the run as done when the history entry has outputs (or an explicit completed flag), as
    # errored when status says so, and otherwise confirm the prompt is still in the queue —
    # if it is neither in the queue NOR in history, something dropped it and we fail fast.
    deadline = time.time() + args.timeout
    while time.time() < deadline:
        entry = http_json(f"{server}/history/{pid}").get(pid)
        if entry:
            status = entry.get("status", {})
            if status.get("status_str") == "error":
                sys.exit(f"run errored: {json.dumps(status, indent=2)}")
            if status.get("completed") or entry.get("outputs"):
                print("[ ok ] run completed")
                break
        else:
            # Not in history yet — confirm it is still queued or executing.
            q = http_json(f"{server}/queue")
            running = [x for x in q.get("queue_running", []) if pid in json.dumps(x)]
            pending = [x for x in q.get("queue_pending", []) if pid in json.dumps(x)]
            if not running and not pending:
                # Give history one more read in case of a race between /queue and /history.
                if not http_json(f"{server}/history/{pid}").get(pid):
                    sys.exit(f"prompt {pid} is neither in the queue nor in history — it was "
                             f"dropped (server restart?) or interrupted. Check the ComfyUI logs.")
        time.sleep(args.poll)
    else:
        sys.exit(f"timed out after {args.timeout}s waiting for prompt {pid}")

    # Collect outputs from every node.
    outputs = http_json(f"{server}/history/{pid}")[pid].get("outputs", {})
    saved = 0
    for nid, out in outputs.items():
        # ComfyUI groups outputs by media kind; videos land under "videos"/"gifs", images under
        # "images", audio under "audio". Each item has filename/subfolder/type for /view.
        for kind in ("videos", "gifs", "images", "audio"):
            for item in out.get(kind, []):
                q = urllib.parse.urlencode({
                    "filename": item["filename"],
                    "subfolder": item.get("subfolder", ""),
                    "type": item.get("type", "output"),
                })
                data = http_bytes(f"{server}/view?{q}")
                dest = os.path.join(args.out, item["filename"])
                with open(dest, "wb") as f:
                    f.write(data)
                print(f"[save] {kind}: {dest} ({len(data)} bytes)")
                saved += 1
    if saved == 0:
        sys.exit("run completed but produced no downloadable outputs — check the workflow's "
                 "SaveVideo/output nodes and the ComfyUI logs.")
    print(f"[done] {saved} output file(s) in {args.out}")


if __name__ == "__main__":
    main()
