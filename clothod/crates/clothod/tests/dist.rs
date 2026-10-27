//! The release rule in scripts/dist.sh: a release must be newer than the last one, compared per
//! numeric component. Version strings don't sort as text ("0.1.10" < "0.1.9"), so this pins it.

fn newer(a: &str, b: &str) -> bool {
    let script = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../scripts/dist.sh");
    let out = std::process::Command::new("sh").arg(&script).args(["--check-newer", a, b]).output().unwrap();
    match out.status.code() {
        Some(0) => true,
        Some(1) => false,
        other => panic!("dist.sh --check-newer {a} {b}: {other:?}\n{}", String::from_utf8_lossy(&out.stderr)),
    }
}

#[test]
fn releases_compare_by_number_not_text() {
    assert!(newer("0.1.10", "0.1.9"));
    assert!(!newer("0.1.9", "0.1.10"));
    assert!(!newer("0.1.10", "0.1.10"), "the same version is not a new release");
    assert!(newer("0.2.0", "0.1.10"));
    assert!(newer("1.0.0", "0.9.99"));
    assert!(newer("0.1.11", "0.1.10"));
    assert!(!newer("0.1.2", "0.1.10"));
    assert!(newer("0.1.0", "0.0.0"), "the first release (no RELEASED file)");
}
