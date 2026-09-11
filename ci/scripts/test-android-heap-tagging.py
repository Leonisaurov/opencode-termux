#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "bun/src/src/main.zig"
ENV_LOADER = ROOT / "bun/src/src/env_loader.zig"
BUN_FS = ROOT / "bun/src/src/fs.zig"
RUN_COMMAND = ROOT / "bun/src/src/cli/run_command.zig"
VIRTUAL_MACHINE = ROOT / "bun/src/src/bun.js/VirtualMachine.zig"
INSTALL = ROOT / "bun/src/src/install/install.zig"
NPM = ROOT / "bun/src/src/install/npm.zig"


def main() -> None:
    source = SOURCE.read_text(encoding="utf-8")
    env_loader = ENV_LOADER.read_text(encoding="utf-8")
    bun_fs = BUN_FS.read_text(encoding="utf-8")
    run_command = RUN_COMMAND.read_text(encoding="utf-8")
    virtual_machine = VIRTUAL_MACHINE.read_text(encoding="utf-8")
    install = INSTALL.read_text(encoding="utf-8")
    npm = NPM.read_text(encoding="utf-8")
    assert 'extern "c" fn mallopt' not in source
    assert 'bun.sys.dlsymImpl(null, "mallopt")' in source
    assert "const M_BIONIC_SET_HEAP_TAGGING_LEVEL: c_int = -204;" in source
    assert "const M_HEAP_TAGGING_LEVEL_NONE: c_int = 0;" in source
    assert "const Mallopt = *const fn" in source
    assert "export const android_heap_tagging_ctor" in source
    assert "linksection(\".init_array\")" in source
    assert source.count("android_disable_heap_tagging();") == 1
    assert "std.mem.span(std.c.environ)" in env_loader
    assert "std.os.environ.len > 0 or !Environment.isAndroid" in env_loader
    assert 'if (comptime Environment.isAndroid) "/data/data/com.termux/files/usr/tmp" else "/tmp"' in bun_fs
    assert "RealFS.getDefaultTempDir()" in run_command
    assert "std.fmt.bufPrintZ" in run_command
    assert "fn once() [:0]const u8" in run_command
    assert "pub fn bunNodeDir() [:0]const u8" in run_command
    assert "bunNodeDir() ++" not in run_command
    assert "force_using_bun or !found_node or (comptime Environment.isAndroid)" in run_command
    assert 'strings.indexOf(spec_slice, "android-arm64")' in virtual_machine
    assert '"{s}linux-arm64{s}"' in virtual_machine
    assert "ensureBunGhostPackageExists" in install
    assert 'strings.eqlComptime(name_str, "bun")' in install
    assert "linux | if (Environment.isAndroid) android else 0" in npm


if __name__ == "__main__":
    main()
