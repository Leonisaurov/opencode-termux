#!/usr/bin/env bash
# Verify that the Android renderer fixes are present in the versioned OpenTUI
# commits. The test intentionally does not modify or re-apply source files.
#
# The two trees are pinned to different OpenTUI generations and therefore keep
# different layouts and different provenance for each fix:
#   - kilo: pre-0.5 layout (packages/core/src/zig) with all guards port-derived.
#   - opencode: 0.5.14 layout (packages/native) where upstream absorbed the
#     link/grapheme generation hardening and the renderer attributes narrowing.
# Each assertion below is therefore written against the tree that owns it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

require_tracked() {
    local source="$1" source_rel="${1#"$ROOT/"}"
    shift
    for rel in "$@"; do
        test -f "$source/$rel"
        git -C "$ROOT" ls-files --error-unmatch "$source_rel/$rel" >/dev/null
    done
}

check_kilo_source() {
    local source="$ROOT/opentui/src/kilo"
    local zig="$source/packages/core/src/zig"
    local zig_rel="packages/core/src/zig"
    require_tracked "$source" \
        "$zig_rel/renderer.zig" "$zig_rel/grapheme.zig" "$zig_rel/link.zig"
    test ! -e "$source/.git"

    rg -q 'OTUI Android fix' "$zig/renderer.zig"
    rg -q 'RETIRED_GENERATION|retired_slot_count' "$zig/grapheme.zig"
    rg -q 'RETIRED_GENERATION|retired_slot_count' "$zig/link.zig"
    if rg -q '@intCast\(cell\.attributes\)' "$zig/renderer.zig"; then
        echo "ERROR: renderer narrows cell.attributes (u32) to i32; the link id lives in bits 8-31, so bit 31 panics with 'integer does not fit in destination type'" >&2
        return 1
    fi
    echo "Kilo OpenTUI: versioned renderer invariants OK"
}

check_opencode_source() {
    local source="$ROOT/opentui/src/opencode"
    local zig="$source/packages/native/src"
    local zig_rel="packages/native/src"
    require_tracked "$source" \
        "$zig_rel/renderer.zig" "$zig_rel/grapheme.zig" "$zig_rel/link.zig" \
        "$zig_rel/clipboard/host.zig" \
        "packages/native/build.zig" "packages/native/src/vendor/zig-deps.tar.gz" \
        "packages/native/scripts/prepare-zig-deps.sh"
    test ! -e "$source/.git"

    # Hardening that 0.5.14 took upstream: generation retirement on both pools.
    rg -q 'RETIRED_GENERATION' "$zig/link.zig"
    rg -q 'retired_slot_count' "$zig/link.zig"
    rg -q 'GENERATION_MASK' "$zig/grapheme.zig"
    if rg -q '@intCast\(cell\.attributes\)' "$zig/renderer.zig"; then
        echo "ERROR: renderer narrows cell.attributes (u32) to i32; the link id lives in bits 8-31, so bit 31 panics with 'integer does not fit in destination type'" >&2
        return 1
    fi
    # Android adaptations kept in this tree: the Bionic link guard (dl and
    # pthread are folded into libc.so, so -ldl/-lpthread must not be requested
    # for an Android ABI) and the translate-c Bionic configuration (Zig's
    # TranslateC step propagates neither --libc nor the driver's Android
    # predefines, so miniaudio.h/Yoga.h lose the headers, the API level, and
    # choke on Bionic's array-typed _Nullable).
    rg -q 'OTUI Android fix' "$source/packages/native/build.zig"
    rg -q 'target\.result\.abi != \.android' "$source/packages/native/build.zig"
    rg -q 'addSystemIncludePath' "$source/packages/native/build.zig"
    rg -q '__ANDROID_MIN_SDK_VERSION__=\{d\}' "$source/packages/native/build.zig"
    rg -q 'defineCMacroRaw\("_Nullable="\)' "$source/packages/native/build.zig"
    rg -q 'bionic-api-level' "$ROOT/opentui/scripts/build-opentui.sh"
    # Bionic exports neither pthread_tryjoin_np nor pthread_timedjoin_np, and an
    # undefined reference to either survives the link and aborts the dlopen on
    # the device. The clipboard worker therefore probes liveness with
    # pthread_kill(handle, 0) (ESRCH once a joinable thread has exited).
    rg -q 'OTUI Android fix' "$zig/clipboard/host.zig"
    rg -q 'builtin\.abi == \.android' "$zig/clipboard/host.zig"
    if rg -q '\.linux => switch \(pthread_tryjoin_np' "$zig/clipboard/host.zig"; then
        echo "ERROR: clipboard worker calls pthread_tryjoin_np on the Android path; the symbol does not exist in Bionic and libopentui.so would fail to load" >&2
        return 1
    fi
    # CI has to reject that class of artifact instead of publishing a green build
    # that cannot be dlopened: the NDK stub libraries are the public Bionic API.
    rg -q 'Verify dynamic symbols resolve against Bionic' "$ROOT/.github/workflows/build-opentui.yml"
    rg -q 'comm -23 "\$UNDEF" "\$BIONIC"' "$ROOT/.github/workflows/build-opentui.yml"
    echo "OpenCode OpenTUI: versioned renderer invariants OK"
}

check_opencode_source
check_kilo_source
echo "ALL VERSIONED RENDERER INVARIANT TESTS PASSED"
