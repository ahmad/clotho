import ClothoKit
import SwiftUI

/// The top of the home screen: agents on every connected machine that need the user, each with Resolve,
/// then a folded "Quiet" group with the rest (running, idle and resolved ones).
struct AgentsSection: View {
    let rows: [AgentRow]
    let connections: Connections
    let open: (AgentRow) -> Void
    @State private var replying: AgentRow?
    @SceneStorage("AgentsQuietExpanded") private var quietExpanded = false

    var body: some View {
        if !rows.isEmpty {
            let parts = AgentRow.split(rows)
            Section {
                ForEach(parts.attention) { row in
                    attentionRow(row)
                }
                .sheet(item: $replying) { row in
                    if let connection = connections.existing(row.machineID) {
                        QuickReplySheet(row: row, connection: connection)
                    }
                }
                if !parts.quiet.isEmpty {
                    DisclosureGroup(isExpanded: $quietExpanded) {
                        ForEach(parts.quiet) { row in
                            Button { open(row) } label: { AgentRowView(row: row) }
                                .tint(.primary)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text("Quiet").foregroundStyle(.secondary)
                            Text("\(parts.quiet.count)").foregroundStyle(.tertiary).monospacedDigit()
                        }
                        .font(.subheadline)
                    }
                    .accessibilityIdentifier("quietAgents")
                }
            } header: {
                Text("Agents")
            }
        }
    }

    private func attentionRow(_ row: AgentRow) -> some View {
        let connection = connections.existing(row.machineID)
        return HStack(spacing: 8) {
            Button { open(row) } label: { AgentRowView(row: row) }
                .buttonStyle(.plain)
            Button { resolve(row) } label: {
                Image(systemName: "checkmark.circle").font(.title3)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Resolve")
        }
        .swipeActions(edge: .trailing) {
            Button { resolve(row) } label: { Label("Resolve", systemImage: "checkmark") }
                .tint(.green)
        }
        .swipeActions(edge: .leading) {
            if row.acceptsReply, let connection {
                if connection.canReply {
                    Button { replying = row } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                        .tint(.accentColor)
                } else {
                    Button {} label: { Label("Update clothod to reply", systemImage: "arrow.up.circle") }
                        .tint(.gray)
                }
            }
        }
        .contextMenu {
            Button { resolve(row) } label: { Label("Resolve", systemImage: "checkmark") }
            if row.acceptsReply, let connection {
                if connection.canReply {
                    Button { replying = row } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                } else {
                    Text("Update clothod on \(row.machineName) to reply")
                }
            }
        }
    }

    /// `agent.ack`: the daemon clears attention for every client; the row moves to Quiet.
    private func resolve(_ row: AgentRow) {
        connections.existing(row.machineID)?.ackAgent(row.pane)
    }
}

struct AgentRowView: View {
    let row: AgentRow

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.info.state.symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(row.info.state.color)
                .frame(width: 24)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.info.kind.capitalized).font(.body.weight(.medium))
                    Text(row.info.state.label)
                        .font(.caption.weight(.semibold))
                        // A waiting agent that hasn't asked for anything is shown quietly.
                        .foregroundStyle(row.info.state == .waiting && !row.wantsAttention ? .secondary : row.info.state.color)
                    if row.wantsAttention {
                        Circle().fill(Color.accentColor).frame(width: 7, height: 7).accessibilityLabel("Needs attention")
                    }
                    Spacer()
                    if let since = row.info.sinceDate {
                        Text(since, style: .relative).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
                if let message = row.info.message, !message.isEmpty {
                    Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Text("\(row.machineName) · \(row.workspace) › \(row.title)")
                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

extension AgentInfo.State {
    var label: String {
        switch self {
        case .starting: return "Starting"
        case .running: return "Running"
        case .waiting: return "Waiting"
        case .done: return "Done"
        case .error: return "Error"
        case .unknown: return "Unknown"
        }
    }

    var symbol: String {
        switch self {
        case .starting: return "circle.dotted"
        case .running: return "circle.dashed"
        case .waiting: return "exclamationmark.bubble.fill"
        case .done: return "checkmark.circle.fill"
        case .error: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .starting, .unknown: return .secondary
        case .running: return .blue
        case .waiting: return .orange
        case .done: return .green
        case .error: return .red
        }
    }
}
