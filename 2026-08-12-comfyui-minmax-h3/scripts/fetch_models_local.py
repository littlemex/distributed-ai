# /// script
# requires-python = ">=3.10"
# dependencies = ["huggingface_hub>=0.34", "pyyaml"]
# ///
"""Download a preset's weights into a local ComfyUI models folder (for a desktop GPU).

Reads the same `modelSets` list the in-cluster model-fetch Job uses, so a home machine and the
cluster run identical weights:

    uv run scripts/fetch_models_local.py charts/comfyui/presets/qwen-image.yaml ~/comfyui/models

Files already present with the expected size are skipped, so the command can be re-run.
"""
import os
import shutil
import sys

import yaml
from huggingface_hub import HfApi, hf_hub_download


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    preset, root = sys.argv[1], os.path.expanduser(sys.argv[2])
    sets = (yaml.safe_load(open(preset)) or {}).get("modelSets") or []
    if not sets:
        sys.exit(f"{preset} has no modelSets")
    os.environ.setdefault("HF_HUB_DISABLE_XET", "1")
    api = HfApi()
    for mset in sets:
        repo, rev = mset["repo"], mset.get("revision") or "main"
        try:
            expected = {s.rfilename: s.size for s in (api.repo_info(repo, revision=rev, files_metadata=True).siblings or []) if s.size}
        except Exception as e:  # noqa: BLE001
            print(f"[warn] {repo}: no metadata ({e}); checking size > 0 only")
            expected = {}
        for f in mset["files"]:
            rel, sub = f["file"], f["targetDir"]
            dest = os.path.join(root, sub)
            os.makedirs(dest, exist_ok=True)
            final = os.path.join(dest, os.path.basename(rel))
            want = expected.get(rel)
            if os.path.exists(final) and ((want and os.path.getsize(final) == want) or (not want and os.path.getsize(final) > 0)):
                print(f"[skip] {sub}/{os.path.basename(rel)}")
                continue
            print(f"[get ] {repo} :: {rel}", flush=True)
            p = hf_hub_download(repo_id=repo, filename=rel, revision=rev, local_dir=dest + ".dl")
            shutil.move(p, final)
            shutil.rmtree(dest + ".dl", ignore_errors=True)
            print(f"[done] {sub}/{os.path.basename(rel)} ({os.path.getsize(final)} bytes)", flush=True)
    print(f"[all ] weights under {root}")


if __name__ == "__main__":
    main()
