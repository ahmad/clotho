import AppKit
import ClothoKit

// Whether the user is really at this Mac, for clothod's alerts (0.1.31, feature `alerts`): while they are,
// the daemon holds phone pushes back. Two parts: `UserAction` answers "is there a key or mouse event
// behind what's happening now", and `UserPresence` tells every daemon "the user is here" once a minute
// while Clotho is in front and the keyboard or mouse was used in the last minute.

/// Whether what the app is doing right now has the user's hand behind it.
@MainActor
enum UserAction {
    /// Tests answer for the event queue (nil: ask AppKit).
    static var recentOverride: Bool?
    /// When the app last became active or its window key (system uptime), which the user did too.
    static var cameForwardAt: TimeInterval?

    private static let types: Set<NSEvent.EventType> = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                                        .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel,
                                                        .mouseMoved, .otherMouseDragged, .rightMouseDragged]

    /// The event being handled (or the last one handled) is a key or mouse event younger than `limit`.
    static func isRecent(within limit: TimeInterval) -> Bool {
        if let recentOverride { return recentOverride }
        guard let event = NSApp.currentEvent, types.contains(event.type) else { return false }
        return ProcessInfo.processInfo.systemUptime - event.timestamp < limit
    }

    /// A key or mouse event, or the app or window coming forward, in the last `limit` seconds.
    static func isRecentOrCameForward(within limit: TimeInterval) -> Bool {
        if let recentOverride { return recentOverride }
        if isRecent(within: limit) { return true }
        guard let cameForwardAt else { return false }
        return ProcessInfo.processInfo.systemUptime - cameForwardAt < limit
    }

    static func cameForward() { cameForwardAt = ProcessInfo.processInfo.systemUptime }
}

/// Sends `client.active` to each daemon that takes it while the user is at the app: at most once per
/// machine per `minGap`, and never from the background or while the keyboard and mouse are idle.
@MainActor
final class UserPresence {
    /// A machine as the rule sees it.
    struct Target {
        var key: MachineKey
        var connected: Bool
        var features: Set<Hello.Feature>
    }

    /// How often the timer asks.
    static let interval: TimeInterval = 60
    /// Keyboard and mouse quiet for this long: the user isn't here.
    static let idleLimit: TimeInterval = 60
    /// The least time between two sends to one machine (under `interval`, so every tick sends).
    static let minGap: TimeInterval = 55

    /// The one the app runs, kept here (see `installPaneFocusReporting`).
    static var shared: UserPresence?

    var now: () -> Date = Date.init
    /// The app is active and its main window is key.
    var isFront: () -> Bool
    /// Seconds since the last keyboard or mouse event.
    var idleSeconds: () -> TimeInterval
    var machines: () -> [Target]
    /// Sends `client.active` to a machine.
    var send: (MachineKey) -> Void

    private var lastSent: [MachineKey: Date] = [:]
    private(set) var sent = 0
    private var timer: Timer?

    init(isFront: @escaping () -> Bool, idleSeconds: @escaping () -> TimeInterval = UserPresence.systemIdleSeconds,
         machines: @escaping () -> [Target], send: @escaping (MachineKey) -> Void) {
        self.isFront = isFront
        self.idleSeconds = idleSeconds
        self.machines = machines
        self.send = send
    }

    /// The timer fired, or the app became active or its window key: send if the user is here.
    func check() {
        let targets = machines().filter { $0.connected && $0.features.contains(.alerts) }
        // A machine that went away starts over when it's back (its daemon may be a new one).
        lastSent = lastSent.filter { key, _ in targets.contains { $0.key == key } }
        guard isFront(), idleSeconds() < Self.idleLimit else { return }
        let at = now()
        for target in targets {
            if let last = lastSent[target.key], at.timeIntervalSince(last) < Self.minGap { continue }
            lastSent[target.key] = at
            sent += 1
            send(target.key)
        }
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                self.check()
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Seconds since the user last pressed a key, clicked, scrolled or moved the mouse, in any app. The
    /// window server keeps these, so it takes no event monitor and no permission.
    nonisolated static func systemIdleSeconds() -> TimeInterval {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .mouseMoved]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? .infinity
    }
}

extension AppDelegate {
    /// Starts telling the daemons the user is here (called from `installPaneFocusReporting`).
    func installUserPresence() {
        UserPresence.shared?.stop()
        let presence = UserPresence(
            isFront: { [weak self] in NSApp.isActive && self?.window.isKeyWindow == true },
            machines: { [weak self] in
                (self?.connections ?? [:]).map { key, session in
                    UserPresence.Target(key: key, connected: session.store.isConnected, features: session.store.hello?.features ?? [])
                }
            },
            send: { [weak self] key in
                guard let store = self?.connections[key]?.store else { return }
                let logging = UserDefaults.standard.bool(forKey: "LogModel")
                if logging { log("client.active to \(key)") }
                Task { @MainActor in
                    do { try await store.backend.clientActive() } catch { if logging { log("client.active to \(key) failed: \(error)") } }
                }
            })
        UserPresence.shared = presence
        presence.start()
    }
}
