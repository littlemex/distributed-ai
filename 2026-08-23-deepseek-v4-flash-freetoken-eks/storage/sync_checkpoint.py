"""Stream a Hugging Face checkpoint into the S3 Files model-cache bucket, one file at a time.

Run by storage/sync-checkpoint.sh as an in-cluster Job. Two properties matter:

* **Bounded disk.** Download a file, upload it, delete it. Peak scratch is the largest single
  shard, not the whole checkpoint -- the difference between 60 GiB of emptyDir and 160 GB for
  DeepSeek-V4-Flash.
* **Directory structure preserved verbatim.** DeepSeek-V4 checkpoints keep their authoritative
  model args in an ``inference/config.json`` subdir and FreeToken reads them from there, so a
  transfer that flattens paths produces a checkpoint that fails to load with every shard present.
  Keys are written as ``<repo_id>/<path_in_repo>``.

Resumable: a file already in S3 with a matching size is skipped, so a re-run after an interrupted
transfer costs a HEAD per file instead of a re-download.
"""

from __future__ import annotations

import fnmatch
import os
import sys

import boto3
from botocore.exceptions import ClientError
from huggingface_hub import HfApi, hf_hub_download

REPO = os.environ["HF_REPO"]
BUCKET = os.environ["S3_BUCKET"]
REGION = os.environ.get("AWS_REGION")
# Comma-separated fnmatch patterns to skip. Repos routinely ship alternate-runtime copies of the
# whole model next to the safetensors -- gpt-oss-20b carries a 13.75 GB `metal/model.bin` for Apple
# Metal -- and transferring those doubles the bill and the wall-clock for bytes FreeToken will never
# open. Excluding is safe only because it is explicit: nothing is skipped unless named here.
EXCLUDE = [p for p in (os.environ.get("HF_EXCLUDE") or "").split(",") if p.strip()]
# 8 MiB parts with a modest concurrency: large enough that a multi-GB shard does not exceed the
# 10k-part limit, small enough that a retry re-sends little.
_PART = 8 * 1024 * 1024


def log(msg: str) -> None:
    print(f"[sync] {msg}", flush=True)


def main() -> int:
    s3 = boto3.client("s3", region_name=REGION)
    api = HfApi()

    info = api.repo_info(REPO, files_metadata=True)
    # Skip the git plumbing; keep everything else, including nested config dirs (DeepSeek-V4's
    # inference/config.json in particular -- FreeToken reads its authoritative model args there).
    def excluded(name: str) -> bool:
        return any(fnmatch.fnmatch(name, pat) or name.startswith(pat.rstrip("*"))
                   for pat in EXCLUDE)

    kept, skipped_by_pattern = [], []
    for sib in info.siblings:
        if sib.rfilename.startswith(".git"):
            continue
        (skipped_by_pattern if excluded(sib.rfilename) else kept).append(sib)
    files = kept
    if skipped_by_pattern:
        # Log what was dropped: a silent exclusion looks exactly like a checkpoint that was never
        # fully transferred, and the failure would surface much later as a load error.
        log(f"excluded by HF_EXCLUDE={EXCLUDE!r}: "
            + ", ".join(sorted(x.rfilename for x in skipped_by_pattern)))
    total = len(files)
    if not total:
        log(f"no files found in {REPO}")
        return 1

    log(f"{REPO}: {total} files -> s3://{BUCKET}/{REPO}/")
    done = skipped = 0
    for i, sib in enumerate(sorted(files, key=lambda s: s.rfilename), 1):
        rel = sib.rfilename
        key = f"{REPO}/{rel}"
        size = sib.size

        if size is not None:
            try:
                head = s3.head_object(Bucket=BUCKET, Key=key)
                if head["ContentLength"] == size:
                    skipped += 1
                    log(f"({i}/{total}) skip {rel} (already {size} bytes)")
                    continue
            except ClientError as exc:
                if exc.response["Error"]["Code"] not in ("404", "NoSuchKey", "403"):
                    raise

        log(f"({i}/{total}) get {rel}" + (f" ({size} bytes)" if size else ""))
        local = hf_hub_download(repo_id=REPO, filename=rel, local_dir="/scratch/dl")
        try:
            s3.upload_file(
                local, BUCKET, key,
                Config=boto3.s3.transfer.TransferConfig(
                    multipart_chunksize=_PART, multipart_threshold=_PART, max_concurrency=8
                ),
            )
            done += 1
        finally:
            # Release the bytes before the next file, which is the entire point of this loop.
            try:
                os.remove(local)
            except OSError:
                pass

    log(f"done: {done} uploaded, {skipped} already present, {total} total")
    log(f"checkpoint root: s3://{BUCKET}/{REPO}/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
