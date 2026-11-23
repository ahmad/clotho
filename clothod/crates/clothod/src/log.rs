//! clothod.log lines.

/// A line in clothod.log, with the time (UTC): what closed panes and answered requests, which
/// clients don't log anywhere else, and what became of each push alert.
pub fn line(msg: impl std::fmt::Display) {
    let t = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
    let (secs, ms) = (t.as_secs() as i64, t.subsec_millis());
    // Civil date from days since 1970-01-01 (Howard Hinnant's algorithm).
    let z = secs.div_euclid(86400) + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    let sod = secs.rem_euclid(86400);
    eprintln!("clothod: {y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}.{ms:03}Z {msg}", sod / 3600, sod / 60 % 60, sod % 60);
}
