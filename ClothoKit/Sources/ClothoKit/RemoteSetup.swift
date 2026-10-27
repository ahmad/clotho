import Foundation

/// The platform-neutral half of running clothod on another machine (docs/remote.md): the probe and
/// install scripts, reading the probe, choosing the bundled build, and the commands for each step.
/// Each platform runs the commands over its own SSH (ssh processes on macOS, SwiftNIO SSH on iOS).
public enum RemoteSetup {
    // Copies of PROBE_SCRIPT and INSTALL_SCRIPT in clothod/crates/cli/src/remote.rs; keep them in sync.

    public static let probeScript = #"""
    echo "clothod-probe=1"
    os=$(uname -s); arch=$(uname -m)
    case "$os" in Linux) os=linux ;; Darwin) os=macos ;; *) os=$(echo "$os" | tr 'A-Z' 'a-z') ;; esac
    case "$arch" in arm64|aarch64) arch=aarch64 ;; x86_64|amd64) arch=x86_64 ;; esac
    echo "os=$os"
    echo "arch=$arch"
    if [ -n "${CLOTHOD_INSTALL_DIR:-}" ]; then base=$CLOTHOD_INSTALL_DIR
    elif [ "$os" = macos ]; then base="$HOME/Library/Application Support/clothod/bin"
    else base="${XDG_DATA_HOME:-$HOME/.local/share}/clothod/bin"; fi
    echo "base=$base"
    installed=""
    for d in "$base"/*/; do n=$(basename "$d"); [ "$n" != current ] && [ -x "${d}clothod" ] && installed="$installed $n"; done
    echo "installed=${installed# }"
    fallback="${TMPDIR:-/tmp}/clothod-bin-$(id -u)"
    echo "fallback_base=$fallback"
    installed=""
    for d in "$fallback"/*/; do [ -x "${d}clothod" ] && installed="$installed $(basename "$d")"; done
    echo "fallback_installed=${installed# }"
    if [ -n "${CLOTHOD_RUNTIME_DIR:-}" ]; then rt=$CLOTHOD_RUNTIME_DIR
    elif [ "$os" = macos ]; then rt="$(getconf DARWIN_USER_TEMP_DIR)clothod"
    else rt="/tmp/clothod-$(id -u)"; fi
    cur=$(readlink "$base/current" 2>/dev/null)
    echo "current=$cur"
    echo "runtime=$rt"
    pid=$(cat "$rt/clothod.pid" 2>/dev/null)
    if [ -S "$rt/clothod.sock" ] && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "daemon=running"
      echo "daemon_pid=$pid"
      exe=$(readlink "/proc/$pid/exe" 2>/dev/null || ps -o comm= -p "$pid" 2>/dev/null)
      echo "daemon_exe=${exe% (deleted)}"
      [ -x "$base/$cur/clothod" ] && echo "daemon_build=$("$base/$cur/clothod" status --print-builds 2>/dev/null | sed -n 's/^serve=//p')"
    else
      echo "daemon=stopped"
    fi
    hpid=$(cat "$rt/holder.pid" 2>/dev/null)
    if [ -n "$hpid" ] && kill -0 "$hpid" 2>/dev/null; then
      echo "holder_pid=$hpid"
      hexe=$(readlink "/proc/$hpid/exe" 2>/dev/null || ps -o comm= -p "$hpid" 2>/dev/null)
      echo "holder_exe=${hexe% (deleted)}"
      [ -x "$base/$cur/clothod" ] && echo "holder_build=$("$base/$cur/clothod" status --print-builds 2>/dev/null | sed -n 's/^holder=//p')"
    fi
    if mkdir -p "$base" 2>/dev/null && [ -w "$base" ]; then echo "writable=yes"; else echo "writable=no"; fi

    """#

    public static let installScript = #"""
    set -u
    id=$1; base=$2
    d="$base/$id"
    t="$d/.clothod.$$.tmp"
    mkdir -p "$d" 2>/dev/null || { echo "clothod-install: cannot create $d" >&2; exit 5; }
    trap 'rm -f "$t"' EXIT
    cat > "$t" || { echo "clothod-install: cannot write $t (disk full or read-only?)" >&2; exit 5; }
    chmod 755 "$t" || exit 5
    got=$("$t" build-id 2>/dev/null) || { echo "clothod-install: the uploaded binary does not run here (wrong platform, or noexec mount)" >&2; exit 4; }
    [ "$got" = "$id" ] || { echo "clothod-install: uploaded binary is $got, expected $id (truncated upload?)" >&2; exit 4; }
    mv -f "$t" "$d/clothod" || exit 5
    trap - EXIT
    echo "installed=$d/clothod"
    """#

    /// Where to install when the default base isn't writable (remote.md, exit 5). Expanded by the remote shell.
    public static let fallbackBase = #""${TMPDIR:-/tmp}/clothod-bin-$(id -u)""#

    /// The exit code of `start` and `bridge` when the running holder can't be driven by this build.
    public static let holderTooOldExit: Int32 = 3

    /// What the probe found.
    public struct Probe: Equatable, Sendable {
        public var os: String
        public var arch: String
        public var base: String
        public var installed: [String]
        public var runtime: String
        public var daemonRunning: Bool
        public var daemonExe: String?
        public var writable: Bool
        /// The build `<base>/current` points at (empty before `current` existed).
        public var current: String?
        /// The builds the running serve and holder report (from `status --print-builds`).
        public var daemonBuild: String?
        public var holderBuild: String?
        /// Builds in the fallback install dir, used when the default one isn't writable.
        public var fallbackBase: String?
        public var fallbackInstalled: [String]

        /// Nothing installed at all, in either place: the only case where connecting installs clothod.
        public var isFresh: Bool { installed.isEmpty && fallbackInstalled.isEmpty }

        /// `<os>-<arch>`, the key into the bundled builds.
        public var platform: String { "\(os)-\(arch)" }

        /// Parses the probe's `key=value` lines; nil without the `clothod-probe=1` marker.
        public init?(output: String) {
            var values: [String: String] = [:]
            for line in output.split(separator: "\n") {
                guard let equals = line.firstIndex(of: "=") else { continue }
                values[String(line[..<equals])] = String(line[line.index(after: equals)...])
            }
            guard values["clothod-probe"] == "1", let os = values["os"], let arch = values["arch"], let base = values["base"] else { return nil }
            self.os = os
            self.arch = arch
            self.base = base
            installed = (values["installed"] ?? "").split(separator: " ").map(String.init).filter { $0 != "current" }
            runtime = values["runtime"] ?? ""
            daemonRunning = values["daemon"] == "running"
            daemonExe = values["daemon_exe"].flatMap { $0.isEmpty ? nil : $0 }
            writable = values["writable"] == "yes"
            let nonEmpty = { (key: String) in values[key].flatMap { $0.isEmpty ? nil : $0 } }
            current = nonEmpty("current")
            daemonBuild = nonEmpty("daemon_build")
            holderBuild = nonEmpty("holder_build")
            fallbackBase = nonEmpty("fallback_base")
            fallbackInstalled = (values["fallback_installed"] ?? "").split(separator: " ").map(String.init)
        }
    }

    /// The builds a client carries: `dist/manifest.json` from clothod/scripts/dist.sh.
    public struct Manifest: Decodable, Sendable {
        public struct Build: Decodable, Sendable {
            public var target: String
            /// The install id, `<version>-<hash>`.
            public var id: String
            public var size: Int
            /// Relative to the manifest's directory.
            public var file: String
        }

        public var version: String
        public var builds: [String: Build]

        public static func load(from directory: URL) throws -> Manifest {
            try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        }
    }

    /// The install id in an installed executable's path (`<base>/<version>-<hash>/clothod`).
    public static func installID(ofExecutable path: String) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count >= 2, parts.last == "clothod" else { return nil }
        let id = String(parts[parts.count - 2])
        return id.contains("-") ? id : nil
    }

    /// Whether a running daemon is provably older than the bundled build with install id `bundled`, so
    /// switching to it is an upgrade: it predates the install scheme (no versioned path, or no `exe` at
    /// all), or its version is lower. Builds of the same version can't be ordered by their ids, so they
    /// never count, which keeps the app from ever offering a downgrade.
    public static func isOutdated(runningExecutable running: String?, bundledID bundled: String) -> Bool {
        guard let running else { return true }
        // Started through `<base>/current/clothod`: the newest installed build, by definition.
        if running.hasSuffix("/current/clothod") { return false }
        guard let runningID = installID(ofExecutable: running) else { return true }
        guard runningID != bundled else { return false }
        let version = { (id: String) in id.split(separator: "-").first.map(String.init) ?? id }
        return version(runningID).compare(version(bundled), options: .numeric) == .orderedAscending
    }

    /// The Mac dev build's private clothod on other machines (expanded by the remote shell), and the
    /// command that deletes it once its daemon is shut down.
    public static let devInstallDir = "$HOME/.local/share/clotho-dev/bin"
    public static let devRuntimeDir = "/tmp/clothod-dev-$(id -u)"
    public static let removeDevDirsCommand = "rm -rf \"$HOME/.local/share/clotho-dev\" \"/tmp/clothod-dev-$(id -u)\""

    /// Whether install id `id` has a lower version than `other` (`0.1.1-abc` < `0.1.2-def`). Releases bump
    /// the version, so this is what an update offer rests on; builds of one version never count.
    public static func isOlder(_ id: String, than other: String) -> Bool {
        let version = { (id: String) in id.split(separator: "-").first.map(String.init) ?? id }
        return version(id).compare(version(other), options: .numeric) == .orderedAscending
    }

    /// Quotes a value for a POSIX shell command line.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// `env VAR=value ...` for the test overrides, passed the same way to every step (empty when none).
    /// Values are left for the remote shell to expand, so they may use `$HOME` or `$(id -u)`.
    /// `ephemeral` ("exit", or idle seconds) makes a temporary instance end itself and remove its dir;
    /// clothod requires it for a non-default runtime dir.
    public static func envPrefix(installDir: String?, runtimeDir: String?, ephemeral: String? = nil) -> String {
        var parts: [String] = []
        if let installDir { parts.append("CLOTHOD_INSTALL_DIR=\(installDir)") }
        if let runtimeDir {
            parts.append("CLOTHOD_RUNTIME_DIR=\(runtimeDir)")
            // A private instance keeps its settings to itself: settings.set must never write the user's
            // config.toml, which their own daemon reads.
            parts.append("CLOTHOD_CONFIG=\(runtimeDir)/config.toml")
        }
        if let ephemeral { parts.append("CLOTHOD_EPHEMERAL=\(quote(ephemeral))") }
        return parts.isEmpty ? "" : "env " + parts.joined(separator: " ") + " "
    }

    /// The probe, with the script sent on stdin.
    public static func probeCommand(env: String) -> String { env + "sh -s" }

    /// The install step, with the binary sent on stdin. `base` is already quoted (or a shell expression).
    public static func installCommand(id: String, quotedBase: String, env: String) -> String {
        env + "sh -c " + quote(installScript) + " sh " + quote(id) + " " + quotedBase
    }

    public static func installedPath(base: String, id: String) -> String { "\(base)/\(id)/clothod" }

    public static func bridgeCommand(path: String, env: String) -> String { env + quote(path) + " bridge" }
    public static func stopCommand(path: String, env: String) -> String { env + quote(path) + " stop" }
    public static func shutdownCommand(path: String, env: String) -> String { env + quote(path) + " shutdown" }
}
