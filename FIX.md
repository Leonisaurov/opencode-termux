# Estado de la migración de fuentes

La corrección del problema histórico de Bun heap-tagging ya no se entrega como
un parche aplicado durante CI. Su implementación vive en el commit de Bun
fijado por [`ci/source-manifest.json`](ci/source-manifest.json).

La validación local del contrato es:

```sh
python3 ci/scripts/validate-source-tree.py
```

El verificador exige que cada checkout exista, apunte al commit exacto y esté
limpio. Las adaptaciones que aún pertenecen a fuentes externas (WebKit, Zig
vendorizado de Bun y Rusty V8) deben publicarse en commits reproducibles antes
de retirar sus archivos históricos; el CI no los aplica silenciosamente.
