import AppKit
import ClothoKit

// Highlighted workspaces: right-click a workspace in the sidebar › Highlight › a colour, as Finder's tags
// do. The row (and its ⌘P row) gets a faint tint of it. Kept on this Mac only, by machine and workspace
// id, across relaunches; a workspace that closes loses its highlight.

enum WorkspaceHighlight: String, CaseIterable {
    case red, orange, yellow, green, blue, purple, gray

    var title: String { rawValue.capitalized }

    /// The system's own colours, which adapt to light and dark.
    var color: NSColor {
        switch self {
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .gray: return .systemGray
        }
    }

    /// A Finder-style dot for the menu.
    var dot: NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            self.color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.accessibilityDescription = title
        return image
    }
}

/// Where highlights are kept: one dictionary in the defaults, "<machine>/<workspace>" to a colour.
enum WorkspaceHighlights {
    static let defaultsKey = "WorkspaceHighlights"
    /// Tests use their own suite.
    nonisolated(unsafe) static var store = UserDefaults.standard
    /// After any change, so the sidebar and ⌘P redraw.
    static let didChange = Notification.Name("WorkspaceHighlightsDidChange")

    static func key(_ machine: MachineKey, _ workspace: WorkspaceID) -> String { "\(machine)/\(workspace)" }

    private static var all: [String: String] {
        get { store.dictionary(forKey: defaultsKey) as? [String: String] ?? [:] }
        set {
            if newValue.isEmpty { store.removeObject(forKey: defaultsKey) } else { store.set(newValue, forKey: defaultsKey) }
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static func get(_ machine: MachineKey, _ workspace: WorkspaceID) -> WorkspaceHighlight? {
        all[key(machine, workspace)].flatMap(WorkspaceHighlight.init(rawValue:))
    }

    /// Sets a workspace's highlight; nil removes it.
    static func set(_ highlight: WorkspaceHighlight?, _ machine: MachineKey, _ workspace: WorkspaceID) {
        var dict = all
        dict[key(machine, workspace)] = highlight?.rawValue
        all = dict
    }

    /// Drops the highlights of a machine's workspaces that no longer exist. Returns how many went.
    @discardableResult
    static func prune(_ machine: MachineKey, keeping workspaces: Set<WorkspaceID>) -> Int {
        let dict = all
        let prefix = "\(machine)/"
        let gone = dict.keys.filter { key in
            guard key.hasPrefix(prefix), let id = WorkspaceID(key.dropFirst(prefix.count)) else { return false }
            return !workspaces.contains(id)
        }
        guard !gone.isEmpty else { return 0 }
        all = dict.filter { !gone.contains($0.key) }
        return gone.count
    }

    /// How much stronger the tint is on the selected row (which also shows its selection bar and bold title).
    static let selectedBoost: CGFloat = 0.10

    /// The tint's opacity under a row: enough to tell colours apart, faint enough to read through.
    static func alpha(dark: Bool, hovering: Bool) -> CGFloat {
        (dark ? 0.20 : 0.16) + (hovering ? 0.08 : 0)
    }
}

extension AppDelegate {
    /// Each live, connected machine's closed workspaces lose their highlights (every sync; cheap when
    /// nothing went). Not before the daemon's first state: an empty model then isn't "all closed".
    func pruneWorkspaceHighlights() {
        for (key, session) in connections {
            let store = session.store
            guard store.isConnected, store.phase == .live, store.state.rev > 0 else { continue }
            let removed = WorkspaceHighlights.prune(key, keeping: Set(store.state.workspaces.map(\.id)))
            if removed > 0 { log("highlights: dropped \(removed) for closed workspaces on \(key)") }
        }
    }
}

extension NSMenu {
    /// "Highlight ▸" with the colours, None, and a checkmark on the current one.
    static func highlightItem(current: WorkspaceHighlight?, choose: @escaping (WorkspaceHighlight?) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: "Highlight", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Highlight")
        for color in WorkspaceHighlight.allCases {
            let option = ClosureMenuItem(title: color.title) { choose(color) }
            option.image = color.dot
            option.state = current == color ? .on : .off
            menu.addItem(option)
        }
        menu.addItem(.separator())
        let none = ClosureMenuItem(title: "None") { choose(nil) }
        none.state = current == nil ? .on : .off
        menu.addItem(none)
        item.submenu = menu
        return item
    }
}
