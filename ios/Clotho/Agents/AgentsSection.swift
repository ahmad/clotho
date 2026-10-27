import ClothoKit
import SwiftUI

/// The top of the home screen: every agent on every connected machine, waiting first.
struct AgentsSection: View {
    let rows: [AgentRow]
    let connections: Connections
    let open: (AgentRow) -> Void
    @State private var replying: AgentRow?

    var body: some View {
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in
                    let connection = connections.existing(row.machineID)
                    Button { open(row) } label: { AgentRowView(row: row) }
                        .tint(.primary)
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
                            if row.acceptsReply, let connection {
                                if connection.canReply {
                                    Button { replying = row } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                                } else {
                                    Text("Update clothod on \(row.machineName) to reply")
                                }
                            }
                        }
                }
                .sheet(item: $replying) { row in
                    if let connection = connections.existing(row.machineID) {
                        QuickReplySheet(row: row, connection: connection)
                    }
                }
            } header: {
                Text("Agents")
            }
        }
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
