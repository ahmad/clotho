import ClothoKit
import SwiftUI
import UIKit

/// Quick open with nothing typed: ClothoKit's CommandTree, as on the Mac's ⌘P. "Needs you" on top (agents
/// waiting or in error on any machine), then the machine on screen's workspaces with the current one open to
/// its tabs; "All machines" goes up to every machine. A tap opens a tab, a workspace (at its last active
/// tab) or an agent's pane, and on a machine shows its workspaces (connecting first when it isn't); the
/// chevron opens or closes a row in place. With a keyboard the arrow keys walk it as on the Mac. Unlike the
/// Mac there's no live preview: the sheet covers the pane.
@MainActor
enum QuickOpenTree {
    /// A machine's key in the tree.
    nonisolated static func key(_ id: UUID) -> String { id.uuidString }

    /// An agent that goes in "Needs you": waiting for the user or in error, and not muted or resolved
    /// (the Mac's CommandBar.needsYou).
    nonisolated static func needsYou(_ row: AgentRow) -> Bool {
        row.wantsAttention && [.waiting, .error].contains(row.info.state)
    }

    /// The machines in the app's order, each with its workspaces and tabs when connected (or showing its
    /// saved model); nil for one that isn't, which a tap connects.
    static func outline(machines: [Machine], connections: Connections) -> CommandTree.Outline {
        outline(machines.map { machine in
            let store = connections.existing(machine.id)?.store
            return (machine.id, store.flatMap { $0.isConnected || $0.isSaved ? $0.state : nil })
        }, agents: connections.agentRows)
    }

    /// The same from plain values: each machine's model (nil when not connected) and every agent row.
    nonisolated static func outline(_ machines: [(id: UUID, state: ModelState?)], agents: [AgentRow]) -> CommandTree.Outline {
        let list = machines.map { machine in
            CommandTree.Outline.Machine(key: key(machine.id),
                                        workspaces: machine.state?.workspaces.map { .init(id: $0.id, tabs: $0.tabs.map(\.id)) })
        }
        let known = Set(machines.map(\.id))
        let waiting = agents.filter { needsYou($0) && known.contains($0.machineID) }
        return .init(machines: list, needsYou: waiting.map { (machine: key($0.machineID), pane: $0.pane) })
    }

    /// The tree as quick open opens: the machine on screen (its current tab selected), or from Home the list
    /// of every machine when there's more than one.
    static func start(machines: [Machine], connections: Connections, focused: UUID?, tab: TabID?) -> CommandTree {
        let outline = outline(machines: machines, connections: connections)
        let machine = focused
            ?? machines.first { connections.existing($0.id)?.store.isConnected == true }?.id
            ?? machines.first?.id
        guard let machine else { return CommandTree(outline: outline, machine: "", workspace: nil, tab: nil) }
        let store = connections.existing(machine)?.store
        let workspace = tab.flatMap { tab in store?.state.workspaces.first { $0.tabs.contains { $0.id == tab } }?.id }
            ?? store?.focusedWorkspace?.id
        var tree = CommandTree(outline: outline, machine: key(machine), workspace: workspace, tab: tab)
        if focused == nil, machines.count > 1 { tree.showMachines() }
        return tree
    }

    /// Where a row goes: a tab at its active pane, a workspace at its last active tab, an agent's pane.
    static func route(_ node: CommandTree.Node, connections: Connections) -> Route? {
        route(node, state: UUID(uuidString: node.machine).flatMap { connections.existing($0)?.store.state })
    }

    nonisolated static func route(_ node: CommandTree.Node, state: ModelState?) -> Route? {
        guard let id = UUID(uuidString: node.machine) else { return nil }
        let workspaces = state?.workspaces ?? []
        switch node {
        case .machine:
            return .machine(id)
        case let .workspace(_, workspaceID):
            guard let workspace = workspaces.first(where: { $0.id == workspaceID }),
                  let tab = workspace.tabs.first(where: { $0.id == workspace.activeTab }) ?? workspace.tabs.first else { return .machine(id) }
            return .pane(id, tab.id, tab.activePane)
        case let .tab(_, tabID):
            guard let tab = workspaces.flatMap(\.tabs).first(where: { $0.id == tabID }) else { return nil }
            return .pane(id, tab.id, tab.activePane)
        case let .agent(_, pane):
            guard let tab = workspaces.flatMap(\.tabs).first(where: { $0.layout.panes.contains(pane) }) else { return nil }
            return .pane(id, tab.id, pane)
        }
    }

    /// How a row looks.
    struct Display {
        var title: String
        var subtitle: String?
        var symbol: String
        var tint: Color = .selection
    }

    static func display(_ node: CommandTree.Node, machines: [Machine], connections: Connections) -> Display {
        let id = UUID(uuidString: node.machine)
        let machine = machines.first { $0.id == id }
        let connection = id.flatMap { connections.existing($0) }
        let state = connection?.store.state
        switch node {
        case .machine:
            let status: String
            if let connection, connection.store.isConnected || connection.isSaved || connection.cantReach {
                status = connection.connectionLabel
            } else if let connection, case .connecting(let step) = connection.store.connection {
                status = step
            } else {
                status = "Not connected"
            }
            return Display(title: machine?.displayName ?? "Machine", subtitle: status,
                           symbol: machine?.kind == .localSocket ? "laptopcomputer" : "server.rack")
        case let .workspace(_, workspaceID):
            let workspace = state?.workspaces.first { $0.id == workspaceID }
            let count = workspace?.tabs.count ?? 0
            return Display(title: workspace?.name ?? "Workspace", subtitle: count == 1 ? "1 tab" : "\(count) tabs", symbol: "folder")
        case let .tab(_, tabID):
            let tab = state?.workspaces.flatMap(\.tabs).first { $0.id == tabID }
            let title = tab.flatMap { connection?.store.displayTitle(of: $0) } ?? "Tab"
            return Display(title: title, symbol: (tab?.layout.panes.count ?? 1) > 1 ? "rectangle.split.2x1" : "terminal")
        case let .agent(_, pane):
            guard let row = connections.agentRows.first(where: { $0.machineID == id && $0.pane == pane }) else {
                return Display(title: "Agent", symbol: "sparkles")
            }
            return Display(title: row.title, subtitle: "\(row.info.state.rawValue.capitalized) · \(row.machineName) › \(row.workspace)",
                           symbol: "sparkles", tint: row.info.state.color)
        }
    }

    /// The accessibility label of a row (UI tests find rows by it).
    static func label(_ display: Display, _ row: CommandTree.Row) -> String {
        var label = display.title
        if row.expandable { label += row.expanded ? ", expanded" : ", collapsed" }
        return label
    }
}

/// One row of the tree: indented by depth, the row's icon and name, and a chevron on rows that open.
struct QuickOpenTreeRow: View {
    let row: CommandTree.Row
    let display: QuickOpenTree.Display
    let selected: Bool
    let activate: () -> Void
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: activate) {
                HStack(spacing: 12) {
                    Image(systemName: display.symbol).foregroundStyle(display.tint).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(display.title).lineLimit(1)
                        if let subtitle = display.subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, CGFloat(row.depth) * 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .tint(.primary)
            .accessibilityLabel(QuickOpenTree.label(display, row))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityValue(Self.kind(row.node))
            .accessibilityIdentifier("treeRow")
            if row.expandable {
                Button(action: toggle) {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(row.expanded ? 90 : 0))
                        .frame(width: 44, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .tint(.secondary)
                .accessibilityLabel(row.expanded ? "Collapse \(display.title)" : "Expand \(display.title)")
                .accessibilityIdentifier("treeToggle")
            }
        }
    }
}

extension QuickOpenTreeRow {
    /// What the row is, for VoiceOver ("tab", "workspace", "machine", "agent").
    static func kind(_ node: CommandTree.Node) -> String {
        switch node {
        case .agent: return "agent"
        case .machine: return "machine"
        case .workspace: return "workspace"
        case .tab: return "tab"
        }
    }
}

/// Quick open's search field. A UITextField, so the hardware keys reach the tree before the field: ↑/↓ move,
/// and with nothing typed ←/→ close and open rows (with text they move the caret, as usual); Tab and ⇧Tab
/// open the selected row or go up (from a search, they leave it at that row or its parent); Return and ⌘1–9
/// open a row; ⌘Return opens the selected tab beside the pane on screen; Esc backs out of commands, then closes.
struct QuickOpenField: UIViewRepresentable {
    @Binding var text: String
    var onKey: (QuickOpenKey) -> Void

    func makeUIView(context: Context) -> KeyField {
        let field = KeyField()
        field.placeholder = "Tabs, workspaces, machines"
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.returnKeyType = .go
        field.clearButtonMode = .whileEditing
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.accessibilityIdentifier = "quickOpenField"
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // Focus as the sheet opens.
        DispatchQueue.main.async { field.becomeFirstResponder() }
        return field
    }

    func updateUIView(_ field: KeyField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        field.onKey = onKey
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: QuickOpenField
        init(parent: QuickOpenField) { self.parent = parent }

        @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onKey(.activate)
            return false
        }
    }

    final class KeyField: UITextField {
        var onKey: (QuickOpenKey) -> Void = { _ in }

        override var keyCommands: [UIKeyCommand]? {
            var commands = [
                command(UIKeyCommand.inputUpArrow, action: #selector(up)),
                command(UIKeyCommand.inputDownArrow, action: #selector(down)),
                command("\t", action: #selector(tabKey)),
                command("\t", modifiers: .shift, action: #selector(backTab)),
                command(UIKeyCommand.inputEscape, action: #selector(escape)),
                // Return from a hardware keyboard (the software keyboard's Go comes through textFieldShouldReturn).
                command("\r", action: #selector(returnKey)),
                command("\r", modifiers: .command, action: #selector(openBeside)),
            ]
            if (text ?? "").isEmpty {
                commands += [command(UIKeyCommand.inputLeftArrow, action: #selector(left)),
                             command(UIKeyCommand.inputRightArrow, action: #selector(right))]
            }
            for digit in 1...9 { commands.append(command("\(digit)", modifiers: .command, action: #selector(number(_:)))) }
            return commands
        }

        private func command(_ input: String, modifiers: UIKeyModifierFlags = [], action: Selector) -> UIKeyCommand {
            let command = UIKeyCommand(input: input, modifierFlags: modifiers, action: action)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }

        @objc private func up() { onKey(.move(-1)) }
        @objc private func down() { onKey(.move(1)) }
        @objc private func left() { onKey(.collapse) }
        @objc private func right() { onKey(.expand) }
        @objc private func tabKey() { onKey(.tab) }
        @objc private func backTab() { onKey(.backTab) }
        @objc private func escape() { onKey(.escape) }
        @objc private func returnKey() { onKey(.activate) }
        @objc private func openBeside() { onKey(.openBeside) }
        @objc private func number(_ sender: UIKeyCommand) {
            if let input = sender.input, let digit = Int(input) { onKey(.number(digit)) }
        }
    }
}

enum QuickOpenKey: Equatable {
    case move(Int), collapse, expand, tab, backTab, escape, activate, number(Int), openBeside
}
