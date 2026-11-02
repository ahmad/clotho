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
    @ObservedObject private var pins = AgentPins.shared

    var body: some View {
        if !rows.isEmpty {
            let pinned = pins.split(rows)
            let parts = AgentRow.split(pinned.rest)
            if !pinned.pinned.isEmpty {
                Section {
                    ForEach(pinned.pinned) { row in
                        Group {
                            if row.wantsAttention { attentionRow(row) } else { quietRow(row) }
                        }
                        .listRowBackground(Color.accentColor.opacity(0.09))
                    }
                } header: {
                    SectionCount(title: "Pinned", count: pinned.pinned.count)
                }
            }
            if !parts.attention.isEmpty {
                Section {
                    ForEach(parts.attention) { row in
                        attentionRow(row)
                    }
                } header: {
                    SectionCount(title: "Needs you", count: parts.attention.count)
                }
            }
            if !parts.quiet.isEmpty {
                Section {
                    ForEach(parts.quiet) { row in
                        quietRow(row)
                    }
                } header: {
                    SectionCount(title: "Quiet", count: parts.quiet.count)
                }
            }
        }
    }

    /// Room around each row, so the list reads easily.
    static let insets = EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)

    private func quietRow(_ row: AgentRow) -> some View {
        AgentRowView(row: row, pinned: pins.isPinned(row), open: { open(row) }, openID: "quietAgent")
            .listRowInsets(Self.insets)
            .swipeActions(edge: .trailing) { muteButton(row) }
            .swipeActions(edge: .leading) { pinButton(row) }
            .contextMenu { pinButton(row); muteButton(row); historyButton(row) }
    }

    private func attentionRow(_ row: AgentRow) -> some View {
        let connection = connections.existing(row.machineID)
        return VStack(alignment: .leading, spacing: 8) {
            AgentRowView(row: row, pinned: pins.isPinned(row), open: { open(row) }, openID: "needsYouAgent")
            if let connection {
                PermissionButtons(row: row, connection: connection)
            }
        }
        .listRowInsets(Self.insets)
        .swipeActions(edge: .trailing) {
            Button { resolve(row) } label: { Label("Resolve", systemImage: "checkmark") }
                .tint(.green)
            muteButton(row)
        }
        .swipeActions(edge: .leading) {
            pinButton(row)
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
            pinButton(row)
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

    /// Pin keeps the agent in its own section at the top (on this phone only); Unpin puts it back.
    private func pinButton(_ row: AgentRow) -> some View {
        let pinned = pins.isPinned(row)
        return Button { pins.toggle(row) } label: {
            Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin")
        }
        .tint(.orange)
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

/// One agent, as in a mail inbox: where it is, what it said, and who it is with how long ago.
///
///     Platform › api-server
///     Ran the tests; two failures in push.rs. Wants
///     to know whether to fix them now.
///     devbox · Claude · 4m
///
/// The sections say whether it needs the user, so the row doesn't repeat a status; only an error says so, in
/// red. A muted agent has a crossed-out bell in its caption (Mute and Unmute are in the swipe and the menu).
/// Quiet rows are dimmer, with one line of summary.
struct AgentRowView: View {
    let row: AgentRow
    /// Pinned on this phone (AgentPins): a pin in the caption.
    var pinned = false
    /// Opens the agent's pane; nil shows the row on its own (the quick reply sheet's header).
    var open: (() -> Void)? = nil
    var openID: String? = nil

    private var needsYou: Bool { row.wantsAttention }

    var body: some View {
        if let open {
            Button(action: open) { content }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier(openID ?? "agentRow")
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(row.workspace) › \(row.title)")
                .font(.body.weight(needsYou ? .semibold : .medium))
                .foregroundStyle(needsYou ? .primary : .secondary)
                .lineLimit(1).truncationMode(.middle)
            if let summary = row.summary {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(needsYou ? .secondary : .tertiary)
                    .lineLimit(needsYou ? 2 : 1)
            }
            HStack(spacing: 4) {
                Text("\(row.machineName) · \(row.info.shortKindName)")
                if let since = row.info.sinceDate {
                    // Compact, as on the Mac ("1m", "2h"), updated each minute.
                    TimelineView(.everyMinute) { context in
                        Text("· " + AgentRowView.age(since, now: context.date)).monospacedDigit()
                    }
                }
                if row.info.state == .error {
                    Text("· Error").foregroundStyle(.red).fontWeight(.medium)
                }
                if pinned {
                    Image(systemName: "pin.fill").imageScale(.small).foregroundStyle(Color.accentColor)
                }
                if row.isMuted {
                    Image(systemName: "bell.slash").imageScale(.small)
                }
            }
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// What VoiceOver (and the UI tests) read: the lines, then the status and "Muted".
    private var accessibilityText: String {
        var parts = ["\(row.workspace) › \(row.title)"]
        if let summary = row.summary { parts.append(summary) }
        parts.append("\(row.machineName) · \(row.info.shortKindName) · \(row.status)")
        if pinned { parts.append("Pinned") }
        if row.isMuted { parts.append("Muted") }
        return parts.joined(separator: ", ")
    }
}

/// "Needs you  6": a section's name and how many agents are in it.
private struct SectionCount: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.footnote.weight(.semibold))
        .textCase(nil)
        .padding(.top, 10)
        .padding(.bottom, 2)
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
                Button { answer(request, .allow) } label: { Label("Allow", systemImage: "checkmark") }
                    .buttonStyle(Pill(fill: .green, text: .white))
                    .accessibilityIdentifier("allowRequest")
                Button(role: .destructive) { answer(request, .deny) } label: { Label("Deny", systemImage: "xmark") }
                    .buttonStyle(Pill(fill: Color(.tertiarySystemFill), text: .red))
                    .accessibilityIdentifier("denyRequest")
                if row.info.pendingRequests.count > 1 {
                    Text("+\(row.info.pendingRequests.count - 1)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityLabel("\(row.info.pendingRequests.count - 1) more waiting after this one")
                }
            }
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

/// A small capsule button (Allow, Deny): smaller than the system's smallest bordered button.
private struct Pill: ButtonStyle {
    let fill: Color
    let text: Color
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(PillLabel())
            .font(.caption.weight(.semibold))
            .foregroundStyle(text)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(fill, in: Capsule())
            .opacity(configuration.isPressed || !enabled ? 0.6 : 1)
            .contentShape(Capsule())
    }
}

private struct PillLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}
