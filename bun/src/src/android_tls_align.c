/**
 * Android TLS alignment shim.
 *
 * On ARM64, Android's Bionic dynamic linker requires the ELF TLS segment
 * to have p_align >= 64 bytes (to reserve 8 TCB slots before the TLS data).
 * The Zig linker emits p_align based on the maximum alignment of all TLS
 * variables, which defaults to 8 for Zig threadlocal variables.
 *
 * This file provides a dummy __thread variable with alignment 64, which
 * forces the linker (lld) to:
 *   1. Set PT_TLS p_align = 64
 *   2. Compute tp_offset = round_up(2*sizeof(void*), 64) = 64
 *   3. Resolve all R_AARCH64_TLSLE_ADD_TPREL relocations with tp_offset=64
 *
 * Without this, the Zig linker would emit p_align=8, lld would compute
 * tp_offset=16, and all TLS accesses would collide with Bionic's TCB slots,
 * corrupting critical runtime state (DTV, thread_id, scudo allocator, etc.).
 *
 * This file MUST be compiled with the Android NDK and linked into the final
 * binary alongside the Zig object file.
 */

#if defined(__ANDROID__) && defined(__aarch64__)
__attribute__((aligned(64)))
static __thread char _android_tls_align_dummy[64];

/* Prevent the compiler from optimizing away the variable */
void *_android_tls_align_anchor(void) {
    return (void *)_android_tls_align_dummy;
}
#endif
