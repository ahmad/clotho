// ⌘P's commands, typed after ">" (phase 2), shared by the Mac and iOS: which commands there are, their
// titles and search words, which apply to the selected row, and which need a second pick in the tree
// (moving a tab: where to). Each app runs them its own way; an app leaves out what it doesn't have
// (`supported`), such as the Mac's sidebar on a phone.

public struct CommandListItem: Hashable, Sendable, Identifiable {
    public enum ID: String, CaseIterable, Sendable {
        case newTab, newWorkspace, closeTab, closeWorkspace, splitRight, splitDown
        case claudeHere, codexHere, resumeClaude
        case rename, moveTab, openBeside
        case files, settings, machines, toggleSidebar
        case appearanceSystem, appearanceLight, appearanceDark
        case machineOn, machineOff, reconnect
    }

    /// What the command needs picked before it runs.
    public enum Target: Hashable, Sendable {
        /// A workspace, picked in the same tree (moving a tab).
        case workspace
    }

    public var id: ID
    public var title: String
    /// More words it's found by ("terminal" finds New Tab).
    public var keywords: [String]
    public var target: Target?

    public init(id: ID, title: String, keywords: [String] = [], target: Target? = nil) {
        self.id = id
        self.title = title
        self.keywords = keywords
        self.target = target
    }

    /// Everything the matcher sees: title and keywords.
    public var searchText: String { ([title] + keywords).joined(separator: " ") }
}

/// What a command list is built for: the selected row (its machine, workspace, tab) and the machine's state.
public struct CommandContext: Sendable, Equatable {
    public var machine: String?
    public var machineName: String?
    /// The selected row's workspace (a tab's or an agent's, or the workspace itself).
    public var workspace: WorkspaceID?
    public var workspaceName: String?
    /// A tab row (or an agent's tab).
    public var tab: TabID?
    public var tabName: String?
    public var connected: Bool
    /// Switched on in Clotho (the user's machine list); this Mac always is.
    public var enabled: Bool
    public var isLocal: Bool
    /// The machine stopped retrying (Reconnect).
    public var unreachable: Bool
    /// The daemon can move panes (feature `pane.move`), and the tab is on the focused pane's machine
    /// and isn't the focused tab: Open Beside.
    public var canOpenBeside: Bool

    public init(machine: String? = nil, machineName: String? = nil, workspace: WorkspaceID? = nil, workspaceName: String? = nil,
                tab: TabID? = nil, tabName: String? = nil, connected: Bool = true, enabled: Bool = true, isLocal: Bool = true,
                unreachable: Bool = false, canOpenBeside: Bool = false) {
        self.machine = machine
        self.machineName = machineName
        self.workspace = workspace
        self.workspaceName = workspaceName
        self.tab = tab
        self.tabName = tabName
        self.connected = connected
        self.enabled = enabled
        self.isLocal = isLocal
        self.unreachable = unreachable
        self.canOpenBeside = canOpenBeside
    }
}

public enum CommandList {
    /// The commands that apply to `context`, in a stable order, among the ones the app has. Titles name
    /// the place ("New Tab in api", "Close Tab “zsh”").
    public static func items(for context: CommandContext, supported: Set<CommandListItem.ID> = Set(CommandListItem.ID.allCases)) -> [CommandListItem] {
        var items: [CommandListItem] = []
        func add(_ id: CommandListItem.ID, _ title: String, _ keywords: [String], target: CommandListItem.Target? = nil) {
            guard supported.contains(id) else { return }
            items.append(CommandListItem(id: id, title: title, keywords: keywords, target: target))
        }
        let place = context.workspaceName.map { " in \($0)" } ?? ""
        let live = context.connected && context.enabled

        if live, context.machine != nil {
            add(.newTab, "New Tab" + place, ["terminal", "shell", "open"])
            add(.newWorkspace, "New Workspace" + (context.machineName.map { " on \($0)" } ?? ""), ["create", "project"])
        }
        if live, context.tab != nil {
            add(.splitRight, "Split Right", ["pane", "vertical", "side"])
            add(.splitDown, "Split Down", ["pane", "horizontal", "below"])
        }
        if live, context.workspace != nil {
            add(.claudeHere, "Claude Here", ["agent", "claude code", "ai"])
            add(.codexHere, "Codex Here", ["agent", "openai", "ai"])
            add(.resumeClaude, "Resume Last Claude in This Folder", ["agent", "continue", "claude code", "session"])
        }
        if live, let name = context.tabName, context.tab != nil {
            add(.rename, "Rename Tab “\(name)”", ["title", "name"])
            add(.moveTab, "Move Tab “\(name)” to…", ["workspace", "send"], target: .workspace)
            if context.canOpenBeside { add(.openBeside, "Open “\(name)” Beside This Pane", ["split", "join", "side by side"]) }
            add(.closeTab, "Close Tab “\(name)”", ["quit", "kill", "remove"])
        } else if live, let name = context.workspaceName, context.workspace != nil {
            add(.rename, "Rename Workspace “\(name)”", ["title", "name"])
            add(.closeWorkspace, "Close Workspace “\(name)”", ["quit", "kill", "remove"])
        }

        add(.files, "Open Files", ["browser", "transfer", "upload", "download", "finder"])
        add(.settings, "Open Settings", ["preferences", "options"])
        add(.machines, "Open Machines", ["hosts", "ssh", "servers", "settings"])
        add(.toggleSidebar, "Toggle Sidebar", ["hide", "show", "panel"])
        add(.appearanceSystem, "Appearance: Match System", ["theme", "auto", "mode"])
        add(.appearanceLight, "Appearance: Light", ["theme", "day", "mode"])
        add(.appearanceDark, "Appearance: Dark", ["theme", "night", "mode"])

        if let name = context.machineName, !context.isLocal {
            if context.enabled {
                add(.machineOff, "Turn \(name) Off", ["disable", "disconnect", "machine"])
                if !context.connected || context.unreachable { add(.reconnect, "Reconnect to \(name)", ["connect", "retry", "ssh"]) }
            } else {
                add(.machineOn, "Turn \(name) On", ["enable", "connect", "machine"])
            }
        }
        return items
    }

    /// The commands matching `query` (what follows ">"): every word typed must start a word of the title
    /// or the keywords ("cla" finds Claude Here, "new tab" New Tab, "ren" Rename…), case and accents
    /// aside; scattered letters don't count. Commands whose words all start title words come first, then
    /// by how many matched only in keywords; the list's own order breaks ties. Empty: all of them, in
    /// order.
    public static func matching(_ items: [CommandListItem], query: String) -> [CommandListItem] {
        let needles = words(query)
        guard !needles.isEmpty else { return items }
        let ranked: [(item: CommandListItem, keywordOnly: Int, order: Int)] = items.enumerated().compactMap { order, item in
            let title = words(item.title), keywords = item.keywords.flatMap(words)
            var keywordOnly = 0
            for needle in needles {
                if title.contains(where: { $0.hasPrefix(needle) }) { continue }
                guard keywords.contains(where: { $0.hasPrefix(needle) }) else { return nil }
                keywordOnly += 1
            }
            return (item, keywordOnly, order)
        }
        return ranked.sorted { ($0.keywordOnly, $0.order) < ($1.keywordOnly, $1.order) }.map(\.item)
    }

    /// Lowercased words without accents, split at anything that isn't a letter or digit ("Tab “zsh”"
    /// gives "tab", "zsh").
    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// Text after the command prefix (">"), or nil when the query isn't a command.
    public static func commandQuery(_ text: String) -> String? {
        let trimmed = text.drop { $0 == " " }
        guard trimmed.first == ">" else { return nil }
        return String(trimmed.dropFirst())
    }
}
