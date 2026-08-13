"""Single source of the content-hash convention (``sha256:<hex>``), used by report + storage.

Previously duplicated in report.py and storage/finalizer.py; a drift in the prefix or chunk
size would silently break every integrity comparison, so it lives once here.
"""
from __future__ import annotations

import base64
import hashlib

SHA256_PREFIX = "sha256:"
_CHUNK_BYTES = 1 << 20


def sha256_file(path: str) -> str:
    """Streaming sha256 of a file, returned as ``sha256:<hex>``."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(_CHUNK_BYTES), b""):
            h.update(chunk)
    return SHA256_PREFIX + h.hexdigest()


def sha256_b64_of_file(path: str) -> str:
    """Base64 of the raw sha256 digest — the form S3 returns in ``ChecksumSHA256`` so an
    uploaded object's server-side checksum can be compared to the local file."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(_CHUNK_BYTES), b""):
            h.update(chunk)
    return base64.b64encode(h.digest()).decode()
