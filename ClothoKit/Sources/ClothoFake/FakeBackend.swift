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
    private var colors: TerminalColors?
    /// The colours last given to `setTerminalColors`, for tests (the fake has no apps to report them to).
    public var terminalColors: TerminalColors? { locked { colors } }
    /// How many times `setTerminalColors` was called.
    public private(set) var terminalColorsCalls = 0

    /// Hello features on top of the fake's usual ones (see `init`).
    private let extraFeatures: [String]
    /// The fake's settings, in memory (`getSettings`, `setSettings`, `setRewriteHealth`).
    private var settings = DaemonSettings(scrollbackLines: 2000,
                                          limits: .init(scrollbackLines: .init(min: 0, max: 50000, default: 2000)),
                                          notificationRewrite: true)
    /// How many times `clientActive` was called (tests count how often a client sends it).
    public var clientActiveCalls: Int { locked { activeCalls } }
    private var activeCalls = 0

    /// `extraFeatures`: more names for hello's `features` ("settings", "summary", "alerts", "peek"), for
    /// building and testing what a client gates on them. Without any, hello is what it always was.
    public init(extraFeatures: [String] = []) {
        self.extraFeatures = extraFeatures
        (events, continuation) = AsyncStream.makeStream(of: SessionEvent.self)
    }

    deinit {
        stop()
    }

    public func setTerminalColors(_ colors: TerminalColors?) {
        locked {
            self.colors = colors
            terminalColorsCalls += 1
        }
    }

    // MARK: Lifecycle

    public func start() async throws {
        var hello = Hello(protocol: 1, protocolMin: 1, protocolMax: 1, daemon: "clotho-fake", version: "0.1.0",
                          instance: String(UInt64.random(in: 0...UInt64.max), radix: 16),
                          pid: getpid(), machine: Hello.Machine(hostname: Self.hostname, os: "macos", arch: "aarch64"))
        let features = ["pane.keys", "agents", "fs", "restore", "move", "git", "pane.move"]
        hello.featureNames = features + extraFeatures.filter { !features.contains($0) }
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

    /// Makes `focus` take this long, as a round trip to a remote daemon would (tests of local focus).
    public var focusDelay: TimeInterval = 0

    public func focus(_ target: FocusTarget) async throws {
        if focusDelay > 0 { try await Task.sleep(nanoseconds: UInt64(focusDelay * 1e9)) }
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

    /// The panes `focusPane` was called for, in order (tests count how often a client sends it).
    public var focusedPanes: [PaneID] { locked { paneFocusCalls } }
    private var paneFocusCalls: [PaneID] = []

    /// One client: its viewport is already the pane's size. Counted, and fails for an unknown pane as
    /// clothod's does.
    public func focusPane(_ pane: PaneID) async throws {
        try locked {
            guard state.panes.contains(where: { $0.id == pane }) else { throw notFound("pane \(pane)") }
            paneFocusCalls.append(pane)
        }
    }

    /// Counted; the fake has no phone to hold pushes back from.
    public func clientActive() async throws {
        locked { activeCalls += 1 }
    }

    // MARK: Peek (canned: tests and demos set the lines with `setPeek`)

    public enum PeekCall: Equatable, Sendable {
        case subscribe(panes: [PaneID]?, lines: Int)
        case unsubscribe
    }
    /// Every `peekSubscribe` (as asked, before `lines` is brought into 1...8) and `peekUnsubscribe`
    /// call, in order, refused ones included.
    public var peekCalls: [PeekCall] { locked { peekAsks } }
    private var peekAsks: [PeekCall] = []
    private var peekLines: [PaneID: [String]] = [:]
    private var peekSubscription: (panes: Set<PaneID>?, lines: Int)?
    /// What each pane's subscriber was last sent, so only a change is an event (as clothod does it).
    private var peekSent: [PaneID: [String]] = [:]

    /// While true, `peekSubscribe` and `peekUnsubscribe` are noted in `peekCalls` and then neither take
    /// effect nor answer, as with a machine that has stopped answering. Set false, they go on (in no
    /// set order, if more than one was waiting).
    public var peeksHeld: Bool {
        get { locked { peekHold } }
        set { locked { peekHold = newValue } }
    }
    private var peekHold = false

    private func waitWhilePeeksHeld() async throws {
        while locked({ peekHold }) { try await Task.sleep(nanoseconds: 5_000_000) }
    }

    /// With "peek" among `extraFeatures`, as the real backend: the reply's lines are also yielded as
    /// `.peek` events, ids that name no pane are skipped, and `lines` is brought into 1...8. Without
    /// it, `unknown_method`.
    public func peekSubscribe(panes: [PaneID]?, lines: Int) async throws -> [PanePeek] {
        locked { peekAsks.append(.subscribe(panes: panes, lines: lines)) }
        try await waitWhilePeeksHeld()
        return try locked {
            guard extraFeatures.contains("peek") else {
                throw BackendError(code: "unknown_method", message: "this fake wasn't made with the peek feature")
            }
            peekSubscription = (panes.map(Set.init), min(max(lines, 1), 8))
            peekSent.removeAll()
            let wanted = (panes ?? state.panes.map(\.id)).filter { id in state.panes.contains { $0.id == id } }
            var seen = Set<PaneID>()
            let peeks = wanted.filter { seen.insert($0).inserted }.map { PanePeek(pane: $0, lines: peekTail($0)) }
            for peek in peeks {
                peekSent[peek.pane] = peek.lines
                continuation.yield(.peek(peek.pane, lines: peek.lines))
            }
            return peeks
        }
    }

    public func peekUnsubscribe() async throws {
        locked { peekAsks.append(.unsubscribe) }
        try await waitWhilePeeksHeld()
        locked {
            peekSubscription = nil
            peekSent.removeAll()
        }
    }

    /// Sets the last lines of a pane's screen (oldest first). A `.peek` event follows when the peek
    /// subscription wants the pane and the lines it gets differ from the ones it was last sent.
    public func setPeek(_ pane: PaneID, lines: [String]) {
        locked {
            peekLines[pane] = lines
            guard let subscription = peekSubscription, subscription.panes?.contains(pane) ?? true,
                  state.panes.contains(where: { $0.id == pane }) else { return }
            let tail = peekTail(pane)
            guard peekSent[pane] != tail else { return }
            peekSent[pane] = tail
            continuation.yield(.peek(pane, lines: tail))
        }
    }

    /// The pane's lines as its subscriber gets them (call with the lock held).
    private func peekTail(_ pane: PaneID) -> [String] {
        Array((peekLines[pane] ?? []).suffix(peekSubscription?.lines ?? 0))
    }

    // MARK: Settings

    public func getSettings() async throws -> DaemonSettings {
        return locked { () -> DaemonSettings in
            var current = settings
            current.appliedPanes = nil
            return current
        }
    }

    /// Like clothod: an out-of-range scrollback is refused, the result lists no panes (the fake's panes
    /// keep their history), turning the rewrite off or on moves a reported health between `off` and
    /// `unknown`, and a `settings` event follows.
    public func setSettings(_ change: DaemonSettings.Change) async throws -> DaemonSettings {
        return try locked { () throws -> DaemonSettings in
            if let lines = change.scrollbackLines {
                let range = settings.limits.scrollbackLines
                guard (range.min...range.max).contains(lines) else {
                    throw BackendError(code: "bad_request", message: "scrollback_lines must be \(range.min)..\(range.max)")
                }
                settings.scrollbackLines = lines
            }
            if let rewrite = change.notificationRewrite, rewrite != settings.notificationRewrite {
                settings.notificationRewrite = rewrite
                if settings.notificationRewriteHealth != nil {
                    settings.notificationRewriteHealth = .init(state: rewrite ? .unknown : .off)
                }
            }
            var result = settings
            result.appliedPanes = []
            continuation.yield(.settings(settings))
            return result
        }
    }

    /// Sets what the fake reports as `notification_rewrite_health` (nil: none, as on an older daemon) and
    /// sends the `settings` event, as clothod does when the health changes.
    public func setRewriteHealth(_ health: DaemonSettings.RewriteHealth?) {
        locked {
            settings.notificationRewriteHealth = health
            continuation.yield(.settings(settings))
        }
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

    /// Mutes or unmutes the pane's agent, like clothod: a muted agent's attention is cleared and never raised.
    /// Like clothod: answers one request once; anything else is `stale`. Allow sends the agent back to
    /// work once nothing else waits; deny leaves it waiting on whatever is left (or done).
    public func decide(pane: PaneID, request: String, decision: PermissionDecision, message: String?) async throws {
        try locked {
            guard let p = state.panes.firstIndex(where: { $0.id == pane }),
                  let index = state.panes[p].agent?.requests?.firstIndex(where: { $0.id == request }) else {
                throw BackendError(code: "stale", message: "request \(request) was already answered or retired")
            }
            state.panes[p].agent?.requests?.remove(at: index)
            decisions.append((pane, request, decision, message))
            if state.panes[p].agent?.requests?.isEmpty == true, decision == .allow {
                state.panes[p].agent?.state = .running
                state.panes[p].agent?.attention = false
            }
            continuation.yield(.agent(pane, state.panes[p].agent))
            publishPane(at: p)
        }
    }

    /// What `decide` was told, in order (tests).
    public private(set) var decisions: [(pane: PaneID, request: String, decision: PermissionDecision, message: String?)] = []

    /// Marks a pane as restored after a restart (nil clears it), as clothod's `restore` does, for building
    /// and testing the note without rebooting anything.
    public func setRestored(_ pane: PaneID, _ restored: PaneRestore?) {
        locked {
            guard let p = state.panes.firstIndex(where: { $0.id == pane }) else { return }
            state.panes[p].restored = restored
            publishPane(at: p)
        }
    }

    /// Moves by the daemon's rules (`ModelState.moving`). A move that changes nothing sends no state.
    public func move(_ move: MoveRequest) async throws {
        switch move {
        case let .pane(pane, to, direction, ratio, focus):
            return try locked { try graft(moving: .pane(pane), beside: to, direction: direction, ratio: ratio, focus: focus) }
        case let .tabJoin(tab, to, direction, ratio, focus):
            return try locked { try graft(moving: .tab(tab), beside: to, direction: direction, ratio: ratio, focus: focus) }
        case .workspace, .tab: break
        }
        try locked {
            guard let moved = state.moving(move) else {
                if case .workspace(_, let index) = move, index < 0 { throw BackendError(code: "bad_request", message: "negative index") }
                if case .tab(_, _, let index, _) = move, index < 0 { throw BackendError(code: "bad_request", message: "negative index") }
                throw notFound("\(move)")
            }
            guard moved != state else { return }
            state = moved
            publishState()
        }
    }

    /// Sets a pane's git info (nil: outside a repo), as clothod's `git` reports it.
    public func setGit(_ pane: PaneID, _ git: PaneGit?) {
        locked {
            guard let p = state.panes.firstIndex(where: { $0.id == pane }) else { return }
            state.panes[p].git = git
            publishPane(at: p)
        }
    }

    public func dismissRestored(_ pane: PaneID) async throws {
        try locked {
            guard let p = state.panes.firstIndex(where: { $0.id == pane }) else { throw notFound("pane \(pane)") }
            guard state.panes[p].restored != nil else { return }
            state.panes[p].restored = nil
            publishPane(at: p)
        }
    }

    public func muteAgent(_ pane: PaneID, muted: Bool) async throws {
        try locked {
            guard let p = state.panes.firstIndex(where: { $0.id == pane }), state.panes[p].agent != nil else {
                throw BackendError(code: "not_found", message: "no agent in pane \(pane)")
            }
            state.panes[p].agent?.muted = muted ? true : nil
            if muted { state.panes[p].agent?.attention = false }
            continuation.yield(.agent(pane, state.panes[p].agent))
            publishPane(at: p)
        }
    }

    /// Puts a fake agent in a pane (nil removes it), for building the UI without clothod. A waiting,
    /// done or error state starts out needing attention, as clothod's do, unless the agent is muted or
    /// settling. An `attention` the caller gives (true or false) is kept.
    /// The same kind of agent keeps its mute; a different one (a new session) starts unmuted.
    public func setAgent(_ pane: PaneID, _ agent: AgentInfo?) {
        locked {
            guard let p = state.panes.firstIndex(where: { $0.id == pane }) else { return }
            var agent = agent
            if let previous = state.panes[p].agent, previous.isMuted, agent?.kind == previous.kind, agent?.muted == nil {
                agent?.muted = true
            }
            if agent?.isMuted == true {
                agent?.attention = false
            } else if let state = agent?.state, [.waiting, .done, .error].contains(state), agent?.attention == nil, agent?.isSettling != true {
                agent?.attention = true
            }
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
        // Like clothod (0.1.9 on): input never clears attention; only agent.ack or the agent running does.
        sendInput(pane, bytes)
    }

    public func sendInput(_ pane: PaneID, _ bytes: Data) {
        let fake: FakePane? = locked {
            // Typing clears a restored mark, as clothod does; focus and mouse reports don't count.
            if !Self.isReport(bytes), let p = state.panes.firstIndex(where: { $0.id == pane }), state.panes[p].restored != nil {
                state.panes[p].restored = nil
                publishPane(at: p)
            }
            return panes[pane]
        }
        fake?.send(bytes)
    }

    /// A focus report (ESC [ I, ESC [ O) or a mouse report (ESC [ <…, ESC [ M…), which aren't typing.
    static func isReport(_ bytes: Data) -> Bool {
        let b = [UInt8](bytes)
        guard b.count >= 3, b[0] == 0x1b, b[1] == UInt8(ascii: "[") else { return false }
        return [UInt8(ascii: "I"), UInt8(ascii: "O"), UInt8(ascii: "<"), UInt8(ascii: "M")].contains(b[2])
    }

    // MARK: Changes, diffs and worktrees (canned: the fake never runs git)

    /// One `gitDiff` call, as it was asked (tests).
    public struct DiffRequest: Equatable, Sendable {
        public var pane: PaneID
        public var path: String
        public var group: GitChangeGroup
        public var oldPath: String?
        public var context: Int?

        public init(pane: PaneID, path: String, group: GitChangeGroup, oldPath: String? = nil, context: Int? = nil) {
            self.pane = pane
            self.path = path
            self.group = group
            self.oldPath = oldPath
            self.context = context
        }
    }

    private struct DiffKey: Hashable {
        var pane: PaneID
        var path: String
        var group: GitChangeGroup
    }

    private var cannedChanges: [PaneID: Result<GitChanges, BackendError>] = [:]
    private var cannedDiffs: [DiffKey: Result<GitDiff, BackendError>] = [:]
    private var changesCalls: [PaneID] = []
    private var diffRequests: [DiffRequest] = []
    private var worktreeAsks: [WorktreeRequest] = []
    private var histories: [PaneID: [AgentHistoryEntry]] = [:]

    /// Makes `gitChanges` and `gitDiff` take this long, as git does in a big repository.
    public var gitDelay: TimeInterval = 0
    /// Makes a worktree create take this long, as a checkout does.
    public var worktreeDelay: TimeInterval = 0
    /// Makes every worktree create fail with this, after the delay. Nothing is made.
    public var worktreeError: BackendError?

    /// The panes `gitChanges` was called for, in order (tests count the fetches).
    public var gitChangesCalls: [PaneID] { locked { changesCalls } }
    /// Every `gitDiff` call, in order.
    public var gitDiffRequests: [DiffRequest] { locked { diffRequests } }
    /// Every worktree asked for, in order, failed ones included.
    public var worktreeRequests: [WorktreeRequest] { locked { worktreeAsks } }

    /// What `gitChanges` answers for a pane. Unset, it fails with `not_a_repo`. Give the pane's summary
    /// with `setGit` (`GitChanges.summary` makes one that agrees with the list).
    public func setChanges(_ pane: PaneID, _ result: Result<GitChanges, BackendError>) {
        locked { cannedChanges[pane] = result }
    }

    /// What `gitDiff` answers for a file of a pane. Unset, it fails with `not_changed`.
    public func setDiff(_ pane: PaneID, path: String, group: GitChangeGroup, _ result: Result<GitDiff, BackendError>) {
        locked { cannedDiffs[DiffKey(pane: pane, path: path, group: group)] = result }
    }

    public func gitChanges(_ pane: PaneID, limit: Int?) async throws -> GitChanges {
        let delay: TimeInterval = locked {
            changesCalls.append(pane)
            return gitDelay
        }
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        let result: Result<GitChanges, BackendError> = locked {
            guard state.panes.contains(where: { $0.id == pane }) else { return .failure(notFound("pane \(pane)")) }
            return cannedChanges[pane] ?? .failure(BackendError(code: "not_a_repo", message: "pane \(pane) is not in a git repository"))
        }
        return try result.get()
    }

    public func gitDiff(_ pane: PaneID, path: String, group: GitChangeGroup, oldPath: String?, context: Int?) async throws -> GitDiff {
        let delay: TimeInterval = locked {
            diffRequests.append(DiffRequest(pane: pane, path: path, group: group, oldPath: oldPath, context: context))
            return gitDelay
        }
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        let result: Result<GitDiff, BackendError> = locked {
            guard state.panes.contains(where: { $0.id == pane }) else { return .failure(notFound("pane \(pane)")) }
            return cannedDiffs[DiffKey(pane: pane, path: path, group: group)]
                ?? .failure(BackendError(code: "not_changed", message: "\(path) has no \(group.rawValue) changes"))
        }
        return try result.get()
    }

    /// Like clothod's, without git: after `worktreeDelay` (and unless `worktreeError` is set) a normal
    /// fake Tab, whose pane's `git` says it is in a linked worktree. The folder isn't made, so the shell
    /// starts in `spawn.cwd`. The path is clothod's: beside the repository, `<repo>-<name with / as ->`.
    public func createTab(in workspace: WorkspaceID, spawn: SpawnOptions, worktree: WorktreeRequest) async throws -> CreatedTab {
        let made = try await prepareWorktree(spawn, worktree)
        let created = try await createTab(in: workspace, spawn: spawn)
        setGit(created.pane, made.git)
        return CreatedTab(tab: created.tab, pane: created.pane, worktree: made.worktree)
    }

    public func createWorkspace(name: String?, spawn: SpawnOptions, worktree: WorktreeRequest) async throws -> CreatedWorkspace {
        let made = try await prepareWorktree(spawn, worktree)
        let created = try await createWorkspace(name: name, spawn: spawn)
        setGit(created.pane, made.git)
        return CreatedWorkspace(workspace: created.workspace, tab: created.tab, pane: created.pane, worktree: made.worktree)
    }

    /// The delay and the canned error, then where the worktree would be and what its pane's `git` says.
    /// The repository is the one a pane in `spawn.cwd` (or with that root) reports, else `spawn.cwd` itself.
    private func prepareWorktree(_ spawn: SpawnOptions, _ request: WorktreeRequest) async throws -> (worktree: CreatedWorktree, git: PaneGit) {
        guard let cwd = spawn.cwd, !cwd.isEmpty else {
            throw BackendError(code: "bad_request", message: "a worktree needs cwd")
        }
        let (delay, error, source): (TimeInterval, BackendError?, PaneGit?) = locked {
            worktreeAsks.append(request)
            return (worktreeDelay, worktreeError, state.panes.first { $0.git != nil && ($0.cwd == cwd || $0.git?.root == cwd) }?.git)
        }
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        if let error { throw error }
        let root = source?.root ?? cwd
        let repo = source?.repo ?? (root as NSString).lastPathComponent
        let folder = "\(repo)-\(request.name.replacingOccurrences(of: "/", with: "-"))"
        let path = ((root as NSString).deletingLastPathComponent as NSString).appendingPathComponent(folder)
        let head = source?.head ?? "0000000"
        let git = PaneGit(repo: repo, root: path, remote: source?.remote, branch: request.name, head: head,
                          worktree: PaneGit.Worktree(name: folder, path: "../\(folder)"),
                          changes: PaneGit.Changes(
                              uncommitted: PaneGit.Changes.Count(files: 0, added: 0, removed: 0),
                              branch: PaneGit.Changes.BranchCount(base: request.base ?? source?.place ?? "main", commits: 0, files: 0,
                                                                  added: 0, removed: 0)))
        return (CreatedWorktree(path: path, branch: request.name, head: head), git)
    }

    /// What `agentHistory` answers for a pane, oldest first (the Activity list). Unset: no entries.
    public func setAgentHistory(_ pane: PaneID, _ entries: [AgentHistoryEntry]) {
        locked { histories[pane] = entries }
    }

    public func agentHistory(_ pane: PaneID, limit: Int?, since: Double?) async throws -> AgentHistory {
        try locked {
            guard state.panes.contains(where: { $0.id == pane }) else { throw notFound("pane \(pane)") }
            var entries = histories[pane] ?? []
            if let since { entries = entries.filter { $0.at > since } }
            if let limit, limit >= 0 { entries = Array(entries.suffix(limit)) }
            return AgentHistory(pane: pane, max: 200, entries: entries)
        }
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

    /// Like clothod: OSC 52 copies go only to a subscribed client, and never as reads.
    fileprivate func paneClipboard(_ fake: FakePane, _ texts: [String]) {
        locked {
            guard panes[fake.id] === fake, fake.subscribed else { return }
            for text in texts where !text.isEmpty { continuation.yield(.clipboard(fake.id, text: text, selection: false)) }
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
    private enum Moved { case pane(PaneID), tab(TabID) }

    /// pane.move and tab.join, by clothod's rules (protocol.md, "Moving panes"; model.rs move_pane,
    /// join_tab, graft): out of its place (an emptied tab closes, its workspace stays), then into a new
    /// split beside `to`; focus follows when asked or when it was on what moved.
    private func graft(moving what: Moved, beside to: PaneID, direction: Direction, ratio: Double?, focus: Bool) throws {
        guard state.pane(to) != nil, let (toW, toT) = indexOfTab(containing: to) else { throw notFound("pane \(to)") }
        let sub: Layout
        let focusOn: PaneID?
        switch what {
        case let .pane(pane):
            guard pane != to else { throw BackendError(code: "bad_request", message: "pane is to_pane") }
            guard let (w, t) = indexOfTab(containing: pane) else { throw notFound("pane \(pane)") }
            let follows = focus || state.focus.pane == pane
            let old = state.workspaces[w].tabs[t].layout
            if let rest = old.removing(pane) {
                state.workspaces[w].tabs[t].layout = rest
                if state.workspaces[w].tabs[t].activePane == pane {
                    state.workspaces[w].tabs[t].activePane = old.sibling(of: pane)?.panes.first ?? rest.panes.first!
                }
            } else {
                removeTab(at: w, t)
            }
            sub = .pane(pane)
            focusOn = follows ? pane : nil
        case let .tab(tab):
            let (w, t) = try tabIndex(tab)
            guard (w, t) != (toW, toT) else { throw BackendError(code: "bad_request", message: "to_pane is in the tab") }
            let follows = focus || state.focus.tab == tab
            let moved = state.workspaces[w].tabs[t]
            removeTab(at: w, t)
            sub = moved.layout
            focusOn = follows ? moved.activePane : nil
        }
        repairFocus()
        guard let (dw, dt) = indexOfTab(containing: to) else { throw notFound("pane \(to)") }
        let split = makeID()
        let r = min(max(ratio ?? 0.5, Layout.ratioRange.lowerBound), Layout.ratioRange.upperBound)
        state.workspaces[dw].tabs[dt].layout = state.workspaces[dw].tabs[dt].layout.replacing(to) { old in
            direction.newPaneIsSecond
                ? .split(id: split, axis: direction.axis, ratio: r, a: old, b: sub)
                : .split(id: split, axis: direction.axis, ratio: 1 - r, a: sub, b: old)
        }
        if let focusOn {
            state.workspaces[dw].tabs[dt].activePane = focusOn
            state.workspaces[dw].activeTab = state.workspaces[dw].tabs[dt].id
            state.focus = ClothoKit.Focus(workspace: state.workspaces[dw].id, tab: state.workspaces[dw].tabs[dt].id, pane: focusOn)
        } else {
            repairFocus()
        }
        publishState()
    }

    /// Removes a tab with tab.close's rule: the workspace's active tab becomes the one before it.
    private func removeTab(at w: Int, _ t: Int) {
        let id = state.workspaces[w].tabs[t].id
        state.workspaces[w].tabs.remove(at: t)
        if state.workspaces[w].activeTab == id {
            let tabs = state.workspaces[w].tabs
            state.workspaces[w].activeTab = tabs.isEmpty ? nil : tabs[max(t - 1, 0)].id
        }
    }

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
    private var pendingClipboard: [String] = []

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
        if !pendingClipboard.isEmpty {
            backend?.paneClipboard(self, pendingClipboard)
            pendingClipboard = []
        }
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
    /// OSC 52 writes. SwiftTerm doesn't pass on the target, so these count as the clipboard.
    func clipboardCopy(source: Terminal, content: Data) {
        if let text = String(data: content, encoding: .utf8) { pendingClipboard.append(text) }
    }
    /// OSC 52 reads get nothing, as from clothod.
    func clipboardRead(source: Terminal) -> Data? { nil }
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

// Files are this device's own, so the fake machine has a real file browser.
extension FakeBackend: FileBackend {
    private static let files = LocalFileBackend()

    public var supportsFiles: Bool { true }
    public var homeDirectory: String? { NSHomeDirectory() }

    public func stat(_ path: String) async throws -> FileEntry { try await Self.files.stat(path) }
    public func list(_ path: String, hidden: Bool, limit: Int?, cursor: String?) async throws -> FileListing {
        try await Self.files.list(path, hidden: hidden, limit: limit, cursor: cursor)
    }
    public func mkdir(_ path: String, parents: Bool) async throws -> FileEntry { try await Self.files.mkdir(path, parents: parents) }
    public func setattr(_ path: String, mtimeNs: String?, mode: Int?) async throws -> FileEntry {
        try await Self.files.setattr(path, mtimeNs: mtimeNs, mode: mode)
    }
    public func rename(_ from: String, to: String, overwrite: Bool) async throws -> FileEntry {
        try await Self.files.rename(from, to: to, overwrite: overwrite)
    }
    public func remove(_ path: String, recursive: Bool) async throws { try await Self.files.remove(path, recursive: recursive) }
    public func statfs(_ path: String) async throws -> FileSpace { try await Self.files.statfs(path) }
    public func read(_ path: String, options: FileReadOptions) async throws -> FileReadStream { try await Self.files.read(path, options: options) }
    public func write(_ path: String, options: FileWriteOptions, source: FileDataSource,
                      progress: @escaping @Sendable (UInt64) -> Void) async throws -> FileEntry {
        try await Self.files.write(path, options: options, source: source, progress: progress)
    }
}
