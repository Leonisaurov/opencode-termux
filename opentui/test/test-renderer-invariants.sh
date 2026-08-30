#!/usr/bin/env bash
# Verify that the Android renderer fixes are present in the versioned OpenTUI
# commits. The test intentionally does not modify or re-apply source files.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

check_source() {
    local source="$1" label="$2"
    local source_rel="${source#"$ROOT/"}"
    test -f "$source/packages/core/src/zig/renderer.zig"
    test -f "$source/packages/core/src/zig/grapheme.zig"
    test -f "$source/packages/core/src/zig/link.zig"
    test ! -e "$source/.git"
    git -C "$ROOT" ls-files --error-unmatch \
        "$source_rel/packages/core/src/zig/renderer.zig" \
        "$source_rel/packages/core/src/zig/grapheme.zig" \
        "$source_rel/packages/core/src/zig/link.zig" >/dev/null

    rg -q 'OTUI Android fix' "$source/packages/core/src/zig/renderer.zig"
    rg -q 'RETIRED_GENERATION|retired_slot_count' "$source/packages/core/src/zig/grapheme.zig"
    rg -q 'RETIRED_GENERATION|retired_slot_count' "$source/packages/core/src/zig/link.zig"
    echo "$label: versioned renderer invariants OK"
}

check_source "$ROOT/opentui/src/opencode" "OpenCode OpenTUI"
check_source "$ROOT/opentui/src/kilo" "Kilo OpenTUI"
echo "ALL VERSIONED RENDERER INVARIANT TESTS PASSED"
