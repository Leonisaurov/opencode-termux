#!/usr/bin/env python3
"""Produce and validate the repository's versioned CI cache contract.

The key deliberately describes the toolchain and inputs that can change ABI or
compiler output.  This helper is also usable outside GitHub Actions, which
makes cache-key changes testable without a runner.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import sys
from pathlib import Path


SCHEMA = "ci-cache-v1"
CHUNK = 1024 * 1024


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while data := stream.read(CHUNK):
            digest.update(data)
    return digest.hexdigest()


def path_digest(path: Path) -> str:
    if path.is_symlink():
        return hashlib.sha256(f"symlink\0{path.readlink()}".encode()).hexdigest()
    if path.is_file():
        return f"file:{sha256(path)}"
    if not path.is_dir():
        return "missing"
    entries = []
    for child in sorted(path.rglob("*")):
        if child.is_dir() or ".git" in child.parts:
            continue
        entries.append(f"{child.relative_to(path)}={path_digest(child)}")
    return hashlib.sha256("\n".join(entries).encode()).hexdigest()


def value(name: str, fallback: str = "unknown") -> str:
    return os.environ.get(name, fallback)


def contract(root: Path, product: str, paths: list[str], values: list[str]) -> dict:
    inputs = {
        "schema": SCHEMA,
        "product": product,
        "runner_os": value("RUNNER_OS", platform.system().lower()),
        "host_arch": value("RUNNER_ARCH", platform.machine()),
        "target": value("ANDROID_TRIPLE_API", "aarch64-linux-android24"),
        "android_api": value("ANDROID_API", "24"),
        "ndk": value("ANDROID_NDK_VERSION"),
        "zig": value("ZIG_VERSION"),
        "rust": value("RUST_TOOLCHAIN", "unknown"),
        "upstream": value("UPSTREAM_COMMIT", value("WEBKIT_COMMIT")),
        "values": dict(item.split("=", 1) for item in values),
        "paths": {
            path: path_digest((root / path).resolve())
            for path in sorted(set(paths))
        },
    }
    encoded = json.dumps(inputs, sort_keys=True, separators=(",", ":")).encode()
    inputs["digest"] = hashlib.sha256(encoded).hexdigest()
    return inputs


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["key", "write", "validate"])
    parser.add_argument("--root", default=".")
    parser.add_argument("--product", required=True)
    parser.add_argument("--path", action="append", default=[])
    parser.add_argument("--value", action="append", default=[])
    parser.add_argument("--manifest")
    parser.add_argument("--output", action="append", default=[])
    parser.add_argument("--machine")
    args = parser.parse_args()
    root = Path(args.root).resolve()
    metadata = contract(root, args.product, args.path, args.value)
    key = f"{SCHEMA}-{args.product}-{metadata['digest']}"
    if args.command == "key":
        print(key)
        return 0
    if args.command == "write":
        if not args.manifest:
            parser.error("write requires --manifest")
        manifest = {"key": key, "contract": metadata}
        manifest_path = (root / args.manifest).resolve()
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        return 0
    if args.manifest:
        manifest_path = (root / args.manifest).resolve()
        if not manifest_path.is_file():
            print("CACHE_CONTRACT=invalid reason=missing-manifest", file=sys.stderr)
            return 1
        saved = json.loads(manifest_path.read_text(encoding="utf-8"))
        if saved.get("key") != key:
            print("CACHE_CONTRACT=invalid reason=key-mismatch", file=sys.stderr)
            return 1
    for output in args.output:
        path = (root / output).resolve()
        if not path.is_file() or path.stat().st_size == 0:
            print(f"CACHE_CONTRACT=invalid reason=missing-output path={output}", file=sys.stderr)
            return 1
        if args.machine:
            readelf = shutil.which("readelf")
            if readelf:
                import subprocess
                result = subprocess.run([readelf, "-h", str(path)], text=True, capture_output=True)
                if result.returncode or args.machine not in result.stdout:
                    print(f"CACHE_CONTRACT=invalid reason=machine-mismatch path={output}", file=sys.stderr)
                    return 1
    print(f"CACHE_CONTRACT=valid key={key}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
