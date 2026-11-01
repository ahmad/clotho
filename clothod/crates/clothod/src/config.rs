//! `~/.config/clothod/config.toml` (or `$XDG_CONFIG_HOME/clothod/config.toml`, or
//! `$CLOTHOD_CONFIG`), read when serve starts. `settings.set` writes it (keeping comments and
//! other keys):
//!
//! ```toml
//! # Lines of history each pane keeps in the daemon: what a reattaching or newly started app
//! # gets back. Each 1000 lines cost cols × 24 bytes × 1000 (2.9 MB at 120 columns) once used:
//! # measured, one full 120-column pane takes 8 MB of serve heap at 2000 lines, 142 MB at 50000.
//! scrollback_lines = 2000
//! # Notification text rewritten by Claude Haiku through this machine's claude login
//! # (crate::summary). Off: the agent's own text, cleaned of Markdown.
//! notification_rewrite = true
//! ```

use std::path::PathBuf;

pub const DEFAULT_SCROLLBACK: usize = clotho_vt::DEFAULT_SCROLLBACK;
/// Per pane. 50000 full lines at 120 columns are 142 MB of serve heap (measured), already a
/// third of the 400 MB the soak allows serve; 100000 were 282 MB.
pub const MAX_SCROLLBACK: usize = 50_000;

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
        Some(Some(n)) if n > MAX_SCROLLBACK as i64 => {
            eprintln!("clothod: {}: scrollback_lines {n} is over the limit; using {MAX_SCROLLBACK}", path.display());
            MAX_SCROLLBACK
        }
        Some(_) => {
            eprintln!("clothod: {}: scrollback_lines must be an integer 0..={MAX_SCROLLBACK}; using {DEFAULT_SCROLLBACK}", path.display());
            DEFAULT_SCROLLBACK
        }
    }
}

/// `notification_rewrite` (default on). Anything but a boolean is ignored, with a log line.
pub fn notification_rewrite() -> bool {
    let Some(path) = path() else { return true };
    let Ok(text) = std::fs::read_to_string(&path) else { return true };
    let Ok(doc) = text.parse::<toml_edit::DocumentMut>() else { return true };
    match doc.get("notification_rewrite").map(|v| v.as_bool()) {
        None => true,
        Some(Some(b)) => b,
        Some(None) => {
            eprintln!("clothod: {}: notification_rewrite must be true or false; using true", path.display());
            true
        }
    }
}

pub fn set_notification_rewrite(on: bool) -> Result<PathBuf, String> {
    set_value("notification_rewrite", toml_edit::value(on))
}

/// Store `scrollback_lines` in the config file (created if missing), keeping everything else in
/// it. Refuses to touch a file it can't parse rather than lose what is in it.
pub fn set_scrollback_lines(n: usize) -> Result<PathBuf, String> {
    if n > MAX_SCROLLBACK {
        return Err(format!("scrollback_lines must be 0..={MAX_SCROLLBACK}"));
    }
    set_value("scrollback_lines", toml_edit::value(n as i64))
}

/// Store one key in the config file (created if missing), keeping everything else in it.
fn set_value(key: &str, value: toml_edit::Item) -> Result<PathBuf, String> {
    let path = path().ok_or("no config path (HOME is not set)")?;
    // A symlinked config (dotfiles) stays a symlink: write where it points.
    let path = std::fs::canonicalize(&path).unwrap_or(path);
    let text = match std::fs::read_to_string(&path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(e) => return Err(format!("{}: {e}", path.display())),
    };
    let mut doc = text.parse::<toml_edit::DocumentMut>().map_err(|e| format!("{} is not valid TOML, not changing it: {e}", path.display()))?;
    doc[key] = value;
    // Atomic, keeping the file's permissions.
    crate::write_atomic(&path, doc.to_string().as_bytes()).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(path)
}
