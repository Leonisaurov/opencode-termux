#!/usr/bin/env python3
import subprocess
import textwrap
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
HELPER = (ROOT / "ci/scripts/module-graph-patch.ts").as_posix()


def main() -> None:
    script = textwrap.dedent(
        f"""
        import {{ patchAndroidModuleGraph, validateAndroidModuleGraph }} from {HELPER!r};

        const trailer = Buffer.from("\\n---- Bun! ----\\n");
        function graph(source) {{
          const strings = Buffer.from(source, "latin1");
          const offsets = Buffer.alloc(32);
          offsets.writeBigUInt64LE(BigInt(strings.length), 0);
          offsets.writeUInt32LE(strings.length, 8);
          offsets.writeUInt32LE(0, 12);
          offsets.writeUInt32LE(0, 16);
          offsets.writeUInt32LE(0, 20);
          offsets.writeUInt32LE(0, 24);
          offsets.writeUInt32LE(0, 28);
          return new Uint8Array(Buffer.concat([strings, offsets, trailer]));
        }}
        function expectFailure(fn, text) {{
          try {{ fn(); }} catch (error) {{
            if (!String(error).includes(text)) throw error;
            return;
          }}
          throw new Error(`expected failure containing ${{text}}`);
        }}

        const opencodeSource = 'var exports_Undici={{}};__export(exports_Undici, {{default: () => Undici_default}});import Undici from "undici";import"undici";var Undici_default;var init=()=>{{__reExport(exports_Undici, undici);Undici_default = Undici}}';
        const opencode = graph(opencodeSource);
        const opencodePatched = patchAndroidModuleGraph(opencode, "opencode");
        if (opencodePatched.patchCount !== 1) throw new Error("OpenCode patch count");
        validateAndroidModuleGraph(opencodePatched.graph, "opencode");
        if (patchAndroidModuleGraph(opencodePatched.graph, "opencode").patchCount !== 0) throw new Error("OpenCode patch is not idempotent");
        const kiloSource = 'var _ZH={{}};QA(_ZH,{{default:()=>Xt6}});import qt6 from"undici";import"undici";var Xt6;var pk1=a(()=>{{ihA(_ZH,Ie7);Xt6=qt6}})';
        const kiloPatched = patchAndroidModuleGraph(graph(kiloSource), "kilo");
        if (kiloPatched.patchCount !== 1) throw new Error("Kilo patch count");
        validateAndroidModuleGraph(kiloPatched.graph, "kilo");
        if (patchAndroidModuleGraph(kiloPatched.graph, "kilo").patchCount !== 0) throw new Error("Kilo patch is not idempotent");

        validateAndroidModuleGraph(graph('var x=1'), "opencode");
        validateAndroidModuleGraph(graph('var _ZH={{}};QA(_ZH,{{default:()=>Xt6}});import qt6 from"undici";import"undici";var Xt6;var pk1=a(()=>{{ihA(_ZH,qt6);Xt6=qt6}})'), "kilo");
        expectFailure(() => validateAndroidModuleGraph(new Uint8Array(Buffer.from("bad")), "opencode"), "shorter than");
        expectFailure(() => patchAndroidModuleGraph(graph('var exports_Undici={{}};__export(exports_Undici, {{default: () => Undicii}});import Undicii from "undici";import"undici";var Undicii;var init=()=>{{__reExport(exports_Undici, undici);Undicii = Undicii}}'), "opencode"), "length differs");
        expectFailure(() => patchAndroidModuleGraph(graph('var _ZH={{}};QA(_ZH,{{default:()=>Xt6}});import qt6 from"undici";import"undici";var Xt6;var pk1=a(()=>{{ihA(_ZH,Ie7);foo(_ZH,Abc);Xt6=qt6}})'), "kilo"), "ambiguous");
        console.log("module graph patch tests: OK");
        """
    )
    result = subprocess.run(["bun", "-e", script], text=True, capture_output=True)
    if result.returncode:
        raise SystemExit(result.stderr or result.stdout)
    print(result.stdout, end="")


if __name__ == "__main__":
    main()
