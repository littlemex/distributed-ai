"""Crash-safe finalization of a profiler trace to our own S3 bucket.

A trace (nsys/ncu/neuron-profile) is a write-once artifact that can be hundreds of MB to GB, so
it does NOT go into MLflow artifacts (200 MB download limit) — it lives in our per-region trace
bucket and is referenced from the MLflow run by a ``profile_uri`` tag.

Finalization protocol (so a producer crash cannot silently lose or corrupt a trace):
  1. the producer writes ``<trace>.tmp`` on Lustre scratch, fsyncs, atomic-renames to ``<trace>``,
     fsyncs the directory, and writes a ``<trace>.DONE`` marker (also atomically) containing the
     sha256 — see :func:`finalize_local`;
  2. :func:`upload_finalized` copies the trace to S3 with retry, then verifies the object's
     server-side **SHA256 checksum** matches the local file (real content verification, not just
     size), and only then is the caller allowed to log the MLflow run;
  3. :func:`sweep` re-uploads any ``.DONE``-but-unuploaded traces left by a crashed producer
     (the Lustre PV is shared, so a dead node's trace is still readable), skips already-quarantined
     ones, and quarantines — never deletes — traces whose upload keeps failing.

Only the S3 I/O lives here; MLflow logging is the caller's next step (kept separate so this is
testable against a plain bucket with no MLflow dependency).

IAM the ``producer`` role must have on the trace bucket: ``s3:PutObject`` AND ``s3:GetObject``
(HeadObject with ChecksumMode requires GetObject).
"""
from __future__ import annotations

import os
from typing import Any

from harness.hashing import sha256_b64_of_file, sha256_file

DONE_SUFFIX = ".DONE"
UPLOADED_SUFFIX = ".UPLOADED"    # receipt written next to the trace after a verified upload
QUARANTINE_SUFFIX = ".QUARANTINE"

# boto3 error codes that will never succeed on retry — retrying just re-sends a GB file.
_NON_RETRYABLE = {"AccessDenied", "403", "InvalidAccessKeyId", "SignatureDoesNotMatch", "NoSuchBucket"}


def _atomic_write(path: str, text: str) -> None:
    """Write a small marker atomically (tmp + fsync + rename) so a crash mid-write cannot leave a
    truncated marker that later looks like a corrupt digest."""
    tmp = path + ".writing"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
    _fsync_dir(os.path.dirname(path) or ".")


def _fsync_dir(dirpath: str) -> None:
    """fsync a directory so a rename/create is durable across power loss."""
    fd = os.open(dirpath, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def finalize_local(tmp_path: str, final_path: str) -> str:
    """Atomically publish a fully-written temp trace as the final trace + a DONE marker.

    Returns the sha256. After this returns, ``final_path`` is a complete, machine-detectable
    trace (DONE marker present, directory fsynced) even if the producer dies before uploading.
    """
    with open(tmp_path, "rb") as f:
        os.fsync(f.fileno())
    os.replace(tmp_path, final_path)  # atomic on the same filesystem
    _fsync_dir(os.path.dirname(final_path) or ".")
    digest = sha256_file(final_path)
    _atomic_write(final_path + DONE_SUFFIX, digest)
    return digest


def _read_done(final_path: str) -> str | None:
    marker = final_path + DONE_SUFFIX
    if not os.path.exists(marker):
        return None
    with open(marker, encoding="utf-8") as m:
        return m.read().strip()


def _error_code(exc: Exception) -> str | None:
    resp = getattr(exc, "response", None)
    if isinstance(resp, dict):
        return resp.get("Error", {}).get("Code")
    return None


def upload_finalized(
    s3_client: Any,
    final_path: str,
    bucket: str,
    key: str,
    max_attempts: int = 5,
    base_delay_s: float = 0.5,
    _sleep=None,
) -> dict[str, Any]:
    """Upload a finalized (DONE-marked) trace to S3, verify by server-side SHA256, write a receipt.

    Fails closed: no DONE marker, local drift, permission errors, or checksum mismatch after
    retries all raise and write NO receipt (the caller must not log an MLflow run). Non-retryable
    errors (e.g. AccessDenied) fail immediately instead of re-sending the GB file. Returns
    ``{"uri", "sha256", "attempts"}`` for the caller's ``profile_uri`` tag.
    """
    import time as _time

    sleep = _sleep or _time.sleep
    digest = _read_done(final_path)
    if digest is None:
        raise ValueError(f"refusing to upload un-finalized trace (no DONE marker): {final_path}")
    if digest != sha256_file(final_path):
        raise ValueError(f"local trace changed after finalize: {final_path}")
    checksum_b64 = sha256_b64_of_file(final_path)

    last_err: Exception | None = None
    for attempt in range(1, max_attempts + 1):
        try:
            # Ask S3 to compute+store a SHA256 checksum so we can verify content, not just size.
            s3_client.upload_file(final_path, bucket, key,
                                  ExtraArgs={"ChecksumAlgorithm": "SHA256"})
            head = s3_client.head_object(Bucket=bucket, Key=key, ChecksumMode="ENABLED")
            remote_ck = head.get("ChecksumSHA256")
            if remote_ck is not None and remote_ck != checksum_b64:
                raise ValueError(f"S3 checksum mismatch for {key}: {remote_ck} != {checksum_b64}")
            if remote_ck is None and head["ContentLength"] != os.path.getsize(final_path):
                # fall back to size if the backend did not return a checksum (older/mock S3)
                raise ValueError("size mismatch and no server checksum available")
            s3_client.put_object(Bucket=bucket, Key=key + ".sha256", Body=digest.encode())
            uri = f"s3://{bucket}/{key}"
            _atomic_write(final_path + UPLOADED_SUFFIX, uri)
            return {"uri": uri, "sha256": digest, "attempts": attempt}
        except Exception as e:  # noqa: BLE001
            if _error_code(e) in _NON_RETRYABLE:
                raise  # retrying a permission error just re-sends the GB file
            last_err = e
            if attempt < max_attempts:
                sleep(base_delay_s * (2 ** (attempt - 1)))
    raise RuntimeError(f"upload failed after {max_attempts} attempts: {last_err}") from last_err


def sweep(
    s3_client: Any,
    scratch_dir: str,
    bucket: str,
    key_for,
) -> dict[str, list[str]]:
    """Recover a crashed producer: re-upload DONE-but-unuploaded traces under ``scratch_dir``.

    ``key_for(final_path)`` maps a local trace to its S3 key. A trace with a DONE marker but no
    UPLOADED receipt is retried; already-quarantined traces are skipped (quarantine is an
    absorbing state, so a permanently-failing trace does not burn a retry every sweep). On
    repeated failure a trace is quarantined (marker written) and reported — never deleted.
    Returns ``{"uploaded": [...], "quarantined": [...], "skipped_quarantined": [...]}``.
    """
    uploaded: list[str] = []
    quarantined: list[str] = []
    skipped: list[str] = []
    for root, _dirs, files in os.walk(scratch_dir):
        for name in files:
            if not name.endswith(DONE_SUFFIX):
                continue
            final_path = os.path.join(root, name[: -len(DONE_SUFFIX)])
            if not os.path.exists(final_path):
                continue
            if os.path.exists(final_path + UPLOADED_SUFFIX):
                continue  # already durable
            if os.path.exists(final_path + QUARANTINE_SUFFIX):
                skipped.append(final_path)  # absorbing state; needs human action
                continue
            try:
                key = key_for(final_path)  # outside the S3 try: a key_for bug is not a trace fault
            except Exception:  # noqa: BLE001
                raise
            try:
                upload_finalized(s3_client, final_path, bucket, key)
                uploaded.append(final_path)
            except Exception:  # noqa: BLE001
                _atomic_write(final_path + QUARANTINE_SUFFIX, "upload failed during sweep")
                quarantined.append(final_path)
    return {"uploaded": uploaded, "quarantined": quarantined, "skipped_quarantined": skipped}
