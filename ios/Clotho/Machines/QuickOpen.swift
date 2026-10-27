import ClothoKit
import SwiftUI

/// One thing quick open can jump to: ClothoKit's item (matched and ranked the same way as on the Mac) plus
/// where it goes and how it looks here.
struct QuickOpenEntry: Identifiable {
    var item: QuickOpenItem
    var symbol: String
    var route: Route
    var id: String { item.id }

    /// In the Mac's order, which an empty query keeps: agents that need the user, then the focused machine's
    /// workspaces and tabs, then other machines' workspaces and tabs, then the machines.
    @MainActor static func all(machines: [Machine], connections: Connections, focused: UUID?) -> [QuickOpenEntry] {
        var entries: [QuickOpenEntry] = []
        for row in connections.agentRows where row.wantsAttention {
            entries.append(QuickOpenEntry(
                item: QuickOpenItem(kind: .agent, title: row.title,
                                    subtitle: "\(row.info.state.rawValue.capitalized) · \(row.machineName) › \(row.workspace)",
                                    id: "a\(row.machineID)-\(row.pane)"),
                symbol: "sparkles", route: .pane(row.machineID, row.tab, row.pane)))
        }
        let ordered = machines.filter { $0.id == focused } + machines.filter { $0.id != focused }
        var tabs: [QuickOpenEntry] = []
        for machine in ordered {
            guard let store = connections.existing(machine.id)?.store else { continue }
            for workspace in store.state.workspaces {
                if let first = workspace.tabs.first {
                    entries.append(QuickOpenEntry(
                        item: QuickOpenItem(kind: .workspace, title: workspace.name, subtitle: machine.displayName,
                                            id: "w\(machine.id)-\(workspace.id)"),
                        symbol: "folder", route: .pane(machine.id, first.id, first.activePane)))
                }
                for tab in workspace.tabs {
                    tabs.append(QuickOpenEntry(
                        item: QuickOpenItem(kind: .tab, title: store.displayTitle(of: tab),
                                            subtitle: "\(machine.displayName) › \(workspace.name)",
                                            id: "t\(machine.id)-\(tab.id)"),
                        symbol: tab.layout.panes.count > 1 ? "rectangle.split.2x1" : "terminal",
                        route: .pane(machine.id, tab.id, tab.activePane)))
                }
            }
            // Each machine's workspaces, then its tabs, before the next machine's.
            entries += tabs
            tabs = []
        }
        for machine in machines {
            entries.append(QuickOpenEntry(
                item: QuickOpenItem(kind: .machine, title: machine.displayName, subtitle: machine.subtitle, id: "m\(machine.id)"),
                symbol: machine.kind == .localSocket ? "laptopcomputer" : "server.rack", route: .machine(machine.id)))
        }
        return entries
    }

    /// The matches for `query`, best first, with the matched letters of each title.
    static func ranked(_ entries: [QuickOpenEntry], query: String) -> [(entry: QuickOpenEntry, indices: [Int])] {
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return QuickOpen.rank(entries.map(\.item), query: query).compactMap { result in
            byID[result.item.id].map { ($0, result.titleIndices) }
        }
    }

    /// The title with the matched letters in bold.
    static func highlighted(_ title: String, _ indices: [Int]) -> AttributedString {
        var text = AttributedString()
        let marked = Set(indices)
        for (offset, character) in title.enumerated() {
            var piece = AttributedString(String(character))
            if marked.contains(offset) {
                piece.font = .body.bold()
                piece.foregroundColor = .selection
            }
            text += piece
        }
        return text
    }
}

/// ⌘P, or the search button: find any tab, workspace, machine or waiting agent by name and jump to it.
struct QuickOpenView: View {
    /// The machine on screen, whose workspaces and tabs come first.
    var focusedMachine: UUID?
    let open: (Route) -> Void
    @EnvironmentObject private var machines: MachineList
    @EnvironmentObject private var connections: Connections
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    var body: some View {
        let results = QuickOpenEntry.ranked(QuickOpenEntry.all(machines: machines.all, connections: connections, focused: focusedMachine), query: query)
        NavigationStack {
            List {
                ForEach(Array(results.enumerated()), id: \.element.entry.id) { index, result in
                    let entry = result.entry
                    Button { open(entry.route) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: entry.symbol).foregroundStyle(Color.selection).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(QuickOpenEntry.highlighted(entry.item.title, result.indices)).lineLimit(1)
                                Text(entry.item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
                        .onSubmit { if results.indices.contains(highlighted) { open(results[highlighted].entry.route) } }
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
