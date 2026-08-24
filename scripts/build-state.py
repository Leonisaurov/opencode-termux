#!/usr/bin/env python3
"""Content-addressed incremental build state for the Android port.

The command intentionally has no third-party dependencies so it works in
Termux, CI containers, and the host build images alike.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

SCHEMA = 1
CHUNK = 1024 * 1024


def digest_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def digest_file(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(CHUNK):
            hasher.update(chunk)
    return hasher.hexdigest()


def digest_path(path: Path) -> str:
    """Hash a file or directory without timestamps or absolute paths."""
    if path.is_symlink():
        return digest_bytes(f"symlink\0{path.readlink()}".encode())
    if path.is_file():
        return digest_bytes(f"file\0{path.name}\0{digest_file(path)}".encode())
    if not path.is_dir():
        return digest_bytes(f"missing\0{path.name}".encode())

    entries: list[bytes] = []
    for child in sorted(path.iterdir(), key=lambda item: item.name):
        if child.name in {".git", ".zig-cache", "node_modules", "target"}:
            continue
        entries.append(f"{child.name}\0".encode() + digest_path(child).encode())
    return digest_bytes(b"dir\0" + b"\n".join(entries))


def resolve(path: str, root: Path) -> Path:
    candidate = Path(path)
    return candidate if candidate.is_absolute() else root / candidate


def record_name(path: Path, raw: str, root: Path) -> str:
    try:
        return path.resolve().relative_to(root).as_posix()
    except ValueError:
        return path.name


def input_digest(args: argparse.Namespace, root: Path) -> tuple[str, list[dict[str, str]]]:
    records: list[dict[str, str]] = []
    for value in sorted(args.value):
        if "=" not in value:
            raise ValueError(f"--value requires NAME=VALUE: {value}")
        name, content = value.split("=", 1)
        records.append({"kind": "value", "name": name, "digest": digest_bytes(content.encode())})
    for raw in sorted(args.input):
        path = resolve(raw, root)
        records.append({"kind": "path", "name": record_name(path, raw, root), "digest": digest_path(path)})
    for raw in sorted(args.dep):
        path = resolve(raw, root)
        if not path.is_file():
            raise ValueError(f"dependency manifest does not exist: {raw}")
        manifest = json.loads(path.read_text(encoding="utf-8"))
        records.append({"kind": "dependency", "name": record_name(path, raw, root), "digest": manifest.get("digest", "")})
    payload = json.dumps(records, sort_keys=True, separators=(",", ":")).encode()
    return digest_bytes(payload), records


def output_records(args: argparse.Namespace, root: Path) -> list[dict[str, str]]:
    records = []
    for raw in sorted(args.output):
        path = resolve(raw, root)
        if not path.exists():
            raise ValueError(f"required output does not exist: {raw}")
        records.append({"name": record_name(path, raw, root), "digest": digest_path(path)})
    return records


def manifest_path(state_dir: Path, node: str) -> Path:
    return state_dir / "nodes" / f"{node}.json"


def read_manifest(state_dir: Path, node: str) -> dict | None:
    path = manifest_path(state_dir, node)
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def is_valid(manifest: dict | None, digest: str, outputs: list[dict[str, str]]) -> bool:
    return bool(
        manifest
        and manifest.get("schema") == SCHEMA
        and manifest.get("status") == "valid"
        and manifest.get("digest") == digest
        and manifest.get("outputs") == outputs
    )


def atomic_write(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def acquire_lock(state_dir: Path, node: str) -> Path:
    lock = state_dir / "locks" / f"{node}.lock"
    lock.parent.mkdir(parents=True, exist_ok=True)
    try:
        lock.mkdir()
    except FileExistsError as error:
        raise RuntimeError(f"node is already being built: {node} ({lock})") from error
    (lock / "owner").write_text(f"pid={os.getpid()}\ntime={time.time()}\n", encoding="utf-8")
    return lock


def run(args: argparse.Namespace) -> int:
    root = Path(args.root).resolve()
    state_dir = resolve(args.state_dir, root)
    digest, inputs = input_digest(args, root)
    existing = read_manifest(state_dir, args.node)
    try:
        outputs = output_records(args, root)
    except ValueError:
        outputs = []
    if not args.force and is_valid(existing, digest, outputs):
        print(f"BUILD_STATE=hit node={args.node} digest={digest}")
        return 0
    if args.dry_run:
        print(f"BUILD_STATE=miss node={args.node} digest={digest}")
        return 0

    lock = acquire_lock(state_dir, args.node)
    manifest = {
        "schema": SCHEMA,
        "node": args.node,
        "digest": digest,
        "status": "building",
        "inputs": inputs,
        "outputs": [],
        "started_at": int(time.time()),
    }
    atomic_write(manifest_path(state_dir, args.node), manifest)
    try:
        print(f"BUILD_STATE=miss node={args.node} digest={digest}")
        result = subprocess.run(args.command, cwd=root, check=False)
        if result.returncode:
            manifest["status"] = "failed"
            manifest["returncode"] = result.returncode
            atomic_write(manifest_path(state_dir, args.node), manifest)
            return result.returncode
        digest, inputs = input_digest(args, root)
        outputs = output_records(args, root)
        manifest.update({"status": "valid", "digest": digest, "inputs": inputs, "outputs": outputs, "finished_at": int(time.time())})
        atomic_write(manifest_path(state_dir, args.node), manifest)
        return 0
    finally:
        shutil.rmtree(lock, ignore_errors=True)


def check(args: argparse.Namespace) -> int:
    root = Path(args.root).resolve()
    state_dir = resolve(args.state_dir, root)
    digest, _ = input_digest(args, root)
    manifest = read_manifest(state_dir, args.node)
    try:
        outputs = output_records(args, root)
    except ValueError:
        outputs = []
    valid = is_valid(manifest, digest, outputs)
    print(f"BUILD_STATE={'valid' if valid else 'invalid'} node={args.node} digest={digest}")
    return 0 if valid else 1


def status(args: argparse.Namespace) -> int:
    state_dir = resolve(args.state_dir, Path(args.root).resolve())
    manifests = sorted((state_dir / "nodes").glob("*.json"))
    if args.node:
        manifests = [manifest_path(state_dir, args.node)]
    for path in manifests:
        manifest = read_manifest(state_dir, path.stem)
        if manifest is None:
            print(f"{path.stem}: missing-or-invalid-manifest")
            continue
        print(f"{path.stem}: {manifest.get('status', 'unknown')} digest={manifest.get('digest', '')}")
    return 0


def parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["run", "check", "status"])
    parser.add_argument("--root", default=".")
    parser.add_argument("--state-dir", default="build/state")
    parser.add_argument("--node")
    parser.add_argument("--input", action="append", default=[])
    parser.add_argument("--value", action="append", default=[])
    parser.add_argument("--dep", action="append", default=[])
    parser.add_argument("--output", action="append", default=[])
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    return parser


def main() -> int:
    raw = sys.argv[1:]
    separator = raw.index("--") if "--" in raw else len(raw)
    args = parser().parse_args(raw[:separator])
    if args.command in {"run", "check"} and not args.node:
        print(f"{args.command} requires --node", file=sys.stderr)
        return 2
    if args.command == "run":
        command_args = raw[separator + 1 :]
        if not command_args:
            print("run requires a command after --", file=sys.stderr)
            return 2
        args.command = command_args
        return run(args)
    if args.command == "check":
        return check(args)
    return status(args)


if __name__ == "__main__":
    raise SystemExit(main())
