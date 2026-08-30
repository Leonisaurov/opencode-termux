#[cfg(any(target_os = "linux", target_os = "android"))]
fn main() {
    #[cfg(target_os = "linux")]
    codex_linux_sandbox::run_main();
    #[cfg(target_os = "android")]
    {
        eprintln!("codex-linux-sandbox no soportado en Android");
        std::process::exit(1);
    }
}
