#!/usr/bin/env python3
"""Gate for the OpenCode standalone emitted by Bun 1.4.2.

The era-Zig validator (validate-android-bundle.py) parses a module graph
appended after the ELF and asserts the undici re-export repair landed. Bun
1.4.2 cross-compiles instead: it embeds the target's own bun ELF and links the
graph into the `.bun` section, so there is nothing at the EOF to parse and no
byte patch to verify. What can still be proven from the outside is the runtime
identity (a patched Bionic PIE, not the official glibc build), the payload
OpenTUI needs, and that the emitted graph does not carry the undici helper the
old pipeline had to fix.

Usage: validate-android-bundle-142.py <binary> [--lib <libopentui.so>]
"""
from __future__ import annotations

import argparse
import json
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LOCK = ROOT / "ci" / "external-sources.lock"
MAX_BYTES = 220 * 1024 * 1024
# The stripped base alone is ~102 MB, so anything reaching this floor has lost
# most of its runtime; the real identity proof is the marker and the .bun
# section, and the ceiling keeps an accidental unstripped embed out.
MIN_BYTES = 90 * 1024 * 1024
# Bun 1.3+ does not emit this helper (measured across the eleven B7 probe
# binaries); a hit means the emitter changed and the undici exposure has to be
# re-reviewed at the source, because a linked graph cannot be patched here.
UNDICI_HELPER = re.compile(rb"__reExport\(")
EM_BASE = 16
EM_AARCH64 = 183
ET_DYN = 3


def fail(message: str) -> None:
    raise ValueError(f"android-bundle-142-validator: {message}")


def pinned_marker() -> str:
    sources = json.loads(LOCK.read_text(encoding="utf-8"))["sources"]
    return sources["bun-android-release"]["revision_marker"]


def section_names(data: bytes) -> set[str]:
    sh_off = struct.unpack_from("<Q", data, 0x28)[0]
    sh_entry = struct.unpack_from("<H", data, 0x3A)[0]
    sh_num = struct.unpack_from("<H", data, 0x3C)[0]
    sh_strndx = struct.unpack_from("<H", data, 0x3E)[0]
    if sh_off == 0 or sh_num == 0:
        fail("section header table is missing")
    strtab_hdr = sh_off + sh_strndx * sh_entry
    strtab = struct.unpack_from("<QI", data, strtab_hdr + 0x18)
    names = set()
    for index in range(sh_num):
        hdr = sh_off + index * sh_entry
        name_off = struct.unpack_from("<I", data, hdr)[0]
        end = data.find(b"\0", strtab[0] + name_off)
        if end >= 0:
            names.add(data[strtab[0] + name_off:end].decode("latin1"))
    return names


def validate(path: Path, native_lib: Path | None) -> None:
    data = path.read_bytes()
    if data[:4] != b"\x7fELF":
        fail("standalone output is not ELF")
    if data[4] != 2:
        fail(f"expected ELFCLASS64, got {data[4]}")
    if struct.unpack_from("<H", data, EM_BASE)[0] != ET_DYN:
        fail("expected ET_DYN: Android requires a PIE runtime")
    if struct.unpack_from("<H", data, EM_BASE + 2)[0] != EM_AARCH64:
        fail("expected EM_AARCH64")
    marker = pinned_marker()
    if marker.encode() not in data:
        fail(f"base lineage marker {marker} is missing: the official glibc runtime was embedded")
    sections = section_names(data)
    if ".bun" not in sections:
        fail(f"the .bun section is missing (sections: {len(sections)})")
    if not MIN_BYTES <= len(data) <= MAX_BYTES:
        fail(f"size {len(data)} is outside the {MIN_BYTES}-{MAX_BYTES} budget")
    if UNDICI_HELPER.search(data):
        fail("module graph contains the __reExport undici helper; the emitter changed")
    if native_lib is not None:
        lib = native_lib.read_bytes()
        if len(lib) < 2 * 4096:
            fail(f"native library {native_lib} is too small to identify: {len(lib)} bytes")
        window = lib[len(lib) // 2:len(lib) // 2 + 4096]
        if window not in data:
            fail(f"the Bionic library {native_lib} is not embedded verbatim")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--lib", type=Path, default=None)
    args = parser.parse_args()
    try:
        validate(args.binary, args.lib)
    except (OSError, ValueError, struct.error) as error:
        print(str(error), file=sys.stderr)
        return 1
    print(f"android-bundle-142-validator: valid {args.binary}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
