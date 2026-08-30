// Stub TLS alineado a 64: bionic ARM64 exige el PT_TLS con p_align >= 64 y
// p_vaddr % 64 == 0 (skew 0). V8 trae thread_local con alineación 8; sin este
// stub el segmento TLS nace con skew != 0 y linker64 aborta ("executable's TLS
// segment is underaligned"). Rust stable no puede emitir .tdata nativo
// (thread_local! -> emutls en android), de ahí el asm.
core::arch::global_asm!(
    ".section .tdata,\"awT\",@progbits",
    ".p2align 6",
    "tls_align_stub:",
    ".fill 64, 1, 0x2a",
    ".previous",
);
unsafe extern "C" {
    fn tls_align_stub() -> i32;
}
#[used]
static TLS_ALIGN_STUB_ANCHOR: unsafe extern "C" fn() -> i32 = tls_align_stub;

use clap::Parser;

#[derive(Debug, Parser)]
struct Cli {
    /// Transport endpoint: `stdio`, `stdio://`, or `ws://IP:PORT`.
    #[arg(
        long,
        value_name = "URL",
        default_value = codex_code_mode_host::DEFAULT_LISTEN_URL
    )]
    listen: String,
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_max_level(tracing::Level::INFO)
        .with_writer(std::io::stderr)
        .with_ansi(false)
        .init();

    codex_code_mode_host::run_main(&Cli::parse().listen).await
}
