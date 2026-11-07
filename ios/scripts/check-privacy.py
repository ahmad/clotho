#!/usr/bin/env python3
"""Checks Clotho's privacy manifests (PrivacyInfo.xcprivacy). Python 3 standard library only; run it with
`python3 -I`.

Usage:
  check-privacy.py superset BASE TAILNET
      TAILNET (ios/Tailnet's manifest, which replaces the app's in CLOTHO_TAILNET=1 builds) must declare everything
      BASE does: the same tracking flag and collected data, every tracking domain, and every category with at least
      BASE's reasons. tailnet.yml's post-build script runs it before copying TAILNET over BASE in the built app.
  check-privacy.py sources [IOS_DIR]
      Lints the committed manifests (Clotho, ClothoNotify, ClothoWidget, Tailnet) and runs `superset` on Clotho
      against Tailnet. Works anywhere, Linux included. build.sh and testflight.sh run it before building.
  check-privacy.py bundle BUNDLE... [--no-imports]
      macOS only. Each built bundle (the .app, each .appex) must have a top-level PrivacyInfo.xcprivacy that passes
      `plutil -lint` and the schema, and, unless --no-imports, must declare every required-reason category its own
      executable imports (`xcrun nm -u`, plus <exe>.debug.dylib in Debug builds). Manifests of nested third-party
      bundles (NIOPosix, Crypto) don't count toward a bundle's own. A declared category nothing imports is a
      warning. build.sh runs it on every simulator build, testflight.sh on the archive.

Exits 1 with an `error:` line per problem (64 for bad usage).
"""
import fnmatch, json, os, plistlib, re, subprocess, sys

# MARK: Required-reason symbols

# Apple's required-reason API list ("Describing use of required reason API",
# https://developer.apple.com/documentation/bundleresources/privacy_manifest_files/describing_use_of_required_reason_api),
# as the undefined symbols `nm -u` shows for a binary that calls them. ios/scripts/tailnet-size.sh measured the app's
# imports with and without the tailnet node. Patterns are fnmatch globs. C functions are matched after any `$...`
# suffix is stripped (`_stat$INODE64`). APIs that are Objective-C methods (NSProcessInfo.systemUptime,
# UITextInputMode.activeInputModes) leave no symbol of their own; the class reference stands in where there is one.
REQUIRED_REASON_SYMBOLS = {
    "NSPrivacyAccessedAPICategoryFileTimestamp": [
        "_stat", "_fstat", "_fstatat", "_lstat", "_stat64", "_fstat64", "_lstat64",
        "_getattrlist", "_fgetattrlist", "_getattrlistat", "_getattrlistbulk",
        "_NSFileCreationDate", "_NSFileModificationDate",
        "_NSURLContentModificationDateKey", "_NSURLCreationDateKey", "_NSURLContentAccessDateKey",
        "_NSURLAttributeModificationDateKey",
    ],
    "NSPrivacyAccessedAPICategorySystemBootTime": [
        "_mach_absolute_time", "_sysctl", "_sysctlbyname",
    ],
    "NSPrivacyAccessedAPICategoryDiskSpace": [
        "_statfs", "_fstatfs", "_statvfs", "_fstatvfs", "_statfs64", "_fstatfs64", "_getattrlist",
        "_NSFileSystemFreeSize", "_NSFileSystemSize",
        "_NSURLVolumeAvailableCapacity*Key", "_NSURLVolumeTotalCapacityKey",
    ],
    "NSPrivacyAccessedAPICategoryActiveKeyboards": [
        "_OBJC_CLASS_$_UITextInputMode",
    ],
    "NSPrivacyAccessedAPICategoryUserDefaults": [
        "_OBJC_CLASS_$_NSUserDefaults", "*UserDefaults*",
        "*AppStorage*",  # SwiftUI's @AppStorage, which reads and writes UserDefaults
    ],
}
CATEGORIES = list(REQUIRED_REASON_SYMBOLS)
REASON = re.compile(r"^[0-9A-F]{4}\.[0-9]$")
# A C function with a variant suffix, e.g. _stat$INODE64; not _OBJC_CLASS_$_X and not Swift's _$s... symbols.
C_SUFFIX = re.compile(r"^(_[A-Za-z_][A-Za-z0-9_]*)\$.*$")
MANIFEST = "PrivacyInfo.xcprivacy"
SOURCES = ["Clotho", "ClothoNotify", "ClothoWidget", "Tailnet"]
TOP_LEVEL = {
    "NSPrivacyTracking": bool,
    "NSPrivacyTrackingDomains": list,
    "NSPrivacyCollectedDataTypes": list,
    "NSPrivacyAccessedAPITypes": list,
}

errors = []


def error(msg):
    errors.append(msg)
    print(f"error: {msg}", file=sys.stderr)


def short(name):
    return name.removeprefix("NSPrivacyAccessedAPICategory")


# MARK: Manifests


def load(path):
    """The parsed manifest, or None after reporting why it can't be read."""
    try:
        with open(path, "rb") as f:
            data = plistlib.load(f)
    except FileNotFoundError:
        error(f"{path}: missing")
        return None
    except Exception as e:  # plistlib raises several kinds (InvalidFileException, ExpatError, ValueError)
        error(f"{path}: not a valid property list ({e})")
        return None
    if not isinstance(data, dict):
        error(f"{path}: the top level isn't a dictionary")
        return None
    return data


def schema(path, m):
    """Reports every schema problem in manifest m; True when there were none."""
    before = len(errors)
    for key, kind in TOP_LEVEL.items():
        if key not in m:
            error(f"{path}: no {key}")
        elif not isinstance(m[key], kind):
            error(f"{path}: {key} isn't a {kind.__name__}")
    for key in sorted(set(m) - set(TOP_LEVEL)):
        error(f"{path}: unknown top-level key {key}")
    if isinstance(m.get("NSPrivacyTrackingDomains"), list):
        for d in m["NSPrivacyTrackingDomains"]:
            if not isinstance(d, str) or not d:
                error(f"{path}: NSPrivacyTrackingDomains has an entry that isn't a domain: {d!r}")
    if isinstance(m.get("NSPrivacyCollectedDataTypes"), list):
        for d in m["NSPrivacyCollectedDataTypes"]:
            if not isinstance(d, dict):
                error(f"{path}: NSPrivacyCollectedDataTypes has an entry that isn't a dictionary: {d!r}")
    seen = set()
    for entry in m.get("NSPrivacyAccessedAPITypes") if isinstance(m.get("NSPrivacyAccessedAPITypes"), list) else []:
        if not isinstance(entry, dict):
            error(f"{path}: NSPrivacyAccessedAPITypes has an entry that isn't a dictionary: {entry!r}")
            continue
        extra = set(entry) - {"NSPrivacyAccessedAPIType", "NSPrivacyAccessedAPITypeReasons"}
        if extra:
            error(f"{path}: unknown keys in an NSPrivacyAccessedAPITypes entry: {', '.join(sorted(extra))}")
        cat = entry.get("NSPrivacyAccessedAPIType")
        if cat not in CATEGORIES:
            error(f"{path}: unknown NSPrivacyAccessedAPIType {cat!r} (known: {', '.join(CATEGORIES)})")
        elif cat in seen:
            error(f"{path}: {cat} is listed twice")
        else:
            seen.add(cat)
        reasons = entry.get("NSPrivacyAccessedAPITypeReasons")
        if not isinstance(reasons, list) or not reasons:
            error(f"{path}: {cat} has no NSPrivacyAccessedAPITypeReasons")
            continue
        for r in reasons:
            if not isinstance(r, str) or not REASON.match(r):
                error(f"{path}: {cat} has a reason that isn't a code like C617.1: {r!r}")
        if len(set(map(str, reasons))) != len(reasons):
            error(f"{path}: {cat} lists a reason twice")
    return len(errors) == before


def declared(m):
    """{category: set of reasons} of a manifest that passed the schema."""
    return {e["NSPrivacyAccessedAPIType"]: set(e["NSPrivacyAccessedAPITypeReasons"])
            for e in m["NSPrivacyAccessedAPITypes"]}


def canonical(items):
    return {json.dumps(i, sort_keys=True, default=str) for i in items}


def superset(base_path, base, tail_path, tail):
    """Reports where tail fails to declare everything base does."""
    if base["NSPrivacyTracking"] != tail["NSPrivacyTracking"]:
        error(f"{tail_path}: NSPrivacyTracking is {tail['NSPrivacyTracking']}, {base_path} says {base['NSPrivacyTracking']}")
    missing = set(base["NSPrivacyTrackingDomains"]) - set(tail["NSPrivacyTrackingDomains"])
    if missing:
        error(f"{tail_path}: lacks the tracking domains {', '.join(sorted(missing))} that {base_path} lists")
    if canonical(base["NSPrivacyCollectedDataTypes"]) != canonical(tail["NSPrivacyCollectedDataTypes"]):
        error(f"{tail_path}: NSPrivacyCollectedDataTypes differs from {base_path}'s")
    b, t = declared(base), declared(tail)
    for cat, reasons in b.items():
        if cat not in t:
            error(f"{tail_path}: lacks {cat}, which {base_path} declares")
        elif not reasons <= t[cat]:
            error(f"{tail_path}: {cat} lacks {', '.join(sorted(reasons - t[cat]))}, which {base_path} declares")


def load_checked(path):
    m = load(path)
    return m if m is not None and schema(path, m) else None


def cmd_superset(args):
    if len(args) != 2:
        usage()
    base, tail = load_checked(args[0]), load_checked(args[1])
    if base is not None and tail is not None:
        superset(args[0], base, args[1], tail)


def cmd_sources(args):
    if len(args) > 1:
        usage()
    ios = args[0] if args else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    manifests = {name: load_checked(os.path.join(ios, name, MANIFEST)) for name in SOURCES}
    base, tail = manifests["Clotho"], manifests["Tailnet"]
    if base is not None and tail is not None:
        superset(os.path.join(ios, "Clotho", MANIFEST), base, os.path.join(ios, "Tailnet", MANIFEST), tail)
    if not errors:
        print(f"privacy manifests OK: {', '.join(SOURCES)}")


# MARK: Built bundles


def imports(binary):
    """The undefined symbols of a Mach-O binary, or None after reporting why they can't be read. nm's whole
    output is captured before matching: piping it into a reader that stops early would kill nm with SIGPIPE
    (see scripts/check-no-tailnet.sh)."""
    try:
        out = subprocess.run(["xcrun", "nm", "-u", binary], capture_output=True, text=True)
    except OSError as e:
        error(f"{binary}: couldn't run xcrun nm ({e})")
        return None
    if out.returncode != 0:
        error(f"{binary}: nm failed: {out.stderr.strip()}")
        return None
    syms = set()
    for line in out.stdout.splitlines():
        line = line.strip()
        if not line or line.endswith(":"):  # blank lines and "<file> (for architecture arm64):" headers
            continue
        sym = line.split()[-1]
        if not sym.startswith("_OBJC_"):
            m = C_SUFFIX.match(sym)
            if m:
                sym = m.group(1)
        syms.add(sym)
    return syms


def used_categories(syms):
    """{category: sorted symbols that need it}."""
    used = {}
    for cat, patterns in REQUIRED_REASON_SYMBOLS.items():
        hits = sorted(s for s in syms if any(fnmatch.fnmatchcase(s, p) for p in patterns))
        if hits:
            used[cat] = hits
    return used


def check_bundle(bundle, check_imports):
    name = os.path.basename(os.path.normpath(bundle))
    if not os.path.isdir(bundle):
        error(f"{bundle}: no such bundle")
        return
    path = os.path.join(bundle, MANIFEST)
    if not os.path.isfile(path):
        error(f"{name}: no {MANIFEST} at the top of the bundle")
        return
    lint = subprocess.run(["plutil", "-lint", path], capture_output=True, text=True)
    if lint.returncode != 0:
        error(f"{path}: plutil -lint failed: {(lint.stdout + lint.stderr).strip()}")
        return
    m = load_checked(path)
    if m is None:
        return
    have = declared(m)
    summary = "; ".join(f"{short(c)} {' '.join(sorted(r))}" for c, r in have.items()) or "no required-reason APIs"
    if not check_imports:
        print(f"{name}: {summary} (imports not checked)")
        return
    info = load(os.path.join(bundle, "Info.plist"))
    exe = info.get("CFBundleExecutable") if info is not None else None
    if not isinstance(exe, str) or not exe:
        error(f"{name}: Info.plist names no CFBundleExecutable")
        return
    binaries = [os.path.join(bundle, exe)]
    if not os.path.isfile(binaries[0]):
        error(f"{name}: its executable {exe} is missing")
        return
    debug = os.path.join(bundle, exe + ".debug.dylib")
    if os.path.isfile(debug):
        binaries.append(debug)
    syms = set()
    for b in binaries:
        s = imports(b)
        if s is None:
            return
        syms |= s
    used = used_categories(syms)
    for cat, hits in used.items():
        if cat not in have:
            error(f"{name}: imports {', '.join(hits)} ({short(cat)}), but its {MANIFEST} doesn't declare {cat}")
    for cat in have:
        if cat not in used:
            print(f"warning: {name}: declares {short(cat)}, but imports none of its symbols", file=sys.stderr)
    print(f"{name}: {summary} (imports: {', '.join(short(c) for c in used) or 'none'})")


def cmd_bundle(args):
    check_imports = "--no-imports" not in args
    bundles = [a for a in args if a != "--no-imports"]
    if not bundles or any(b.startswith("--") for b in bundles):
        usage()
    if sys.platform != "darwin":
        error("`bundle` needs macOS (plutil, xcrun nm)")
        return
    for b in bundles:
        check_bundle(b, check_imports)


def usage():
    print("usage: check-privacy.py superset BASE TAILNET\n"
          "       check-privacy.py sources [IOS_DIR]\n"
          "       check-privacy.py bundle BUNDLE... [--no-imports]", file=sys.stderr)
    sys.exit(64)


def main():
    if len(sys.argv) < 2:
        usage()
    cmd = {"superset": cmd_superset, "sources": cmd_sources, "bundle": cmd_bundle}.get(sys.argv[1])
    if cmd is None:
        usage()
    cmd(sys.argv[2:])
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
