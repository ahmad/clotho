//! `~/.config/clothod/config.toml` (or `$XDG_CONFIG_HOME/clothod/config.toml`, or
//! `$CLOTHOD_CONFIG`), read when serve starts:
//!
//! ```toml
//! # Lines of history each pane keeps in the daemon: what a reattaching or newly started app
//! # gets back. Each 1000 lines cost cols × 24 bytes × 1000 (2.9 MB at 120 columns) once used.
//! scrollback_lines = 2000
//! ```

use std::path::PathBuf;

pub const DEFAULT_SCROLLBACK: usize = clotho_vt::DEFAULT_SCROLLBACK;
pub const MAX_SCROLLBACK: usize = 100_000;

pub fn path() -> Option<PathBuf> {
    if let Some(p) = std::env::var_os("CLOTHOD_CONFIG").filter(|p| !p.is_empty()) {
        return Some(p.into());
    }
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .filter(|p| !p.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))?;
    Some(base.join("clothod").join("config.toml"))
}

pub fn scrollback_lines() -> usize {
    let Some(path) = path() else { return DEFAULT_SCROLLBACK };
    let Ok(text) = std::fs::read_to_string(&path) else { return DEFAULT_SCROLLBACK };
    let doc = match text.parse::<toml_edit::DocumentMut>() {
        Ok(d) => d,
        Err(e) => {
            eprintln!("clothod: ignoring {}: {e}", path.display());
            return DEFAULT_SCROLLBACK;
        }
    };
    match doc.get("scrollback_lines").map(|v| v.as_integer()) {
        None => DEFAULT_SCROLLBACK,
        Some(Some(n)) if (0..=MAX_SCROLLBACK as i64).contains(&n) => n as usize,
        Some(_) => {
            eprintln!("clothod: {}: scrollback_lines must be an integer 0..={MAX_SCROLLBACK}; using {DEFAULT_SCROLLBACK}", path.display());
            DEFAULT_SCROLLBACK
        }
    }
}
