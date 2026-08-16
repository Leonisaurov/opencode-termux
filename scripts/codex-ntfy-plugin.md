# Plugin ntfy opcional para Codex

El plugin consume la API opt-in de `codex-tui`; no inicia Codex ni modifica el
código del port por sí mismo. La TUI continúa funcionando localmente y el
plugin solo añade el canal remoto.

En una terminal inicia Codex con la API habilitada:

```sh
export CODEX_APPROVAL_API=1
export CODEX_APPROVAL_API_TOKEN='token-api'
export CODEX_APPROVAL_API_LISTEN='0.0.0.0:10010'
./codex-android
```

En otra terminal configura y ejecuta el plugin:

```sh
export CODEX_APPROVAL_API_TOKEN='token-api'
export CODEX_NTFY_HOOK_TOKEN='token-webhook'
export CODEX_NTFY_PUBLISH_TOKEN='token-ntfy'
export NTFY_URL='http://localhost:8086'
export NTFY_TOPIC='codex'
export CODEX_NTFY_CALLBACK_HOST='192.168.1.50'
bun run scripts/codex-ntfy-plugin.ts
```

El teléfono se suscribe al topic `codex`. El botón `⋯` abre el panel vivo del
plugin. Las decisiones llegan a la misma cola de aprobaciones de la TUI; las
reglas de prefijo permanecen en memoria y no escriben `default.rules`.
