import ClothoKit
import Darwin
import Foundation
import SwiftTerm

/// A stand-in for clothod that runs real local shells and keeps the model in memory, so the native UI
/// can be built and tested before the daemon exists. It follows the protocol's semantics where that's
/// cheap: integer IDs and `rev`, seq-numbered output, the subscribe reply and its three modes,
/// `pane.resized` in stream order, terminal replies answered here rather than by the client, and panes
/// removed from the layout when their process exits.
///
/// Differences from clothod: shells die with the app, and a "snapshot" is a reset followed by the
/// retained output (exact while the pane has produced less than `retainedBytes`).
public final class FakeBackend: SessionBackend, @unchecked Sendable {
    public static let retainedBytes = 4 << 20
    static let replayLimit = 1 << 20

    public let events: AsyncStream<SessionEvent>
    private let continuation: AsyncStream<SessionEvent>.Continuation

    // Everything below is guarded by `lock`. Events are yielded while holding it, so they come out in
    // the order the changes happened.
    private let lock = NSLock()
    private var state = ModelState()
    private var nextID: UInt64 = 1
    private var panes: [PaneID: FakePane] = [:]
    private var cwdTimer: DispatchSourceTimer?

    public init() {
        (events, continuation) = AsyncStream.makeStream(of: SessionEvent.self)
    }

    deinit {
        stop()
    }

    // MARK: Lifecycle

    public func start() async throws {
        var hello = Hello(protocol: 1, protocolMin: 1, protocolMax: 1, daemon: "clotho-fake", version: "0.1.0",
                          instance: String(UInt64.random(in: 0...UInt64.max), radix: 16),
                          pid: getpid(), machine: Hello.Machine(hostname: Self.hostname, os: "macos", arch: "aarch64"))
        hello.featureNames = ["pane.keys", "agents"]
        locked {
            continuation.yield(.connected(hello))
            continuation.yield(.state(state))
        }
        // clothod falls back to the process's cwd when the shell doesn't send OSC 7, which zsh doesn't by default.
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1.5)
        timer.setEventHandler { [weak self] in self?.refreshCwds() }
        timer.resume()
        locked { cwdTimer = timer }
    }

    public func stop() {
        let all: [FakePane] = locked {
            cwdTimer?.cancel()
            cwdTimer = nil
            defer { panes.removeAll() }
            return Array(panes.values)
        }
        all.forEach { $0.hangUp() }
    }

    public func getState() async throws -> ModelState {
        locked { state }
    }

    /// gethostname(), which, unlike ProcessInfo.hostName, never waits on a DNS lookup.
    static var hostname: String {
        var buffer = [CChar](repeating: 0, count: 256)
        return gethostname(&buffer, buffer.count) == 0 ? String(cString: buffer) : "localhost"
    }

    // MARK: Workspaces and tabs

    public func createWorkspace(name: String?, spawn: SpawnOptions) async throws -> CreatedWorkspace {
        try locked {
            let workspaceID = makeID()
            let tabID = makeID()
            let pane = try spawnPane(spawn)
            let tab = ClothoKit.Tab(id: tabID, activePane: pane, layout: .pane(pane))
            state.workspaces.append(ClothoKit.Workspace(id: workspaceID, name: name ?? "Session \(state.workspaces.count + 1)", tabs: [tab]))
            state.focus = ClothoKit.Focus(workspace: workspaceID, tab: tabID, pane: pane)
            publishState()
            return CreatedWorkspace(workspace: workspaceID, tab: tabID, pane: pane)
        }
    }

    public func renameWorkspace(_ workspace: WorkspaceID, name: String) async throws {
        try locked {
            let w = try workspaceIndex(workspace)
            state.workspaces[w].name = name
            publishState()
        }
    }

    public func closeWorkspace(_ workspace: WorkspaceID) async throws {
        let closed: [FakePane] = try locked {
            let w = try workspaceIndex(workspace)
            let ids = state.workspaces[w].tabs.flatMap(\.layout.panes)
            state.workspaces.remove(at: w)
            let closed = detach(ids)
            repairFocus()
            publishState()
            return closed
        }
        closed.forEach { $0.hangUp() }
    }

    public func createTab(in workspace: WorkspaceID, spawn: SpawnOptions) async throws -> CreatedTab {
        try locked {
            let w = try workspaceIndex(workspace)
            let tabID = makeID()
            let pane = try spawnPane(spawn)
            state.workspaces[w].tabs.append(ClothoKit.Tab(id: tabID, activePane: pane, layout: .pane(pane)))
            state.focus = ClothoKit.Focus(workspace: workspace, tab: tabID, pane: pane)
            publishState()
            return CreatedTab(tab: tabID, pane: pane)
        }
    }

    public func renameTab(_ tab: TabID, title: String?) async throws {
        try locked {
            let (w, t) = try tabIndex(tab)
            state.workspaces[w].tabs[t].title = title
            publishState()
        }
    }

    public func closeTab(_ tab: TabID) async throws {
        let closed: [FakePane] = try locked {
            let (w, t) = try tabIndex(tab)
            let ids = state.workspaces[w].tabs[t].layout.panes
            state.workspaces[w].tabs.remove(at: t)
            let closed = detach(ids)
            repairFocus()
            publishState()
            return closed
        }
        closed.forEach { $0.hangUp() }
    }

    // MARK: Panes and splits

    public func split(_ pane: PaneID, direction: Direction, ratio: Double?, spawn: SpawnOptions) async throws -> CreatedSplit {
        try locked {
            guard let (w, t) = indexOfTab(containing: pane) else { throw notFound("pane \(pane)") }
            var options = spawn
            if options.cwd == nil { options.cwd = state.pane(pane)?.cwd }
            let newPane = try spawnPane(options)
            let splitID = makeID()
            let r = min(max(ratio ?? 0.5, Layout.ratioRange.lowerBound), Layout.ratioRange.upperBound)
            let tab = state.workspaces[w].tabs[t]
            state.workspaces[w].tabs[t].layout = tab.layout.replacing(pane) { old in
                direction.newPaneIsSecond
                    ? .split(id: splitID, axis: direction.axis, ratio: r, a: old, b: .pane(newPane))
                    : .split(id: splitID, axis: direction.axis, ratio: 1 - r, a: .pane(newPane), b: old)
            }
            state.workspaces[w].tabs[t].activePane = newPane
            state.focus = ClothoKit.Focus(workspace: state.workspaces[w].id, tab: tab.id, pane: newPane)
            publishState()
            return CreatedSplit(pane: newPane, split: splitID)
        }
    }

    public func closePane(_ pane: PaneID) async throws {
        let closed: [FakePane] = try locked {
            guard state.pane(pane) != nil else { throw notFound("pane \(pane)") }
            let closed = detach([pane])
            removeFromLayout(pane)
            publishState()
            return closed
        }
        closed.forEach { $0.hangUp() }
    }

    public func setRatio(_ split: SplitID, ratio: Double) async throws {
        try locked {
            let r = min(max(ratio, Layout.ratioRange.lowerBound), Layout.ratioRange.upperBound)
            for w in state.workspaces.indices {
                for t in state.workspaces[w].tabs.indices {
                    if let layout = state.workspaces[w].tabs[t].layout.settingRatio(of: split, to: r) {
                        state.workspaces[w].tabs[t].layout = layout
                        publishState()
                        return
                    }
                }
            }
            throw notFound("split \(split)")
        }
    }

    public func focus(_ target: FocusTarget) async throws {
        try locked {
            switch target {
            case .pane(let pane):
                guard let (w, t) = indexOfTab(containing: pane) else { throw notFound("pane \(pane)") }
                state.workspaces[w].tabs[t].activePane = pane
                state.focus = ClothoKit.Focus(workspace: state.workspaces[w].id, tab: state.workspaces[w].tabs[t].id, pane: pane)
            case .tab(let tab):
                let (w, t) = try tabIndex(tab)
                let found = state.workspaces[w].tabs[t]
                state.focus = ClothoKit.Focus(workspace: state.workspaces[w].id, tab: tab, pane: found.activePane)
            case .workspace(let workspace):
                let w = try workspaceIndex(workspace)
                // Back to the workspace's last-focused tab.
                let tabs = state.workspaces[w].tabs
                let tab = tabs.first { $0.id == state.workspaces[w].activeTab } ?? tabs.first
                state.focus = ClothoKit.Focus(workspace: workspace, tab: tab?.id, pane: tab?.activePane)
            }
            publishState()
        }
    }

    // MARK: Pane data

    public func subscribe(_ pane: PaneID, haveSeq: UInt64?, scrollback: Int?, viewport: Size?) async throws -> Subscription {
        // The subscriber's own viewport is applied before the reply, which already carries the new size,
        // so this subscriber gets no `resized` for it.
        if let viewport { try await applySize(pane, viewport, notifySubscriber: false) }
        return try locked {
            guard let fake = panes[pane], let model = state.pane(pane) else { throw notFound("pane \(pane)") }
            fake.subscribed = true
            let seq = fake.seq
            let bufferStart = seq - UInt64(fake.buffer.count)
            let mode: Subscription.Mode
            if haveSeq == seq {
                mode = .live
            } else if let have = haveSeq, have < seq, have >= bufferStart, seq - have <= UInt64(Self.replayLimit) {
                mode = .replay
            } else {
                mode = .snapshot
            }
            let subscription = Subscription(mode: mode, seq: mode == .replay ? haveSeq! : seq, cols: model.cols, rows: model.rows)
            continuation.yield(.subscribed(pane, subscription))
            switch mode {
            case .live:
                break
            case .replay:
                let from = Int(haveSeq! - bufferStart)
                continuation.yield(.output(pane, seq: haveSeq!, bytes: fake.buffer.subdata(in: fake.buffer.startIndex + from ..< fake.buffer.endIndex)))
            case .snapshot:
                // Full reset, then everything retained.
                var bytes = Data([0x1b, 0x63])
                bytes.append(fake.buffer)
                continuation.yield(.snapshot(pane, seq: seq, cols: model.cols, rows: model.rows, bytes: bytes))
            }
            return subscription
        }
    }

    public func unsubscribe(_ pane: PaneID) async throws {
        locked { panes[pane]?.subscribed = false }
    }

    /// With a single client, its viewport is always the most recent one, so it becomes the PTY size.
    public func setViewport(_ pane: PaneID, _ size: Size) async throws {
        try await resize(pane, size)
    }

    public func resize(_ pane: PaneID, _ size: Size) async throws {
        try await applySize(pane, size, notifySubscriber: true)
    }

    private func applySize(_ pane: PaneID, _ size: Size, notifySubscriber: Bool) async throws {
        let cols = max(2, size.cols), rows = max(1, size.rows)
        let fake: FakePane? = try locked {
            guard let p = state.panes.firstIndex(where: { $0.id == pane }), let fake = panes[pane] else { throw notFound("pane \(pane)") }
            guard state.panes[p].cols != cols || state.panes[p].rows != rows else { return nil }
            state.panes[p].cols = cols
            state.panes[p].rows = rows
            if fake.subscribed && notifySubscriber { continuation.yield(.resized(pane, cols: cols, rows: rows, seq: fake.seq)) }
            publishPane(at: p)
            return fake
        }
        // Outside the lock: the pane's queue may be inside a feed, waiting to report to us.
        fake?.resize(cols: cols, rows: rows)
    }

    public func ackAgent(_ pane: PaneID) async throws {
        locked {
            guard let p = state.panes.firstIndex(where: { $0.id == pane }), state.panes[p].agent?.attention == true else { return }
            state.panes[p].agent?.attention = false
            continuation.yield(.agent(pane, state.panes[p].agent))
            publishPane(at: p)
        }
    }

    /// Puts a fake agent in a pane (nil removes it), for building the UI without clothod. A waiting,
    /// done or error state starts out needing attention, as clothod's do.
    public func setAgent(_ pane: PaneID, _ agent: AgentInfo?) {
        locked {
            guard let p = state.panes.firstIndex(where: { $0.id == pane }) else { return }
            var agent = agent
            if let state = agent?.state, [.waiting, .done, .error].contains(state), agent?.attention == nil { agent?.attention = true }
            if agent?.since == nil { agent?.since = Date().timeIntervalSince1970 }
            state.panes[p].agent = agent
            continuation.yield(.agent(pane, agent))
            publishPane(at: p)
        }
    }

    /// `pane.keys`, simply: text as is, then each key as the bytes a terminal sends in normal modes.
    public func sendKeys(_ pane: PaneID, text: String?, keys: [String]) async throws {
        var bytes = Data((text ?? "").utf8)
        for key in keys {
            switch key {
            case "enter": bytes.append(0x0d)
            case "escape", "esc": bytes.append(0x1b)
            case "tab": bytes.append(0x09)
            case "backspace": bytes.append(0x7f)
            case let single where single.count == 1: bytes.append(contentsOf: single.utf8)
            default: throw BackendError(code: "bad_request", message: "unknown key \(key)")
            }
        }
        sendInput(pane, bytes)
        try await ackAgent(pane)
    }

    public func sendInput(_ pane: PaneID, _ bytes: Data) {
        let fake = locked { panes[pane] }
        fake?.send(bytes)
    }

    // MARK: Called by panes, on their own queues

    fileprivate func paneOutput(_ fake: FakePane, _ bytes: Data) {
        locked {
            guard panes[fake.id] === fake else { return }
            let seq = fake.seq
            fake.seq += UInt64(bytes.count)
            fake.buffer.append(bytes)
            if fake.buffer.count > Self.retainedBytes {
                fake.buffer = fake.buffer.suffix(Self.retainedBytes * 3 / 4)
            }
            if fake.subscribed { continuation.yield(.output(fake.id, seq: seq, bytes: bytes)) }
            if let p = state.panes.firstIndex(where: { $0.id == fake.id }) { state.panes[p].seq = fake.seq }
        }
    }

    fileprivate func paneChanged(_ fake: FakePane, title: String?, cwd: String?, bell: Bool) {
        locked {
            guard panes[fake.id] === fake, let p = state.panes.firstIndex(where: { $0.id == fake.id }) else { return }
            var changed = false
            if let title, state.panes[p].title != title {
                state.panes[p].title = title
                changed = true
            }
            if let cwd, state.panes[p].cwd != cwd {
                state.panes[p].cwd = cwd
                changed = true
            }
            if changed { publishPane(at: p) }
            if bell { continuation.yield(.bell(fake.id)) }
        }
    }

    fileprivate func paneExited(_ fake: FakePane, code: Int32?) {
        locked {
            guard panes[fake.id] === fake, let p = state.panes.firstIndex(where: { $0.id == fake.id }) else { return }
            state.panes[p].exited = PaneExit(code: code)
            publishPane(at: p)
            panes[fake.id] = nil
            removeFromLayout(fake.id)
            publishState()
        }
    }

    private func refreshCwds() {
        let all = locked { Array(panes.values) }
        for fake in all {
            if let cwd = fake.processCwd() { paneChanged(fake, title: nil, cwd: cwd, bell: false) }
        }
    }

    // MARK: Helpers (call with the lock held)

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func makeID() -> UInt64 {
        defer { nextID += 1 }
        return nextID
    }

    private func publishState() {
        if let w = state.workspaces.firstIndex(where: { $0.id == state.focus.workspace }) {
            state.workspaces[w].activeTab = state.focus.tab
        }
        for w in state.workspaces.indices where !state.workspaces[w].tabs.contains(where: { $0.id == state.workspaces[w].activeTab }) {
            state.workspaces[w].activeTab = state.workspaces[w].tabs.first?.id
        }
        state.rev += 1
        continuation.yield(.state(state))
    }

    private func publishPane(at index: Int) {
        state.rev += 1
        continuation.yield(.pane(state.panes[index], rev: state.rev))
    }

    private func spawnPane(_ options: SpawnOptions) throws -> PaneID {
        let id = makeID()
        let cols = options.cols ?? 80, rows = options.rows ?? 24
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let command = options.command ?? [shell, "-l"]
        var cwd = options.cwd ?? NSHomeDirectory()
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir) || !isDir.boolValue { cwd = NSHomeDirectory() }

        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("HERDR_") && !$0.key.hasPrefix("CLOTHO_") }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "clotho"
        env["CLOTHO_PANE"] = String(id)
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        for (key, value) in options.env ?? [:] { env[key] = value }

        let fake = FakePane(id: id, backend: self, cols: cols, rows: rows)
        guard fake.start(command: command, env: env, cwd: cwd) else {
            throw BackendError(code: "spawn_failed", message: "couldn't start \(command.joined(separator: " "))")
        }
        panes[id] = fake
        state.panes.append(ClothoKit.Pane(id: id, cols: cols, rows: rows, pid: fake.pid, command: command, cwd: cwd))
        return id
    }

    /// Forgets panes (and their model entries) without touching layouts; returns them to hang up.
    private func detach(_ ids: [PaneID]) -> [FakePane] {
        state.panes.removeAll { ids.contains($0.id) }
        return ids.compactMap { panes.removeValue(forKey: $0) }
    }

    /// Takes a pane out of its tab, closing the tab if it was the last pane.
    private func removeFromLayout(_ pane: PaneID) {
        state.panes.removeAll { $0.id == pane }
        guard let (w, t) = indexOfTab(containing: pane) else { return }
        let old = state.workspaces[w].tabs[t].layout
        if let layout = old.removing(pane) {
            state.workspaces[w].tabs[t].layout = layout
            // Focus moves to the pane that takes the closed one's place.
            if state.workspaces[w].tabs[t].activePane == pane {
                state.workspaces[w].tabs[t].activePane = old.sibling(of: pane)?.panes.first ?? layout.panes.first!
            }
        } else {
            state.workspaces[w].tabs.remove(at: t)
        }
        repairFocus()
    }

    /// Points focus at something that still exists, staying as close as possible to where it was.
    private func repairFocus() {
        var focus = state.focus
        let workspace = state.workspace(focus.workspace) ?? state.workspaces.first
        focus.workspace = workspace?.id
        let tab = workspace?.tabs.first { $0.id == focus.tab } ?? workspace?.tabs.last
        focus.tab = tab?.id
        if let tab, !tab.layout.contains(focus.pane ?? 0) { focus.pane = tab.activePane }
        if tab == nil { focus.pane = nil }
        state.focus = focus
    }

    private func workspaceIndex(_ id: WorkspaceID) throws -> Int {
        guard let w = state.workspaces.firstIndex(where: { $0.id == id }) else { throw notFound("workspace \(id)") }
        return w
    }

    private func tabIndex(_ id: TabID) throws -> (Int, Int) {
        for (w, workspace) in state.workspaces.enumerated() {
            if let t = workspace.tabs.firstIndex(where: { $0.id == id }) { return (w, t) }
        }
        throw notFound("tab \(id)")
    }

    private func indexOfTab(containing pane: PaneID) -> (Int, Int)? {
        for (w, workspace) in state.workspaces.enumerated() {
            if let t = workspace.tabs.firstIndex(where: { $0.layout.contains(pane) }) { return (w, t) }
        }
        return nil
    }

    private func notFound(_ what: String) -> BackendError {
        BackendError(code: "not_found", message: "no \(what)")
    }
}

// MARK: - One shell

/// A shell on its own PTY, with a headless terminal that answers the application's queries (DA, DSR,
/// colors, size) the way clothod's VT does, and reports title, cwd and bell.
final class FakePane: TerminalDelegate, LocalProcessDelegate, @unchecked Sendable {
    let id: PaneID
    private weak var backend: FakeBackend?
    private let queue: DispatchQueue
    private var process: LocalProcess!
    private var terminal: Terminal!
    private let sizeLock = NSLock()
    private var size: (cols: Int, rows: Int)

    // Guarded by the backend's lock.
    var seq: UInt64 = 0
    var buffer = Data()
    var subscribed = false

    // Only touched on `queue`, while a feed is in progress.
    private var pendingTitle: String?
    private var pendingCwd: String?
    private var pendingBell = false

    init(id: PaneID, backend: FakeBackend, cols: Int, rows: Int) {
        self.id = id
        self.backend = backend
        queue = DispatchQueue(label: "clotho.fake.pane.\(id)")
        size = (cols, rows)
        terminal = Terminal(delegate: self, options: TerminalOptions(cols: cols, rows: rows, scrollback: 0))
        process = LocalProcess(delegate: self, dispatchQueue: queue)
    }

    var pid: Int32? {
        let pid = process.shellPid
        return pid > 0 ? pid : nil
    }

    func start(command: [String], env: [String: String], cwd: String) -> Bool {
        guard let executable = command.first else { return false }
        // A leading "-" in argv[0] makes a login shell, like Terminal.app does.
        let login = command.count == 2 && command[1] == "-l"
        let result = process.startProcessChecked(
            executable: executable,
            args: login ? [] : Array(command.dropFirst()),
            environment: env.map { "\($0.key)=\($0.value)" },
            execName: login ? "-" + (executable as NSString).lastPathComponent : nil,
            currentDirectory: cwd)
        if case .failure = result { return false }
        return true
    }

    func send(_ bytes: Data) {
        process.send(data: ArraySlice(bytes))
    }

    func resize(cols: Int, rows: Int) {
        sizeLock.withLock { size = (cols, rows) }
        // Inline rather than on `queue`, which LocalProcess keeps busy reading. The terminal lock orders
        // this against a feed in progress.
        terminal.terminalLock.withLock { terminal.resize(cols: cols, rows: rows) }
        var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        let fd = process.childfd
        if fd >= 0 { _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: fd, windowSize: &ws) }
    }

    /// Like clothod's `pane.close`: SIGHUP to the pane's process group.
    func hangUp() {
        let pid = process.shellPid
        guard pid > 0 else { return }
        kill(-pid, SIGHUP)
        kill(pid, SIGHUP)
    }

    func processCwd() -> String? {
        let pid = process.shellPid
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    // MARK: LocalProcessDelegate (on `queue`)

    func dataReceived(slice: ArraySlice<UInt8>) {
        terminal.terminalLock.withLock { terminal.feed(buffer: slice) }
        backend?.paneOutput(self, Data(slice))
        if pendingTitle != nil || pendingCwd != nil || pendingBell {
            backend?.paneChanged(self, title: pendingTitle, cwd: pendingCwd, bell: pendingBell)
            pendingTitle = nil
            pendingCwd = nil
            pendingBell = false
        }
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        backend?.paneExited(self, code: exitCode)
    }

    func getWindowSize() -> winsize {
        let (cols, rows) = sizeLock.withLock { size }
        return winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
    }

    // MARK: TerminalDelegate (inside a feed, on `queue`)

    /// The headless terminal's replies to queries go straight back to the application.
    func send(source: Terminal, data: ArraySlice<UInt8>) {
        process.send(data: data)
    }

    func setTerminalTitle(source: Terminal, title: String) { pendingTitle = title }
    func hostCurrentDirectoryUpdated(source: Terminal) {
        // OSC 7 sends a file:// URL.
        guard let value = source.hostCurrentDirectory else { return }
        pendingCwd = URL(string: value)?.path ?? value
    }
    func bell(source: Terminal) { pendingBell = true }
}

private extension Layout {
    func replacing(_ pane: PaneID, with make: (Layout) -> Layout) -> Layout {
        switch self {
        case .pane(let id):
            return id == pane ? make(self) : self
        case let .split(id, axis, ratio, a, b):
            return .split(id: id, axis: axis, ratio: ratio, a: a.replacing(pane, with: make), b: b.replacing(pane, with: make))
        }
    }

    /// The layout without `pane` (its sibling takes the split's place), or nil if nothing is left.
    func removing(_ pane: PaneID) -> Layout? {
        switch self {
        case .pane(let id):
            return id == pane ? nil : self
        case let .split(id, axis, ratio, a, b):
            switch (a.removing(pane), b.removing(pane)) {
            case let (newA?, newB?): return .split(id: id, axis: axis, ratio: ratio, a: newA, b: newB)
            case let (newA?, nil): return newA
            case let (nil, newB?): return newB
            case (nil, nil): return nil
            }
        }
    }

    /// The subtree that shares `pane`'s split, which takes its place when it closes.
    func sibling(of pane: PaneID) -> Layout? {
        guard case let .split(_, _, _, a, b) = self else { return nil }
        if a == .pane(pane) { return b }
        if b == .pane(pane) { return a }
        return a.sibling(of: pane) ?? b.sibling(of: pane)
    }

    func settingRatio(of split: SplitID, to ratio: Double) -> Layout? {
        guard case let .split(id, axis, old, a, b) = self else { return nil }
        if id == split { return .split(id: id, axis: axis, ratio: ratio, a: a, b: b) }
        if let newA = a.settingRatio(of: split, to: ratio) { return .split(id: id, axis: axis, ratio: old, a: newA, b: b) }
        if let newB = b.settingRatio(of: split, to: ratio) { return .split(id: id, axis: axis, ratio: old, a: a, b: newB) }
        return nil
    }
}
