#if CLOTHO_TAILNET
import ClothoTailnet
import Darwin
import Foundation
import SwiftUI
import UIKit

// Clotho's own tailnet node on iOS, Phase 0 of PLAN.md's "Built-in Tailscale": only in CLOTHO_TAILNET=1 builds
// (ios/tailnet.yml), behind the debug Tailnet Test screen. It runs the node (ClothoTailnet's TailnetNode) with its
// state in the Keychain, signs it in, lists peers, dials them, can route SSH through the node, and on every
// foreground checks the node's health and recreates it when it's dead (tailscale#21353: a suspended app's node
// stops receiving), recording how long until a dial works.
//
// Settings are UserDefaults, so launch arguments set them (`-TailnetControlURL http://127.0.0.1:1234`):
//   TailnetControlURL     the control server; empty is Tailscale's. A loopback one (clothod's testctl) is test
//                         mode: no port mapper or netns binding, for the rest of the process.
//   TailnetDir            the node's dir (default Application Support/Clotho/tailnet-dev, or .../tailnet-dev/test
//                         in test mode). The state isn't there: it's in the Keychain (TailnetKeychainStore).
//   TailnetHostname       default clotho-<device model>-dev
//   TailnetAutoStart      YES: start at launch (cold-launch measurements)
//   TailnetProbe          host:port the foreground check dials
//   TailnetForceRecreate  YES: treat the node as dead on the next foreground (every foreground, as a launch
//                         argument)
//   TailnetVerbose        YES: the node's own log lines go to the app log
//   TailnetTest           YES: open the Tailnet Test screen at launch (UI tests, quick device runs)

/// What one node runs with.
struct TailnetSettings: Sendable {
    var controlURL: URL?
    var dir: URL
    var hostname: String
    /// Port mapper and netns binding off; the shim refuses it unless the control URL is loopback.
    var testMode: Bool
    var verbose = false

    static func isLoopback(_ url: URL?) -> Bool { ["127.0.0.1", "localhost", "::1"].contains(url?.host ?? "") }

    @MainActor static func fromDefaults(_ defaults: UserDefaults = .standard) -> TailnetSettings {
        let control = defaults.string(forKey: "TailnetControlURL").flatMap { $0.isEmpty ? nil : URL(string: $0) }
        let test = isLoopback(control)
        var dir = TailnetKeychainStore.debugNodeDir
        #if !DEBUG
        dir = dir.deletingLastPathComponent().appendingPathComponent("tailnet", isDirectory: true)
        #endif
        if test { dir.appendPathComponent("test", isDirectory: true) }
        if let custom = defaults.string(forKey: "TailnetDir"), !custom.isEmpty { dir = URL(fileURLWithPath: custom, isDirectory: true) }
        var dev = false
        #if DEBUG
        dev = true
        #endif
        let hostname = defaults.string(forKey: "TailnetHostname").flatMap { $0.isEmpty ? nil : $0 }
            ?? TailnetNode.defaultHostname(device: UIDevice.current.model, dev: dev)
        return TailnetSettings(controlURL: control, dir: dir, hostname: hostname, testMode: test,
                               verbose: defaults.bool(forKey: "TailnetVerbose"))
    }
}

struct TailnetPeerRow: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var ip: String
    var online: Bool
    var os: String
}

/// One foreground: how long the node took to be usable again.
struct ForegroundTiming: Codable, Identifiable, Equatable, Sendable {
    var at: Date
    /// How long the app was in the background (nil: unknown, e.g. a direct call).
    var backgroundSeconds: Double?
    /// The node was Running and answered a status call within 2 s (false when forced dead).
    var healthy: Bool
    var forced: Bool
    var recreated: Bool
    /// The replaced node had finished shutting down when the new one was running (nil: nothing replaced).
    var oldClosed: Bool?
    /// Seconds from foreground to Running (0 when it never stopped running).
    var runningAfter: Double?
    /// Seconds from foreground to a working dial of the probe target.
    var dialAfter: Double?
    var error: String?
    /// Not checked: the node's state then. It wasn't Running when the app went to the background (it was signing
    /// in, say), so recreating it would only cancel that. Optional so timings saved before it still decode.
    var skipped: String?

    var id: Date { at }

    var summary: String {
        if let skipped { return "not checked (\(skipped))" }
        var parts = [healthy ? "healthy" : (forced ? "forced dead" : "dead")]
        if recreated { parts.append("recreated" + (oldClosed == true ? " (old closed)" : "")) }
        if let runningAfter, recreated { parts.append(String(format: "running in %.2f s", runningAfter)) }
        if let dialAfter { parts.append(String(format: "dial in %.2f s", dialAfter)) }
        if let error { parts.append(error) }
        return parts.joined(separator: ", ")
    }
}

/// The node, for the SSH dialer's threads: the current one, whichever recreate made it.
private final class CurrentNode: @unchecked Sendable {
    private let lock = NSLock()
    private var node: TailnetNode?
    var value: TailnetNode? {
        get { lock.withLock { node } }
        set { lock.withLock { node = newValue } }
    }
}

@MainActor
final class TailnetController: ObservableObject {
    static let shared = TailnetController(settings: .fromDefaults(), service: nil)

    /// The Tailnet Test screen opens at launch (-TailnetTest YES).
    static var opensAtLaunch: Bool { UserDefaults.standard.bool(forKey: "TailnetTest") }

    @Published private(set) var stateText = "Stopped"
    @Published private(set) var isRunning = false
    @Published private(set) var needsLogin = false
    @Published private(set) var loginURL: URL?
    /// Every state the current node went through (NeedsLogin without its URL).
    @Published private(set) var stateHistory: [String] = []
    @Published private(set) var selfName: String?
    @Published private(set) var selfIPs: [String] = []
    @Published private(set) var selfStableID: String?
    @Published private(set) var peers: [TailnetPeerRow] = []
    @Published var lastError: String?
    @Published private(set) var startToRunning: TimeInterval?
    @Published private(set) var startStuck = false
    @Published private(set) var hasNode = false
    @Published private(set) var timings: [ForegroundTiming] = []
    @Published private(set) var signingIn = false
    @Published var routeSSH = false {
        didSet { applyRoute() }
    }
    @Published var forceUnhealthyOnForeground: Bool {
        didSet { UserDefaults.standard.set(forceUnhealthyOnForeground, forKey: "TailnetForceRecreate") }
    }
    @Published var probeTarget: String {
        didSet { UserDefaults.standard.set(probeTarget, forKey: "TailnetProbe") }
    }

    var settings: TailnetSettings
    /// The Keychain service, fixed for tests; otherwise from the settings at each start.
    private let fixedService: TailnetKeychainStore.Service?
    var service: TailnetKeychainStore.Service { fixedService ?? (settings.testMode ? .test : .forBuild) }

    private(set) var node: TailnetNode?
    private var lease: TailnetKeychainStore.Lease?
    /// Stopped nodes whose shutdown hasn't finished (tsnet's Close can hang: tailscale#21353).
    private(set) var retired: [TailnetNode] = []
    var retiredCount: Int { retired.count }
    private let current = CurrentNode()
    private var generation = 0
    private var startedAt: Date?
    private var backgroundedAt: Date?
    /// The node was Running when the app went to the background.
    private var backgroundedRunning = false
    /// Counts sign-ins, so only the latest one clears `signingIn`.
    private var signInGeneration = 0
    /// Test mode was on for a node in this process: its switches stay on until a relaunch.
    private(set) var testModeUsed = false
    private let signIn = TailnetSignIn()
    private let forceIsLaunchArgument = ProcessInfo.processInfo.arguments.contains("-TailnetForceRecreate")

    init(settings: TailnetSettings, service: TailnetKeychainStore.Service?) {
        self.settings = settings
        fixedService = service
        forceUnhealthyOnForeground = UserDefaults.standard.bool(forKey: "TailnetForceRecreate")
        probeTarget = UserDefaults.standard.string(forKey: "TailnetProbe") ?? ""
        if service == nil, let data = UserDefaults.standard.data(forKey: "TailnetTimings"),
           let saved = try? JSONDecoder().decode([ForegroundTiming].self, from: data) {
            timings = saved
        }
    }

    // MARK: Start and stop

    /// Starts a new node on the Keychain store. Returns at once: the shim's start runs on a background queue,
    /// never the main thread, because a failed ctn_start can run tsnet's Close on its caller's thread, which can
    /// hang (tailscale#21353), and srv.Start reads the Keychain there.
    func start() {
        guard node == nil else { return }
        lastError = nil
        startStuck = false
        startToRunning = nil
        stateHistory = []
        generation += 1
        let gen = generation
        let settings = settings
        if settings.testMode { testModeUsed = true }
        // The node before this one may still be shutting down: from now on it can read, never write.
        lease?.revoke()
        let newLease = TailnetKeychainStore(service: service).lease()
        Self.prepare(dir: settings.dir)
        var nodeLog: (@Sendable (String) -> Void)?
        if settings.verbose { nodeLog = { line in log("tailnet node: \(line)") } }
        // Not ephemeral, even in debug builds: a clean shutdown of an ephemeral node logs it out, so a recreate
        // would need a new sign-in.
        let node = TailnetNode(configuration: .init(
            dir: settings.dir, hostname: settings.hostname, controlURL: settings.controlURL, ephemeral: false,
            testMode: settings.testMode, store: newLease, log: nodeLog))
        node.onStateChange = { [weak self] state in
            Task { @MainActor in self?.stateChanged(state, generation: gen) }
        }
        self.node = node
        lease = newLease
        current.value = node
        hasNode = true
        stateText = "Starting"
        let t0 = Date()
        startedAt = t0
        log("tailnet: starting \(settings.hostname) in \(settings.dir.path), control \(settings.controlURL?.absoluteString ?? "Tailscale")"
            + "\(settings.testMode ? " (test mode)" : ""), state in Keychain service \(service.rawValue)")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try node.start() }
            Task { @MainActor [weak self] in self?.startReturned(result, generation: gen, after: Date().timeIntervalSince(t0)) }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, self.generation == gen, !self.startReturnedFor.contains(gen) else { return }
            self.startStuck = true
            self.lastError = "Start is stuck (tailscale#21353): Stop or Recreate"
            log("tailnet: start hasn't returned after 15 s")
        }
    }

    private var startReturnedFor: Set<Int> = []

    private func startReturned(_ result: Result<Void, Error>, generation gen: Int, after seconds: TimeInterval) {
        startReturnedFor.insert(gen)
        guard gen == generation else { return }
        startStuck = false
        if case .failure(let error) = result {
            lastError = error.localizedDescription
            log("tailnet: can't start (\(Int(seconds * 1000)) ms): \(error.localizedDescription)")
            current.value = nil
            node = nil
            hasNode = false
            stateText = "Stopped"
            isRunning = false
            applyRoute()
        }
    }

    /// Stops the node and returns at once; it shuts down in the background.
    func stop() {
        guard let node else { return }
        generation += 1
        signInGeneration += 1
        signIn.cancel()
        signingIn = false
        node.stop()
        self.node = nil
        current.value = nil
        retired.append(node)
        purgeRetired()
        hasNode = false
        isRunning = false
        needsLogin = false
        loginURL = nil
        stateText = "Stopped"
        peers = []
        selfName = nil
        selfIPs = []
        log("tailnet: stopped")
    }

    /// Drops retired nodes that have finished closing. Never waits.
    private func purgeRetired() {
        retired.removeAll { $0.waitForClose(timeout: 0) }
    }

    /// Stops the node without waiting for it and starts a new one on the same Keychain store and dir: the
    /// state, so no new sign-in. Returns the old node.
    @discardableResult
    func recreate() -> TailnetNode? {
        guard let old = node else { return nil }
        log("tailnet: recreating the node")
        stop()
        start()
        return old
    }

    /// Waits (off the main thread) until every node this controller stopped has shut down; tests only.
    func waitForClose(timeout: TimeInterval) async -> Bool {
        let nodes = retired + (node.map { [$0] } ?? [])
        let closed = await Task.detached { nodes.allSatisfy { $0.waitForClose(timeout: timeout) } }.value
        purgeRetired()
        return closed
    }

    private static func prepare(dir: URL) {
        var url = dir
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: State

    private func stateChanged(_ state: TailnetNode.State, generation gen: Int) {
        guard gen == generation, node != nil else { return }
        let name: String
        switch state {
        case .stopped: name = "Stopped"; stateText = "Stopped"
        case .starting: name = "Starting"; stateText = "Starting"
        case .needsLogin(let url): name = "NeedsLogin"; stateText = "Needs sign-in"; loginURL = url
        case .needsMachineAuth: name = "NeedsMachineAuth"; stateText = "Needs approval in the tailnet's admin console"
        case .running: name = "Running"; stateText = "Running"
        case .expired: name = "Expired"; stateText = "Key expired: sign in again"
        }
        if stateHistory.last != name { stateHistory.append(name) }
        isRunning = state == .running
        needsLogin = name == "NeedsLogin" || name == "Expired"
        if !needsLogin { loginURL = nil }
        log("tailnet: state \(name)")
        if state == .running {
            signInGeneration += 1
            signIn.finished()
            signingIn = false
            if startToRunning == nil, let startedAt {
                startToRunning = Date().timeIntervalSince(startedAt)
                log("tailnet: Running after \(Int(startToRunning! * 1000)) ms")
            }
            Task { await refresh() }
        }
    }

    /// The node's own name and addresses, and its peers.
    func refresh() async {
        guard let node, node.state == .running else { return }
        do {
            let status = try await node.status(timeout: 5)
            guard self.node === node else { return }
            selfName = status.selfNode.map { $0.dnsName.isEmpty ? $0.hostName : $0.dnsName }
            selfIPs = status.selfNode?.tailscaleIPs ?? []
            selfStableID = status.selfNode?.id
            peers = status.peers.map {
                TailnetPeerRow(id: $0.id, name: $0.hostName, ip: $0.primaryIP ?? "", online: $0.online, os: $0.os)
            }
        } catch {
            lastError = "status: \(error.localizedDescription)"
        }
    }

    /// Waits until the node runs, up to `timeout`.
    func waitUntilRunning(timeout: TimeInterval) async -> Bool {
        guard let node else { return false }
        return await node.waitForState(timeout: timeout) { $0 == .running } == .running
    }

    /// Waits until the node needs a login with a URL, up to `timeout`; the URL.
    func waitForLoginURL(timeout: TimeInterval) async -> URL? {
        guard let node else { return nil }
        let state = await node.waitForState(timeout: timeout) { if case .needsLogin(_?) = $0 { return true } else { return false } }
        if case .needsLogin(let url?) = state { return url }
        return nil
    }

    // MARK: Sign-in

    /// Opens the node's login URL in a web sheet; the sheet closes itself once the node runs.
    func startSignIn() {
        guard let node else { return }
        lastError = nil
        signInGeneration += 1
        let gen = signInGeneration
        Task {
            do {
                var url: URL?
                if case .needsLogin(let known?) = node.state { url = known } else { url = try await node.login() }
                // Stopped, Running or another sign-in while the login URL was on its way.
                guard let url, gen == signInGeneration, self.node === node, node.state != .running else { return }
                signingIn = true
                let outcome = await signIn.present(url)
                guard gen == signInGeneration else { return }
                signingIn = false
                if outcome == .cancelledByUser { lastError = "Sign-in cancelled" }
            } catch {
                guard gen == signInGeneration else { return }
                signingIn = false
                lastError = error.localizedDescription
            }
        }
    }

    func signOut() {
        guard let node else { return }
        Task {
            do { try await node.logout() } catch { lastError = error.localizedDescription }
        }
    }

    // MARK: Dialing

    /// Dials host:port over the node and returns the first line the peer sends (an SSH banner, say), or why
    /// it failed.
    func dial(host: String, port: Int) async -> String {
        guard let node else { return "Failed: the node isn't running" }
        let t0 = Date()
        do {
            let fd = try await node.dial(host: host, port: port, timeout: 10)
            let connected = Date().timeIntervalSince(t0)
            let first = await Task.detached { Self.readFirstLine(fd) }.value
            let text = "\(first ?? "Connected, nothing received in 5 s") (\(Int(connected * 1000)) ms)"
            log("tailnet: dial \(host):\(port): \(text)")
            return text
        } catch {
            log("tailnet: dial \(host):\(port) failed: \(error.localizedDescription)")
            return "Failed: \(error.localizedDescription)"
        }
    }

    /// Up to 256 bytes within 5 s, the first line of them; closes the descriptor.
    nonisolated private static func readFirstLine(_ fd: Int32) -> String? {
        defer { close(fd) }
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, 5000) > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 256)
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else { return nil }
        return String(decoding: buffer.prefix(n), as: UTF8.self).components(separatedBy: .newlines).first
    }

    /// The SSH key exchange with host:port over the node (SSHSession's dial mode): the host key's fingerprint.
    func sshHandshake(host: String, port: Int) async throws -> String {
        let dialer = nodeDialer
        let key = try await Task.detached {
            try SSHSession.presentedHostKey(host: host, port: port, dialer: dialer)
        }.value
        return HostKeys.fingerprint(key) ?? key
    }

    /// Dials through whichever node is current when SSH connects (a recreate swaps it), on SSH's own thread.
    private var nodeDialer: SSHSession.SocketDialer {
        let ref = current
        return { host, port, timeout in
            guard let node = ref.value else { throw TailnetError.stopped }
            return try node.dialSync(host: host, port: port, timeout: timeout)
        }
    }

    private func applyRoute() {
        SSHSession.socketDialer = routeSSH ? nodeDialer : nil
        log("tailnet: route SSH through the node: \(routeSSH)")
    }

    // MARK: Foreground

    func sceneChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            // The node stays: iOS suspends it with the app, and the foreground check finds out what's left.
            if let node {
                backgroundedAt = Date()
                backgroundedRunning = node.state == .running
            }
        case .active:
            guard backgroundedAt != nil else { return }
            Task { await didBecomeActive() }
        default: break
        }
    }

    private var probe: (host: String, port: Int)? {
        let text = probeTarget.trimmingCharacters(in: .whitespaces)
        guard let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]),
              (1...65535).contains(port), colon > text.startIndex else { return nil }
        return (String(text[..<colon]), port)
    }

    /// The foreground check: is the node healthy (Running, and a status call answers in 2 s), and does the probe
    /// target dial in 3 s? If not, recreate it on the same store (no new sign-in) without waiting for the old one,
    /// and time until it runs and the probe dials. Nothing here blocks the main thread.
    ///
    /// Only a node that was Running when the app went to the background (or is now) is checked, forced or not. One
    /// that was signing in or waiting for approval (NeedsLogin, NeedsMachineAuth, Starting) is left alone: the user
    /// may have gone to another app to finish the login, and a recreate would close the sign-in sheet and ask for
    /// a new login. That foreground is recorded as not checked.
    @discardableResult
    func didBecomeActive() async -> ForegroundTiming? {
        let wasRunning = backgroundedRunning
        backgroundedRunning = false
        guard let node else { backgroundedAt = nil; return nil }
        let t0 = Date()
        let background = backgroundedAt.map { t0.timeIntervalSince($0) }
        backgroundedAt = nil
        guard wasRunning || node.state == .running else {
            var timing = ForegroundTiming(at: t0, backgroundSeconds: background, healthy: false, forced: false, recreated: false)
            timing.skipped = stateText
            record(timing, background: background)
            return timing
        }
        let forced = forceUnhealthyOnForeground
        if forced && !forceIsLaunchArgument { forceUnhealthyOnForeground = false }
        var healthy = false
        if !forced, node.state == .running, let status = try? await node.status(timeout: 2), status.backendState == "Running" {
            healthy = true
        }
        var timing = ForegroundTiming(at: t0, backgroundSeconds: background, healthy: healthy, forced: forced, recreated: false)
        let probe = probe
        var probeWorked = probe == nil
        if healthy {
            timing.runningAfter = 0
            if let probe {
                do {
                    let fd = try await node.dial(host: probe.host, port: probe.port, timeout: 3)
                    close(fd)
                    timing.dialAfter = Date().timeIntervalSince(t0)
                    probeWorked = true
                } catch {
                    timing.error = "probe: \(error.localizedDescription)"
                }
            }
        }
        if !healthy || !probeWorked {
            let old = recreate()
            timing.recreated = true
            timing.error = nil
            if await waitUntilRunning(timeout: 20), let new = self.node {
                timing.runningAfter = Date().timeIntervalSince(t0)
                if let probe {
                    do {
                        let fd = try await new.dial(host: probe.host, port: probe.port, timeout: 10)
                        close(fd)
                        timing.dialAfter = Date().timeIntervalSince(t0)
                    } catch {
                        timing.error = "probe after recreate: \(error.localizedDescription)"
                    }
                }
            } else {
                timing.error = "not running 20 s after recreating (\(stateText))"
            }
            timing.oldClosed = old?.waitForClose(timeout: 0)
            purgeRetired()
        }
        record(timing, background: background)
        return timing
    }

    private func record(_ timing: ForegroundTiming, background: Double?) {
        let backgroundText = background.map { String(format: "+%.0fs", $0) } ?? "+?"
        log("tailnet: foreground \(backgroundText): \(timing.summary)")
        timings.insert(timing, at: 0)
        if timings.count > 20 { timings.removeLast(timings.count - 20) }
        if fixedService == nil, let data = try? JSONEncoder().encode(timings) {
            UserDefaults.standard.set(data, forKey: "TailnetTimings")
        }
    }

    func clearTimings() {
        timings = []
        UserDefaults.standard.removeObject(forKey: "TailnetTimings")
    }

    // MARK: Launch

    /// From ClothoApp.init: starts the node when TailnetAutoStart is set, and logs launch → Running and launch →
    /// the first probe dial (cold-launch measurements).
    static func launched() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "TailnetAutoStart") else { return }
        let controller = shared
        let launchedAt = processStart
        controller.start()
        Task { @MainActor in
            guard await controller.waitUntilRunning(timeout: 60) else {
                log("tailnet: autostart: not running 60 s after launch")
                return
            }
            let running = Date().timeIntervalSince(launchedAt)
            var line = String(format: "tailnet: autostart: launch to Running %.2f s (start to Running %.2f s)", running,
                              controller.startToRunning ?? -1)
            if let probe = controller.probe, let node = controller.node {
                if let fd = try? await node.dial(host: probe.host, port: probe.port, timeout: 15) {
                    close(fd)
                    line += String(format: ", launch to first dial %.2f s", Date().timeIntervalSince(launchedAt))
                } else {
                    line += ", the first dial failed"
                }
            }
            line += String(format: ", footprint %.1f MB", footprintMB)
            controller.launchLine = line
            log(line)
        }
    }

    /// The autostart's measurements, shown on the screen.
    @Published private(set) var launchLine: String?

    /// When this process started (the kernel's record), for launch timings.
    static var processStart: Date {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let tv = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
    }

    /// The process's memory footprint in MB (what iOS's memory limits count: task_vm_info.phys_footprint).
    nonisolated static var footprintMB: Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }
}
#endif
