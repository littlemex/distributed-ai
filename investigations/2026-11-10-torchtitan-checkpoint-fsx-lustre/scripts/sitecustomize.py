"""Imported by every Python process that has this directory on PYTHONPATH (run_variant.sh sets it).

With TC_DISABLE_DIRECT_IO=1, torch_checkpointing's file writer opens files without O_DIRECT. Its
default (use_direct_io=True) falls back to buffered I/O only when open() rejects O_DIRECT, not when a
later write() does: on ext4 and on Lustre the unaligned torch.save stream then fails with EINVAL.
The checkpoint is written by a worker subprocess, so the switch has to be applied at interpreter
start, not inside the recipe.
"""
import os

if os.environ.get("TC_DISABLE_DIRECT_IO") == "1":
    try:
        from torch_checkpointing.storage import filesystem as _fs

        _orig = _fs.WriteStream.__init__

        def _buffered(self, path, mode="wb", use_direct_io=True):
            _orig(self, path, mode, False)

        _fs.WriteStream.__init__ = _buffered
    except Exception:  # never break interpreter start-up
        pass
