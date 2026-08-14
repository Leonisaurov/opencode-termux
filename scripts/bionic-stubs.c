/* Stubs bionic para símbolos que el libc++ custom de V8 (rusty_v8 150.4.0,
 * use_custom_libcxx) referencia y que bionic API 24 no exporta:
 *   - __clear_cache: esperado por el JIT de V8 (cpu-arm64.cc); bionic API 24
 *     no lo exporta (vive en compiler-rt del NDK, que se linkea aparte;
 *     este stub lo define también por robustez — el linker solo extrae del
 *     archive compiler-rt los miembros con símbolos aún indefinidos, así que
 *     no hay duplicado).
 *   - aligned_alloc: bionic lo añade en API 28; memalign existe desde API 16.
 *   - strtof_l / strtod_l: en bionic viven como static __inline en
 *     bits/stdlib_inlines.h (libc.so solo los exporta desde API 26) → un
 *     binario precompilado (librusty_v8.a) que los referencia como símbolos
 *     externos necesita una definición fuerte aquí.
 *
 * OJO: NO se incluye <stdlib.h> — bionic ya define strtof_l/strtod_l como
 * static __inline ahí → redefinición en compilación. Los prototipos de
 * memalign/strtof/strtod se declaran manualmente (firmas estándar, ABI
 * estable desde API 16).
 */
#include <locale.h>
#include <stddef.h>

void *memalign(size_t, size_t);          /* bionic, API 16+ */
float strtof(const char *__restrict, char **__restrict);   /* bionic, API 16+ */
double strtod(const char *__restrict, char **__restrict);  /* bionic, API 16+ */

void *aligned_alloc(size_t alignment, size_t size) {
  return memalign(alignment, size);
}

float strtof_l(const char *__restrict nptr, char **__restrict endptr,
               locale_t loc) {
  (void)loc;
  return strtof(nptr, endptr);
}

double strtod_l(const char *__restrict nptr, char **__restrict endptr,
                locale_t loc) {
  (void)loc;
  return strtod(nptr, endptr);
}

/* __clear_cache: esperado por V8 JIT (cpu-arm64.cc); bionic API 24 no lo
 * exporta. El builtin de clang genera las instrucciones ARM64 correctas. */
void __clear_cache(void *beg, void *end) {
  __builtin___clear_cache(beg, end);
}
