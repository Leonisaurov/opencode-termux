//! Client version reported to the Codex backend.
//!
//! CODEX-TERMUX-ANDROID-PATCH: the backend gates models by their
//! `minimal_client_version` (for example `gpt-5.6-luna` needs 0.144.0 and
//! `gpt-6-astra` needs 0.153.0). A port pinned to an older upstream release
//! therefore only ever sees the models that its build version satisfies, and
//! every newer model fails the turn with
//! "requires a newer version of Codex".
//!
//! [`reported_client_version`] lets a build report a different version through
//! `CODEX_REPORTED_CLIENT_VERSION` so a newer catalog can be exercised without
//! re-vendoring the whole upstream tree. The override is off by default: unset
//! the variable and the build version is reported again.

use std::env;

/// Environment variable overriding the version reported to the backend.
pub const REPORTED_CLIENT_VERSION_ENV: &str = "CODEX_REPORTED_CLIENT_VERSION";

/// Drops a semantic-version pre-release/build suffix: `1.2.3-alpha.4` -> `1.2.3`.
pub fn whole_version(version: &str) -> String {
    let without_suffix = version
        .split_once(['-', '+'])
        .map_or(version, |(whole, _suffix)| whole);
    without_suffix.trim().to_string()
}

/// Version reported in the HTTP `User-Agent`.
pub fn reported_client_version() -> String {
    env::var(REPORTED_CLIENT_VERSION_ENV)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| env!("CARGO_PKG_VERSION").to_string())
}

/// Whole version reported to the models endpoint (`client_version` parameter).
pub fn reported_whole_client_version() -> String {
    whole_version(&reported_client_version())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn whole_version_drops_prerelease_and_build_suffixes() {
        assert_eq!(whole_version("0.155.1"), "0.155.1");
        assert_eq!(whole_version("0.134.0-alpha.3"), "0.134.0");
        assert_eq!(whole_version("1.2.3-rc.1+build.7"), "1.2.3");
        assert_eq!(whole_version(" 0.155.1 "), "0.155.1");
    }

    #[test]
    fn reported_version_falls_back_to_build_version() {
        // The override is read from the process environment; guard the real one.
        let expected = env!("CARGO_PKG_VERSION").to_string();
        if env::var(REPORTED_CLIENT_VERSION_ENV).is_err() {
            assert_eq!(reported_client_version(), expected);
            assert_eq!(reported_whole_client_version(), whole_version(&expected));
        }
    }

    #[test]
    fn reported_version_uses_whole_override() {
        // SAFETY: single-threaded test process mutation of our own variable.
        unsafe { env::set_var(REPORTED_CLIENT_VERSION_ENV, "0.155.1") };
        assert_eq!(reported_client_version(), "0.155.1");
        assert_eq!(reported_whole_client_version(), "0.155.1");
        unsafe { env::remove_var(REPORTED_CLIENT_VERSION_ENV) };
    }
}
