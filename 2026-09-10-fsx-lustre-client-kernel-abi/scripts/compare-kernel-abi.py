#!/usr/bin/env python3
"""Compare the kernel module ABI of two Ubuntu kernel builds that share a release string.

The FSx for Lustre Ubuntu repository publishes one binary module package per exact
kernel release (for example ``lustre-client-modules-6.8.0-1063-aws``), and it publishes
those packages per Ubuntu suite (``focal``, ``jammy``, ``noble``). A 6.8 kernel release
can exist in more than one suite because the 6.8 kernel is the GA kernel of Ubuntu 24.04
and the hardware-enablement kernel of Ubuntu 22.04.

Whether a module built in one suite loads on the other suite's kernel is decided by two
things only: the ``vermagic`` string recorded in the module, and the CRC of every kernel
symbol the module imports. This script downloads the two ``linux-headers`` packages and
the module package, then compares both.

It needs no privileges, no running kernel of the target version, and no AWS account: it
is a static check that can be run before provisioning anything.

Example:

    ./compare-kernel-abi.py \\
        --module-url https://fsx-lustre-client-repo.s3.amazonaws.com/ubuntu/pool/jammy/l/lu/lustre-client-modules-6.8.0-1063-aws_2.15.6-1fsx34_amd64.deb \\
        --headers-url http://archive.ubuntu.com/ubuntu/pool/main/l/linux-aws/linux-headers-6.8.0-1063-aws_6.8.0-1063.66_amd64.deb \\
        --headers-url http://archive.ubuntu.com/ubuntu/pool/main/l/linux-aws-6.8/linux-headers-6.8.0-1063-aws_6.8.0-1063.66~22.04.1_amd64.deb

Exit status is 0 when the module is loadable against every kernel passed with
``--headers-url``, and 1 otherwise.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

MODVERSION_NAME_MAX = 512


def download(url: str, dest: str) -> str:
    path = os.path.join(dest, os.path.basename(url))
    with urllib.request.urlopen(url) as response, open(path, "wb") as handle:
        shutil.copyfileobj(response, handle)
    return path


def extract_deb(deb: str, dest: str) -> str:
    """Unpack a .deb data payload into ``dest`` and return the payload root."""
    root = os.path.join(dest, os.path.basename(deb) + ".root")
    os.makedirs(root, exist_ok=True)
    work = os.path.join(dest, os.path.basename(deb) + ".ar")
    os.makedirs(work, exist_ok=True)
    subprocess.run(["ar", "x", os.path.abspath(deb)], cwd=work, check=True)
    payload = next(
        (
            os.path.join(work, name)
            for name in sorted(os.listdir(work))
            if name.startswith("data.tar")
        ),
        None,
    )
    if payload is None:
        raise RuntimeError(f"{deb}: no data.tar payload")
    if payload.endswith(".zst"):
        plain = payload[: -len(".zst")]
        with open(plain, "wb") as handle:
            subprocess.run(["zstd", "-d", "-q", "-c", payload], stdout=handle, check=True)
        payload = plain
    with tarfile.open(payload) as archive:
        archive.extractall(root)
    return root


def find_one(root: str, filename: str) -> str:
    for base, _dirs, files in os.walk(root):
        if filename in files:
            return os.path.join(base, filename)
    raise RuntimeError(f"{root}: {filename} not found")


def find_modules(root: str) -> list[str]:
    found = []
    for base, _dirs, files in os.walk(root):
        found.extend(os.path.join(base, name) for name in files if name.endswith(".ko"))
    return sorted(found)


def read_symvers(path: str) -> dict[str, int]:
    """Parse Module.symvers into {symbol: crc}."""
    table: dict[str, int] = {}
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            fields = line.rstrip("\n").split("\t")
            if len(fields) >= 2:
                table[fields[1]] = int(fields[0], 16) & 0xFFFFFFFF
    return table


def elf_sections(blob: bytes) -> dict[str, tuple[int, int]]:
    if blob[:4] != b"\x7fELF" or blob[4] != 2:
        raise RuntimeError("not a 64-bit ELF object")
    sh_off = struct.unpack_from("<Q", blob, 0x28)[0]
    sh_entsize = struct.unpack_from("<H", blob, 0x3A)[0]
    sh_num = struct.unpack_from("<H", blob, 0x3C)[0]
    sh_strndx = struct.unpack_from("<H", blob, 0x3E)[0]

    def header(index: int) -> tuple[int, int, int]:
        base = sh_off + index * sh_entsize
        name, _type, _flags, _addr, offset, size = struct.unpack_from("<IIQQQQ", blob, base)
        return name, offset, size

    strtab = header(sh_strndx)[1]
    sections: dict[str, tuple[int, int]] = {}
    for index in range(sh_num):
        name_off, offset, size = header(index)
        end = blob.index(b"\0", strtab + name_off)
        sections[blob[strtab + name_off : end].decode()] = (offset, size)
    return sections


def module_vermagic(blob: bytes, sections: dict[str, tuple[int, int]]) -> str | None:
    offset, size = sections.get(".modinfo", (0, 0))
    for entry in blob[offset : offset + size].split(b"\0"):
        if entry.startswith(b"vermagic="):
            return entry[len("vermagic=") :].decode().strip()
    return None


def module_imports(blob: bytes, sections: dict[str, tuple[int, int]]) -> dict[str, int]:
    """Parse the ``__versions`` section into {symbol: crc}.

    Kernels using extended modversions store variable-length records of
    ``u32 length; u32 crc; char name[]``. Fixed-length records of
    ``unsigned long crc; char name[64]`` are the older layout. The first word of an
    extended record is the record length, which is never a plausible CRC low word for
    the fixed layout, so the layout can be detected from the first record.
    """
    offset, size = sections.get("__versions", (0, 0))
    if not size:
        return {}
    imports: dict[str, int] = {}
    first_word, = struct.unpack_from("<I", blob, offset)
    extended = 8 < first_word <= 8 + MODVERSION_NAME_MAX
    if extended:
        cursor = 0
        while cursor < size:
            length, crc = struct.unpack_from("<II", blob, offset + cursor)
            if length <= 8 or cursor + length > size:
                break
            name = blob[offset + cursor + 8 : offset + cursor + length].split(b"\0")[0]
            imports[name.decode("utf-8", "replace")] = crc
            cursor += length
    else:
        stride = 8 + 64
        for index in range(size // stride):
            base = offset + index * stride
            crc, = struct.unpack_from("<Q", blob, base)
            name = blob[base + 8 : base + stride].split(b"\0")[0]
            imports[name.decode("utf-8", "replace")] = crc & 0xFFFFFFFF
    return imports


def kernel_release_of(headers_root: str) -> str:
    for base, dirs, _files in os.walk(headers_root):
        for name in dirs:
            match = re.fullmatch(r"linux-headers-(\S+)", name)
            if match:
                return match.group(1)
    return "unknown"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--module-url", required=True, help="URL of a lustre-client-modules .deb")
    parser.add_argument(
        "--headers-url",
        required=True,
        action="append",
        help="URL of a linux-headers .deb for the same kernel release; repeatable",
    )
    parser.add_argument("--json", help="write the report to this path as JSON")
    parser.add_argument("--keep", action="store_true", help="keep the download directory")
    args = parser.parse_args()

    workdir = tempfile.mkdtemp(prefix="kernel-abi-")
    report: dict[str, object] = {"module_url": args.module_url, "kernels": []}
    try:
        module_root = extract_deb(download(args.module_url, workdir), workdir)
        modules = find_modules(module_root)
        if not modules:
            raise RuntimeError("module package contains no .ko files")

        parsed = []
        for module in modules:
            blob = open(module, "rb").read()
            sections = elf_sections(blob)
            parsed.append(
                {
                    "name": os.path.basename(module),
                    "vermagic": module_vermagic(blob, sections),
                    "imports": module_imports(blob, sections),
                }
            )
        vermagics = sorted({str(entry["vermagic"]) for entry in parsed})
        report["module_count"] = len(parsed)
        report["module_vermagic"] = vermagics
        print(f"module package: {os.path.basename(args.module_url)}")
        print(f"  kernel objects: {len(parsed)}")
        print(f"  vermagic: {', '.join(vermagics)}")

        symbol_tables = []
        for url in args.headers_url:
            root = extract_deb(download(url, workdir), workdir)
            table = read_symvers(find_one(root, "Module.symvers"))
            symbol_tables.append(
                {"url": url, "release": kernel_release_of(root), "symbols": table}
            )
            print(f"kernel headers: {os.path.basename(url)}")
            print(f"  release: {symbol_tables[-1]['release']}  exported symbols: {len(table)}")

        if len(symbol_tables) > 1:
            base = symbol_tables[0]
            for other in symbol_tables[1:]:
                only_base = sorted(set(base["symbols"]) - set(other["symbols"]))
                only_other = sorted(set(other["symbols"]) - set(base["symbols"]))
                shared = set(base["symbols"]) & set(other["symbols"])
                mismatched = sorted(
                    name for name in shared if base["symbols"][name] != other["symbols"][name]
                )
                print(
                    f"kernel-to-kernel: {os.path.basename(base['url'])} vs "
                    f"{os.path.basename(other['url'])}"
                )
                print(
                    f"  shared symbols: {len(shared)}  CRC mismatches: {len(mismatched)}  "
                    f"only-first: {len(only_base)}  only-second: {len(only_other)}"
                )
                report.setdefault("kernel_to_kernel", []).append(
                    {
                        "first": base["url"],
                        "second": other["url"],
                        "shared": len(shared),
                        "crc_mismatches": mismatched[:64],
                        "crc_mismatch_count": len(mismatched),
                        "only_first": only_base[:64],
                        "only_second": only_other[:64],
                    }
                )

        loadable = True
        for kernel in symbol_tables:
            checked = 0
            mismatched: list[dict[str, str]] = []
            missing: list[str] = []
            provided_by_package = {
                symbol
                for entry in parsed
                for symbol in entry["imports"]
                if symbol not in kernel["symbols"]
            }
            for entry in parsed:
                for symbol, crc in entry["imports"].items():
                    if symbol in kernel["symbols"]:
                        checked += 1
                        if kernel["symbols"][symbol] != crc:
                            mismatched.append(
                                {
                                    "module": entry["name"],
                                    "symbol": symbol,
                                    "module_crc": hex(crc),
                                    "kernel_crc": hex(kernel["symbols"][symbol]),
                                }
                            )
                    else:
                        missing.append(symbol)
            verdict = not mismatched
            loadable = loadable and verdict
            print(f"module-to-kernel: {kernel['release']} ({os.path.basename(kernel['url'])})")
            print(f"  kernel symbol imports checked: {checked}")
            print(f"  CRC mismatches: {len(mismatched)}")
            print(
                "  imports resolved inside the module package "
                f"(not kernel symbols): {len(provided_by_package)}"
            )
            print(f"  verdict: {'LOADABLE' if verdict else 'NOT LOADABLE'}")
            for item in mismatched[:16]:
                print(f"    mismatch {item['module']} {item['symbol']}")
            report["kernels"].append(
                {
                    "url": kernel["url"],
                    "release": kernel["release"],
                    "exported_symbols": len(kernel["symbols"]),
                    "imports_checked": checked,
                    "crc_mismatch_count": len(mismatched),
                    "crc_mismatches": mismatched[:64],
                    "verdict": "loadable" if verdict else "not-loadable",
                }
            )

        report["verdict"] = "loadable" if loadable else "not-loadable"
        if args.json:
            with open(args.json, "w", encoding="utf-8") as handle:
                json.dump(report, handle, indent=2, sort_keys=True)
                handle.write("\n")
        return 0 if loadable else 1
    finally:
        if args.keep:
            print(f"downloads kept in {workdir}")
        else:
            shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
