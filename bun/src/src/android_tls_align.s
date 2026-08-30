// Android TLS alignment fix for ARM64 Bionic.
//
// Android's Bionic dynamic linker (API 31+/Android 12+) requires the
// PT_TLS segment to have p_align >= 64 bytes. This is because Bionic's
// Thread Control Block (TCB) uses slots at TPIDR+0..TPIDR+63, and the
// TLS segment starts at round_up(sizeof(tcb_head), p_align).
//
// With p_align=8, the TLS segment starts at TPIDR+16, stomping on
// Bionic's TCB slots (including scudo allocator state). With p_align=64,
// TLS starts at TPIDR+64, leaving all TCB slots intact.
//
// The Zig linker emits p_align=8 for .tbss. This assembly file creates
// a .tbss section with explicit 64-byte alignment, which forces lld to
// compute max(all TLS section alignments) = 64, producing p_align=64
// in the PT_TLS program header.
//
// This MUST be assembled (not compiled as C) to avoid NDK's emulated
// TLS (__emutls) which would produce no real .tbss section at all.

.section .tbss,"awT",@nobits
.balign 64
.global _android_tls_align_force
.hidden _android_tls_align_force
.type _android_tls_align_force,@tls_object
.size _android_tls_align_force,64
_android_tls_align_force:
.zero 64
