# Plan documental del workspace

## Objetivo

Mantener una única guía de enrutamiento para que el trabajo futuro se dirija
al checkout correcto y lea sus instrucciones locales antes de modificar nada.

## Estado de implementación

- [x] Auditar checkouts, artefactos, scripts, workflows y documentación Codex.
- [x] Añadir `AGENTS.md` raíz con rutas para Codex, OpenCode, Kilo, Bun y
      componentes del port.
- [x] Añadir `WORKSPACE.md` como mapa humano breve.
- [x] Enlazar la guía desde el README raíz.
- [x] Eliminar referencias a scripts y parches Codex inexistentes.
- [x] Añadir motor content-addressed en `scripts/build-state.py`, locks y
      manifiestos por nodo.
- [x] Integrar ICU, WebKit, TinyCC, Bun, OpenTUI, OpenCode y empaquetado.
- [x] Integrar Kilo mediante `kilocode_build.sh` y Codex mediante
      `scripts/build-codex-android.sh`.
- [x] Añadir pruebas de hit, invalidación por fuente y propagación de
      dependencias.
- [ ] Ejecutar preflight y builds pesados en el host/CI con aprobación de
      escalada; esta fase no los lanza automáticamente.

## Criterio de mantenimiento

Los checkouts upstream conservan su documentación propia. La raíz solo
documenta integración, portabilidad Android/Termux, rutas y artefactos que
realmente existen en este workspace.
