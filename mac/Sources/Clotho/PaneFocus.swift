import AppKit
import ClothoKit

// The pane the user is looking at takes this Mac's size (`pane.focus`, clothod 0.1.28): when an iPhone
// had shrunk it, coming back to it here makes it full size again. Typing doesn't pick the size, so the
// app says so whenever a pane really gets the user's focus: it takes the keyboard in the key window,
// the window becomes key or the app active with it focused, the user clicks into it, or a tab switch
// focuses it. One action can set off several of those at once (a click that activates the app makes the
// window key and the terminal first responder), so they're coalesced into one call per run loop turn,
// and a repeat for the same pane right after is dropped.

/// Coalesces "a pane may have the user's focus now" into one `focusPane` per action.
@MainActor
final class PaneFocusReporter {
    /// The pane that has the user's focus right now, if any: the key window's terminal in the active app.
    var current: () -> PaneKey?
    /// Sends `pane.focus` for it.
    var send: (PaneKey, String) -> Void
    var now: () -> Date = Date.init
    /// The same pane again within this long is the same action.
    static let repeatInterval: TimeInterval = 0.3

    private var scheduled: String?
    private var last: (key: PaneKey, at: Date)?
    private(set) var sent = 0

    init(current: @escaping () -> PaneKey?, send: @escaping (PaneKey, String) -> Void) {
        self.current = current
        self.send = send
    }

    /// Something happened that may have given a pane the user's focus; `reason` is for the log.
    func note(_ reason: String) {
        guard scheduled == nil else { return }
        scheduled = reason
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.flush() } }
    }

    /// Sends for the noted actions now (the run loop does it; tests call it directly).
    func flush() {
        guard let reason = scheduled else { return }
        scheduled = nil
        guard let key = current() else { return }
        let at = now()
        if let last, last.key == key, at.timeIntervalSince(last.at) < Self.repeatInterval { return }
        last = (key, at)
        sent += 1
        send(key, reason)
    }

    /// The user left (the window resigned key, the app went to the background): the next focus is a
    /// new action even for the same pane.
    func forget() { last = nil }
}

extension AppDelegate {
    /// The pane with the user's focus: the first responder of the key window, while the app is active.
    var userFocusedPane: PaneKey? {
        guard NSApp.isActive, window.isKeyWindow, let terminal = window.firstResponder as? PaneTerminalView,
              connections[terminal.machine]?.store.state.pane(terminal.paneID) != nil else { return nil }
        return PaneKey(machine: terminal.machine, pane: terminal.paneID)
    }

    func installPaneFocusReporting() {
        let reporter = PaneFocusReporter(current: { [weak self] in self?.userFocusedPane }) { [weak self] key, reason in
            guard let store = self?.connections[key.machine]?.store else { return }
            if UserDefaults.standard.bool(forKey: "LogModel") || UserDefaults.standard.bool(forKey: "TraceFocus") {
                log("pane.focus \(key.pane) on \(key.machine): \(reason)")
            }
            Task { @MainActor in
                do { try await store.focusPane(key.pane) } catch { log("pane.focus \(key.pane) on \(key.machine) failed: \(error)") }
            }
        }
        paneFocusReporter = reporter
        let center = NotificationCenter.default
        let notes: [(Notification.Name, AnyObject?, String, Bool)] = [
            (NSWindow.didBecomeKeyNotification, window, "window became key", false),
            (NSApplication.didBecomeActiveNotification, NSApp, "app became active", false),
            (NSWindow.didResignKeyNotification, window, "", true),
            (NSApplication.didResignActiveNotification, NSApp, "", true),
        ]
        for (name, object, reason, leaving) in notes {
            paneFocusObservers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak reporter] _ in
                MainActor.assumeIsolated { if leaving { reporter?.forget() } else { reporter?.note(reason) } }
            })
        }
        // A click into the pane that already has the keyboard (the user is back from the phone).
        paneFocusClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak reporter] event in
            if let self, event.window === window, let hit = window.contentView?.hitTest(event.locationInWindow),
               hit is PaneTerminalView || hit.enclosingPaneTerminal != nil {
                reporter?.note("click")
            }
            return event
        }
    }
}

private extension NSView {
    var enclosingPaneTerminal: PaneTerminalView? {
        var view = superview
        while let current = view {
            if let terminal = current as? PaneTerminalView { return terminal }
            view = current.superview
        }
        return nil
    }
}
