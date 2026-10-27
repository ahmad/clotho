import ClothoKit
import SwiftUI

/// One thing quick open can jump to.
struct QuickOpenItem: Identifiable, Hashable {
    enum Kind: Int { case agent, tab, workspace, machine }

    var kind: Kind
    var title: String
    /// Where it is: "Workspace · Machine".
    var detail: String
    var symbol: String
    var route: Route
    var id: String

    /// Everything on every connected machine, plus the machines themselves.
    @MainActor static func all(machines: [Machine], connections: Connections) -> [QuickOpenItem] {
        var items: [QuickOpenItem] = []
        for row in connections.agentRows where row.wantsAttention {
            items.append(QuickOpenItem(kind: .agent, title: row.title, detail: "\(row.info.state.rawValue.capitalized) · \(row.workspace) · \(row.machineName)",
                                       symbol: "sparkles", route: .pane(row.machineID, row.tab, row.pane),
                                       id: "a\(row.machineID)-\(row.pane)"))
        }
        for machine in machines {
            items.append(QuickOpenItem(kind: .machine, title: machine.displayName, detail: machine.subtitle,
                                       symbol: machine.kind == .localSocket ? "laptopcomputer" : "server.rack",
                                       route: .machine(machine.id), id: "m\(machine.id)"))
            guard let store = connections.existing(machine.id)?.store else { continue }
            for workspace in store.state.workspaces {
                if let first = workspace.tabs.first {
                    items.append(QuickOpenItem(kind: .workspace, title: workspace.name, detail: machine.displayName,
                                               symbol: "folder", route: .pane(machine.id, first.id, first.activePane),
                                               id: "w\(machine.id)-\(workspace.id)"))
                }
                for tab in workspace.tabs {
                    let cwd = store.state.pane(tab.activePane)?.cwd ?? ""
                    items.append(QuickOpenItem(kind: .tab, title: store.displayTitle(of: tab),
                                               detail: [workspace.name, machine.displayName, cwd].filter { !$0.isEmpty }.joined(separator: " · "),
                                               symbol: tab.layout.panes.count > 1 ? "rectangle.split.2x1" : "terminal",
                                               route: .pane(machine.id, tab.id, tab.activePane), id: "t\(machine.id)-\(tab.id)"))
                }
            }
        }
        return items
    }

    /// The items matching `query`, best first; all of them, in kind order, for an empty query.
    static func ranked(_ items: [QuickOpenItem], query: String) -> [QuickOpenItem] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return items.sorted { $0.kind.rawValue < $1.kind.rawValue } }
        return items.compactMap { item -> (QuickOpenItem, Int)? in
            let title = FuzzyScore.score(query, in: item.title)
            let detail = FuzzyScore.score(query, in: item.detail).map { $0 / 3 }
            guard let best = [title, detail].compactMap({ $0 }).max() else { return nil }
            return (item, best)
        }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.kind.rawValue < $1.0.kind.rawValue }
        .map(\.0)
    }
}

/// A subsequence match: every query character in order, scored higher for consecutive runs, word starts and an
/// early first match. (The Mac's ranking moves to ClothoKit, which this will use then.)
enum FuzzyScore {
    static func score(_ query: String, in text: String) -> Int? {
        let q = Array(query.lowercased()), t = Array(text.lowercased()), original = Array(text)
        guard !q.isEmpty else { return 0 }
        var score = 0, qi = 0, last = -2, first = -1
        for (i, c) in t.enumerated() where qi < q.count && c == q[qi] {
            if first < 0 { first = i }
            score += 10
            if i == last + 1 { score += 15 }
            let start = i == 0 || !original[i - 1].isLetter && !original[i - 1].isNumber || (original[i].isUppercase && original[i - 1].isLowercase)
            if start { score += 20 }
            last = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        if t.starts(with: q) { score += 50 }
        return score - first - (t.count - q.count) / 4
    }
}

/// ⌘P, or the search button: find any tab, workspace, machine or waiting agent by name and jump to it.
struct QuickOpenView: View {
    let open: (Route) -> Void
    @EnvironmentObject private var machines: MachineList
    @EnvironmentObject private var connections: Connections
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    var body: some View {
        let results = QuickOpenItem.ranked(QuickOpenItem.all(machines: machines.all, connections: connections), query: query)
        NavigationStack {
            List {
                ForEach(Array(results.prefix(50).enumerated()), id: \.element.id) { index, item in
                    Button { open(item.route) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.symbol).foregroundStyle(Color.selection).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).lineLimit(1)
                                Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .tint(.primary)
                    .listRowBackground(index == highlighted ? Color.selection.opacity(0.22) : nil)
                    .accessibilityAddTraits(index == highlighted ? .isSelected : [])
                }
            }
            .overlay {
                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .safeAreaInset(edge: .top) {
                // A plain field rather than .searchable, so it has the focus as soon as the sheet opens (iOS 17).
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Tabs, workspaces, machines", text: $query)
                        .focused($focused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit { if results.indices.contains(highlighted) { open(results[highlighted].route) } }
                        .accessibilityIdentifier("quickOpenField")
                }
                .padding(10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .onChange(of: query) { highlighted = 0 }
            .onAppear { focused = true }
            .navigationTitle("Quick Open")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .background {
                // Arrow keys move the highlight; Return opens it.
                Group {
                    Button("Next") { highlighted = min(highlighted + 1, max(results.count - 1, 0)) }
                        .keyboardShortcut(.downArrow, modifiers: [])
                    Button("Previous") { highlighted = max(highlighted - 1, 0) }
                        .keyboardShortcut(.upArrow, modifiers: [])
                }
                .hidden()
            }
        }
        .task { await connections.refresh(machines.all) }
    }
}
