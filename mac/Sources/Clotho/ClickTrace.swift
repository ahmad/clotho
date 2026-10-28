import AppKit
import ClothoKit

/// Times a sidebar or tab bar click until its result shows (TraceClicks=YES). Each mark is logged once,
/// as milliseconds since the click's mouse-down:
///   handler: the click reached the app's handler
///   selected: a redraw shows the target selected in the sidebar and the tab bar
///   shown: the target tab's panes are in the split view
///   painted: the run loop came round after that redraw (the frame is committed)
///   content: the first output or snapshot for a shown pane after the click
/// Plus how long each sync() and sidebar update took while a trace runs.
@MainActor
enum ClickTrace {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "TraceClicks") }

    private static var start: TimeInterval?
    private static var label = ""
    private static var marked: Set<String> = []
    /// The tab the click leads to, once known.
    static var target: (machine: MachineKey, tab: TabID?)?

    /// Starts timing at the current event's time (the mouse-down), or now.
    static func begin(_ what: String, machine: MachineKey, tab: TabID?) {
        guard enabled else { return }
        start = NSApp.currentEvent?.timestamp ?? ProcessInfo.processInfo.systemUptime
        label = what
        marked = []
        target = (machine, tab)
        mark("handler")
        // A trace that never completes stops after a few seconds.
        let started = start
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if start == started { finish() }
        }
    }

    static var isRunning: Bool { start != nil }

    static func mark(_ what: String) {
        guard let start, marked.insert(what).inserted else { return }
        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
        log(String(format: "click %@: %@ +%.1f ms", label, what, ms))
        if what == "content" { finish() }
    }

    /// Runs `body`, logging how long it took while a trace runs.
    static func measure<T>(_ what: String, _ body: () -> T) -> T {
        guard start != nil else { return body() }
        let t0 = ProcessInfo.processInfo.systemUptime
        let result = body()
        log(String(format: "click %@: %@ took %.1f ms", label, what, (ProcessInfo.processInfo.systemUptime - t0) * 1000))
        return result
    }

    static func finish() {
        start = nil
        target = nil
    }
}
