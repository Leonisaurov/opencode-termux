#!/usr/bin/env python3
"""Package already-built CI artifacts and emit the installer's manifest."""
import argparse, hashlib, json, pathlib, re, subprocess, tarfile

def verify(path: pathlib.Path, name: str) -> None:
    if name == "codex-linux-sandbox":
        result = subprocess.run(["bash", "-n", str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if result.returncode: raise SystemExit("codex-linux-sandbox: Bash inválido")
        return
    info = subprocess.check_output(["file", str(path)], text=True)
    if "ELF" not in info or not re.search(r"aarch64|ARM aarch64", info):
        raise SystemExit(f"{name}: no es un ELF aarch64 ({info.strip()})")

def main():
    p=argparse.ArgumentParser(); p.add_argument("--root", type=pathlib.Path, required=True); p.add_argument("--out", type=pathlib.Path, required=True); p.add_argument("--release", required=True); p.add_argument("--stack-version", required=True); p.add_argument("--bun", required=True); p.add_argument("--opentui", required=True); p.add_argument("--opencode", required=True); p.add_argument("--kilo", required=True); p.add_argument("--codex", required=True); a=p.parse_args(); a.out.mkdir(parents=True, exist_ok=True)
    specs={"bun":(["bun"],"tar.gz",[]),"opentui":(["libopentui.so"],"tar.gz",[]),"opencode":(["opencode"],"tar.gz",["bun","opentui"]),"kilo":(["kilo"],"tar.gz",["bun"]),"codex":(["codex-android","codex-code-mode-host","codex-linux-sandbox"],"tar.gz",[])}
    versions={"bun":a.bun,"opentui":a.opentui,"opencode":a.opencode,"kilo":a.kilo,"codex":a.codex}; comps={}
    prefixes={"bun":"bun-android-aarch64-","opentui":"opentui-android-aarch64-","opencode":"opencode-android-aarch64-","kilo":"kilo-android-aarch64-","codex":"codex-android-aarch64-"}
    for name,(files,kind,deps) in specs.items():
        artifact_dirs=[p for p in a.root.iterdir() if p.is_dir() and p.name.startswith(prefixes[name])]
        if len(artifact_dirs) != 1: raise SystemExit(f"{name}: artifact ambiguo o ausente")
        source=artifact_dirs[0]; archive=a.out/f"{name}-{versions[name]}-android-aarch64.tar.gz"
        with tarfile.open(archive,"w:gz") as t:
            for f in files:
                matches=list(source.rglob(f));
                if len(matches)!=1 or not matches[0].is_file(): raise SystemExit(f"{name}: artifact ambiguo o ausente: {f}")
                verify(matches[0], f)
                t.add(matches[0],arcname=f)
        comps[name]={"version":versions[name],"tag":versions[name],"asset":archive.name,"sha256":hashlib.sha256(archive.read_bytes()).hexdigest(),"size":archive.stat().st_size,"archive":kind,"depends":deps,"files":files}
    (a.out/"manifest.json").write_text(json.dumps({"schema":"opencode-termux.stack/v1","stack_version":a.stack_version,"release":a.release,"stability":"stable","android":{"arch":"aarch64","abi":"arm64-v8a","api":24},"components":comps},indent=2)+"\n")
if __name__=="__main__": main()
