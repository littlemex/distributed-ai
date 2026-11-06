"""Writing the optional output files (--html, --save-json) so that a failed run never replaces a good file."""
from __future__ import annotations

import os
from pathlib import Path


def new_work_file(path: Path) -> tuple:
    """Create the file the report is written to, owner-only (0600), next to the final path.

    The final path is only ever filled by a run that ended with status 0 (see place_report), so a killed run
    leaves a hidden temporary file at worst and never blocks the next run. The temporary name does not depend
    on the target name, so a long target name cannot make this step fail. The last missing parent directory is
    created with mode 0700 (subject to umask); parents are not otherwise checked.
    """
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = path.parent / f".sr-{os.getpid()}-{os.urandom(4).hex()}.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    return os.fdopen(fd, "w", encoding="utf-8"), tmp


def _side_path(path: Path, label: str, stamp: str) -> Path:
    stem = path.stem[:100]  # keep the side name inside typical file name limits
    return path.with_name(f"{stem}.{label}-{stamp}{path.suffix}")


def place_report(tmp: Path, path: Path, status: int, overwrite: bool, stamp: str, force_side: str | None = None) -> tuple:
    """Move the finished report into place. Returns (final path, note or None, placed_ok).

    Exit status 0: the report goes to `path` (replacing an existing file only with --overwrite; a symbolic
    link there is replaced, not followed). Any other status: the report goes next to `path` as
    `<name>.failed-<time>`, so `path` only ever holds reports of successful runs. If a successful report cannot
    be put at `path` (it appeared meanwhile, or the move failed), it is saved as `<name>.unplaced-<time>`,
    placed_ok is False and the caller turns the exit status into 4.
    """
    def side(label, why):
        # Never replace a file that is already there: two outputs of one run can shorten to the same side name.
        for n in range(1, 100):
            target = _side_path(path, label, stamp if n == 1 else f"{stamp}-{n}")
            try:
                os.link(tmp, target)  # atomic and exclusive
            except FileExistsError:
                continue
            except OSError:
                # No hard links on this file system: create the side name exclusively and copy into it.
                try:
                    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
                except FileExistsError:
                    continue
                except OSError:
                    return tmp
                try:
                    with os.fdopen(fd, "w", encoding="utf-8") as dst, open(tmp, encoding="utf-8") as src:
                        dst.write(src.read())
                except OSError:
                    target.unlink(missing_ok=True)
                    return tmp
            tmp.unlink(missing_ok=True)
            return target
        return tmp  # leave the finished report where it is rather than lose it

    if force_side:
        target = side(force_side, None)
        return target, f"The data file could not be placed, so this file was saved as {target} to keep the two together.", False
    if status != 0:
        target = side("failed", None)
        return target, f"The run was not complete, so the report was saved as {target} and {path} was not touched.", False
    try:
        if overwrite:
            os.replace(tmp, path)
            return path, None, True
        try:
            os.link(tmp, path)  # atomic and exclusive
        except FileExistsError:
            target = side("unplaced", None)
            return target, f"{path} appeared during the run, so the report was saved as {target}.", False
        except OSError:
            # No hard links on this file system: create the path exclusively and copy the report into it.
            try:
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
            except FileExistsError:
                target = side("unplaced", None)
                return target, f"{path} appeared during the run, so the report was saved as {target}.", False
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as dst, open(tmp, encoding="utf-8") as src:
                    dst.write(src.read())
            except BaseException:
                path.unlink(missing_ok=True)  # never leave a truncated file at the target
                raise
        tmp.unlink(missing_ok=True)
        return path, None, True
    except OSError as e:
        target = side("unplaced", None)
        return target, f"{path} could not be written ({e}), so the report was saved as {target}.", False


def refuse_existing(path: Path, overwrite: bool):
    """Return a message when `path` cannot be used as an output, else None."""
    if path.is_dir():
        return f"{path} is a directory. Give a file path."
    if os.path.lexists(path) and not overwrite:
        return f"{path} already exists. Use --overwrite to replace it, or give another path."
    return None

