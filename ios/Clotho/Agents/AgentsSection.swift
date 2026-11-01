import ClothoKit
import SwiftUI
import UIKit

/// The agents on every connected machine: those that need the user first ("Needs you"), then the rest (running,
/// idle, resolved). Rows are compact; Resolve, Mute, Reply and History are swipe actions and the long-press menu.
/// The Agents tab on the iPhone, and the top of the iPad's sidebar.
struct AgentsSection: View {
    let rows: [AgentRow]
    let connections: Connections
    let open: (AgentRow) -> Void
    /// The quick reply and history sheets, presented by the list that holds the section (`agentSheets`).
    @Binding var replying: AgentRow?
    @Binding var history: AgentRow?

    var body: some View {
        if !rows.isEmpty {
            let parts = AgentRow.split(rows)
            if !parts.attention.isEmpty {
                Section {
                    ForEach(parts.attention) { row in
                        attentionRow(row)
                    }
                } header: {
                    Text("Needs you")
                }
            }
            if !parts.quiet.isEmpty {
                Section {
                    ForEach(parts.quiet) { row in
                        Button { open(row) } label: { AgentRowView(row: row) }
                            .tint(.primary)
                            .accessibilityIdentifier("quietAgent")
                            .listRowInsets(Self.insets)
                            .swipeActions(edge: .trailing) { muteButton(row) }
                            .contextMenu { muteButton(row); historyButton(row) }
                    }
                } header: {
                    Text("Quiet")
                }
            }
        }
    }

    /// Tight rows, so many fit on screen.
    static let insets = EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 14)

    private func attentionRow(_ row: AgentRow) -> some View {
        let connection = connections.existing(row.machineID)
        return VStack(alignment: .leading, spacing: 6) {
            Button { open(row) } label: { AgentRowView(row: row) }
                .buttonStyle(.plain)
                .accessibilityIdentifier("needsYouAgent")
            if let connection { PermissionButtons(row: row, connection: connection) }
        }
        .listRowInsets(Self.insets)
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

/// One agent, in four short lines:
///
///     Platform › api-server                       4m
///     Ran the tests; two failures in push.rs. Wants to
///     know whether to fix them now.
///     devbox · Claude · Needs you
///
/// Where it is (workspace › tab), what it said (its summary, else its message as plain text; a permission ask
/// reads "Allow Bash: npm test?"), and in small letters the machine, the agent and its status, tinted.
struct AgentRowView: View {
    let row: AgentRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(row.workspace) › \(row.title)")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if let since = row.info.sinceDate {
                    // Compact, as on the Mac ("1m", "2h"), updated each minute.
                    TimelineView(.everyMinute) { context in
                        Text(AgentRowView.age(since, now: context.date))
                    }
                    .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
            if let summary = row.summary {
                Text(summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 4) {
                Text("\(row.machineName) · \(row.info.shortKindName) ·").foregroundStyle(.tertiary)
                if row.info.state == .running || row.info.state == .starting {
                    Circle().fill(Color.blue.opacity(0.8)).frame(width: 5, height: 5)
                }
                Text(row.status).foregroundStyle(row.statusColor).fontWeight(.medium)
                if row.isMuted {
                    Image(systemName: "bell.slash").foregroundStyle(.tertiary).accessibilityLabel("Muted")
                }
            }
            .font(.caption)
            .lineLimit(1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// An agent's quick reply and history, for the list that shows an AgentsSection.
    func agentSheets(replying: Binding<AgentRow?>, history: Binding<AgentRow?>, connections: Connections) -> some View {
        sheet(item: history) { row in
            if let connection = connections.existing(row.machineID) {
                AgentHistoryView(connection: connection, pane: row.pane)
            }
        }
        .sheet(item: replying) { row in
            if let connection = connections.existing(row.machineID) {
                QuickReplySheet(row: row, connection: connection)
            }
        }
    }
}

extension AgentRow {
    /// The row's two lines: the pending permission request's question ("Allow Bash: npm test?"), else the
    /// permission ask, the summary or the plain message (`AgentInfo.headline`).
    var summary: String? {
        if wantsAttention, let request = info.pendingRequests.first { return request.question }
        return info.headline.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// "Needs you" for a waiting agent that asked for the user; else its state ("Running", "Done", "Error").
    var status: String {
        if info.state == .waiting && wantsAttention { return "Needs you" }
        return info.state.label
    }

    var statusColor: Color {
        switch info.state {
        case .waiting: return wantsAttention ? .orange : .secondary
        case .done: return .green
        case .error: return .red
        case .running: return .blue
        case .starting, .unknown: return .secondary
        }
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
                .font(.subheadline.weight(.medium))
                .foregroundStyle(answered == .allow ? .green : .red)
                .accessibilityIdentifier("answered")
        } else if let request = row.info.pendingRequests.first, connection.canDecide, row.wantsAttention {
            // The question itself is the row's summary line ("Allow Bash: npm test?"): only the answers here.
            HStack(spacing: 8) {
                Button { answer(request, .allow) } label: {
                    Label("Allow", systemImage: "checkmark").foregroundStyle(.white).padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent).tint(.green)
                .accessibilityIdentifier("allowRequest")
                Button(role: .destructive) { answer(request, .deny) } label: {
                    Label("Deny", systemImage: "xmark").foregroundStyle(.red).padding(.horizontal, 6)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("denyRequest")
                if row.info.pendingRequests.count > 1 {
                    Text("+\(row.info.pendingRequests.count - 1)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityLabel("\(row.info.pendingRequests.count - 1) more waiting after this one")
                }
            }
            .font(.footnote.weight(.semibold))
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .disabled(working)
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
