# FIX: Bun Android heap-tagging patch rejected by CI

## Estado

The Bun job in run `33322306630` failed before compilation. Rusty V8 had
already completed successfully. The run was cancelled while Codex was still
running, so no Bun artifact or Bun intermediate cache was produced.

## Causa raíz

`bun/patches/bun/android-heap-tagging.patch` was not a valid patch for the
exact Bun `1.2.13` source checkout used by CI.

The hunk was declared as:

```diff
@@ -18,4 +18,39 @@
```

but it omitted existing blank context lines from `src/main.zig` and its old
and new line counts did not describe the hunk contents. Consequently, after
`android-support.patch` applied, `git apply` reported:

```text
error: patch failed: src/main.zig:18
error: src/main.zig: patch does not apply
```

This was a patch-format/context error, not a compiler error, linker error,
cache miss, zram failure, or evidence that the heap-tagging mitigation works
on a device.

## Evidence

CI used:

- Bun `1.2.13`
- resolved source commit `64ed68c9e0faa7f5224876be8681d2bdc311454b`
- Android API `24`
- target `aarch64-linux-android`

The exact upstream file has blank lines between the `extern` declaration,
the environment declarations, and `main()`. The rejected patch did not carry
those blank lines as context. `git apply --stat` only verified patch metadata;
it did not prove that the hunk applies to the post-`android-support.patch`
source tree.

## Corrección aplicada

La cabecera del hunk fue regenerada para el `src/main.zig` posterior al
parche de soporte Android: ahora declara correctamente `+35` líneas añadidas
y conserva el contexto real del checkout Bun `1.2.13`. `apply-patches.sh`
también valida cada parche en orden, acepta una aplicación ya realizada y
falla ante cualquier estado ambiguo; no elimina el checkout ni los parches
intencionales del proyecto.

La comprobación secuencial del checkout exacto pasó con este orden:

```sh
git apply --check bun/patches/bun/android-support.patch
git apply bun/patches/bun/android-support.patch
git apply --check bun/patches/bun/android-heap-tagging.patch
git apply bun/patches/bun/android-heap-tagging.patch
```

The heap-tagging check must run after the support patch: its context is the
post-support `src/main.zig` layout. `git apply --stat` alone is not a validity
check.

El parche queda listo para CI. El binario Android todavía requiere una prueba
smoke en un dispositivo; aplicar el parche no demuestra por sí solo que el
abort por tagged pointers esté resuelto.
