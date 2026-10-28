import ClothoKit
import SwiftUI
import UIKit

/// The top of the home screen: agents on every connected machine that need the user, each with Resolve,
/// then a folded "Quiet" group with the rest (running, idle and resolved ones).
struct AgentsSection: View {
    let rows: [AgentRow]
    let connections: Connections
    let open: (AgentRow) -> Void
    @State private var replying: AgentRow?
    @State private var history: AgentRow?
    @SceneStorage("AgentsQuietExpanded") private var quietExpanded = false

    var body: some View {
        if !rows.isEmpty {
            let parts = AgentRow.split(rows)
            Section {
                ForEach(parts.attention) { row in
                    attentionRow(row)
                }
                .sheet(item: $history) { row in
                    if let connection = connections.existing(row.machineID) {
                        AgentHistoryView(connection: connection, pane: row.pane)
                    }
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
                                .swipeActions(edge: .trailing) { muteButton(row) }
                                .contextMenu { muteButton(row); historyButton(row) }
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
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { open(row) } label: { AgentRowView(row: row) }
                    .buttonStyle(.plain)
                Button { resolve(row) } label: {
                    Image(systemName: "checkmark.circle").font(.title3)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Resolve")
            }
            if let connection { PermissionButtons(row: row, connection: connection) }
        }
        .swipeActions(edge: .trailing) {
            Button { resolve(row) } label: { Label("Resolve", systemImage: "checkmark") }
                .tint(.green)
            muteButton(row)
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
            muteButton(row)
            historyButton(row)
            if row.acceptsReply, let connection {
                if connection.canReply {
                    Button { replying = row } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                } else {
                    Text("Update clothod on \(row.machineName) to reply")
                }
            }
        }
    }

    /// What the agent did and asked, from the machine (`agent.history`).
    @ViewBuilder private func historyButton(_ row: AgentRow) -> some View {
        if let connection = connections.existing(row.machineID), connection.store.hello?.features.contains(.agentHistory) == true {
            Button { history = row } label: { Label("History", systemImage: "clock.arrow.circlepath") }
        }
    }

    /// Mute keeps an agent under Quiet with no notifications until it's unmuted or its session ends; Unmute
    /// undoes it (the agent comes back to the top the next time it needs the user). Daemons without
    /// `agent.mute` get neither.
    @ViewBuilder private func muteButton(_ row: AgentRow) -> some View {
        if let connection = connections.existing(row.machineID), connection.canMute {
            if row.isMuted {
                Button { connection.muteAgent(row.pane, false) } label: { Label("Unmute", systemImage: "bell") }
                    .tint(.indigo)
            } else {
                Button { connection.muteAgent(row.pane, true) } label: { Label("Mute", systemImage: "bell.slash") }
                    .tint(.indigo)
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
                    if row.isMuted {
                        Image(systemName: "bell.slash").font(.caption).foregroundStyle(.secondary).accessibilityLabel("Muted")
                    }
                    Spacer()
                    if let since = row.info.sinceDate {
                        // Compact, as on the Mac ("1m", "2h"), updated each minute.
                        TimelineView(.everyMinute) { context in
                            Text(AgentRowView.age(since, now: context.date))
                        }
                        .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
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

extension AgentRowView {
    /// How long an agent has been in its state, compact as on the Mac: "now", "1m", "6m", "2h", "3d".
    static func age(_ since: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86400)d"
        }
    }
}

/// Allow and Deny for an agent's pending permission request (`agent.decide`), on its card. They answer that
/// request by id, so a late tap can't approve a different prompt; Claude's own dialog in the terminal stays
/// up too, and whichever answers first wins.
struct PermissionButtons: View {
    let row: AgentRow
    @ObservedObject var connection: MachineConnection
    @State private var working = false
    @State private var note: String?

    var body: some View {
        if let answered = connection.answered[row.pane] {
            Label(answered == .allow ? "Allowed" : "Denied", systemImage: answered == .allow ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(answered == .allow ? .green : .red)
                .accessibilityIdentifier("answered")
        } else if let request = row.info.pendingRequests.first, connection.canDecide, row.wantsAttention {
            VStack(alignment: .leading, spacing: 6) {
                Text(request.question).font(.callout.weight(.medium)).lineLimit(3)
                HStack(spacing: 10) {
                    // The icons take their label's colour: white on the green Allow, red on Deny.
                    Button { answer(request, .allow) } label: {
                        Label("Allow", systemImage: "checkmark").foregroundStyle(.white).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.green)
                    .accessibilityIdentifier("allowRequest")
                    Button(role: .destructive) { answer(request, .deny) } label: {
                        Label("Deny", systemImage: "xmark").foregroundStyle(.red).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("denyRequest")
                }
                .controlSize(.large)
                .disabled(working)
                if row.info.pendingRequests.count > 1 {
                    Text("\(row.info.pendingRequests.count - 1) more waiting after this one")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 30)
        }
        if let note {
            Text(note).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("decideNote")
        }
    }

    private func answer(_ request: PermissionRequest, _ decision: PermissionDecision) {
        working = true
        note = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task {
            switch await connection.decide(row.pane, request: request.id, decision: decision) {
            case .done: break
            case .alreadyAnswered: note = "Already answered."
            case .failed(let message): note = "Couldn't answer: \(message)"
            }
            working = false
        }
    }
}
