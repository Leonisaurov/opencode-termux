#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "bun/scripts/build-webkit.sh"
OVERLAY = ROOT / "bun/webkit"


def main() -> None:
    script = SCRIPT.read_text(encoding="utf-8")
    lines = script.splitlines()
    assert '--input "$WEBKIT_SRC"' not in script
    assert '--value "WEBKIT_COMMIT=$WEBKIT_COMMIT"' in script
    start = lines.index("done <<'EOF'") + 1
    end = lines.index("EOF", start)
    applied = [line for line in lines[start:end] if line]
    available = sorted(path.relative_to(OVERLAY).as_posix() for path in OVERLAY.rglob("*") if path.is_file())
    assert applied == available
    assert all((OVERLAY / relative_path).is_file() for relative_path in applied)


if __name__ == "__main__":
    main()
