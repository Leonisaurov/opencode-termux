# Mapa del workspace

Consulta primero [AGENTS.md](AGENTS.md). Ese archivo contiene las reglas
operativas y el enrutamiento obligatorio. Este documento resume únicamente la
topología para navegación humana.

## Árbol de trabajo

- `codex/`: checkout upstream de Codex. Todo trabajo de Codex empieza allí y
  debe leer sus instrucciones locales.
- `opencode-src/`: checkout upstream de OpenCode usado como fuente de trabajo.
- `build/opencode-src-latest/`: checkout generado/cacheado; sirve para builds y
  comparación, no para conservar cambios manuales.
- `build/kilocode-src-latest/`: checkout generado/cacheado de Kilo.
- `bun-source/`: fuente de Bun, incluida para el runtime Android.
- `patches/`: parches del port para Bun, WebKit, Zig y OpenTUI.
- `scripts/`: preparación, compilación, empaquetado y utilidades del port.
- `.github/workflows/`: CI de Bun, OpenCode, OpenTUI, Codex/V8 y paquetes.
- `termux-packages/`: recetas y herramientas de paquetes Termux.
- `build/`: área regenerable de fuentes externas, caches, marcadores y salidas.

## Artefactos Codex presentes

- `codex-android`: CLI Codex para Android/aarch64, API 24.
- `codex-code-mode-host`: companion de code mode para Android/aarch64.
- `codex-linux-sandbox`: wrapper proot usado por el CLI en Termux.
- `scripts/codex-ntfy-relay.ts`: relay opcional de aprobaciones de
  `codex app-server`; su uso está documentado en el Markdown junto al script.

Los binarios son artefactos y pueden quedar obsoletos respecto a `codex/`.
Comprueba siempre `file`, el commit fuente, el workflow y los marcadores de
`build/` antes de atribuirles una versión.
