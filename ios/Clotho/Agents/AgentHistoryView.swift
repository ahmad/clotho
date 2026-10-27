import ClothoKit
import SwiftUI

/// One pane's agent history (protocol.md "Agent history"): what it did and asked, newest first. The machine
/// keeps the last 200 entries per pane across restarts. New entries arrive while the sheet is open.
struct AgentHistoryView: View {
    @ObservedObject var connection: MachineConnection
    @ObservedObject private var store: ModelStore
    let pane: PaneID
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [AgentHistoryEntry] = []
    @State private var loaded = false
    @State private var error: String?

    init(connection: MachineConnection, pane: PaneID) {
        self.connection = connection
        store = connection.store
        self.pane = pane
    }

    private var supported: Bool { store.hello?.features.contains(.agentHistory) == true }
    private var title: String {
        store.state.location(of: pane).map { store.displayTitle(of: $0.tab) } ?? "Agent"
    }

    var body: some View {
        NavigationStack {
            List {
                if !supported {
                    Text("Update clothod on \(connection.machine.displayName) to see agent history.").foregroundStyle(.secondary)
                } else if let error {
                    Text(error).foregroundStyle(.orange)
                } else if loaded && entries.isEmpty {
                    ContentUnavailableView("No history yet", systemImage: "clock",
                                           description: Text("Changes show here once an agent runs in this pane."))
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(Array(entries.enumerated().reversed()), id: \.offset) { _, entry in
                        AgentHistoryRow(entry: entry)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .refreshable { await load(all: true) }
        }
        .task(id: store.hello?.instance) { await load(all: true) }
        // Each agent change on this pane adds an entry there.
        .onChange(of: store.state.pane(pane)?.agent) { Task { await load(all: false) } }
    }

    private func load(all: Bool) async {
        guard supported else { return }
        do {
            let since = all ? nil : entries.last?.at
            let history = try await store.backend.agentHistory(pane, limit: nil, since: since)
            entries = since == nil ? history.entries : entries + history.entries
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }
}

struct AgentHistoryRow: View {
    let entry: AgentHistoryEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Self.symbol(entry))
                .foregroundStyle(Self.tint(entry))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(Self.headline(entry)).font(.subheadline.weight(.medium))
                    Spacer()
                    Text(entry.date, format: .dateTime.hour().minute().second())
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let message = entry.message, !message.isEmpty {
                    Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let detail = Self.detail(entry) {
                    Text(detail).font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func headline(_ entry: AgentHistoryEntry) -> String {
        let kind = entry.kind.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Agent"
        switch entry.event {
        case .state, .update:
            let state = entry.state?.rawValue.capitalized ?? "Unknown"
            if let from = entry.from, from != entry.state { return "\(kind): \(from.rawValue.capitalized) → \(state)" }
            return "\(kind): \(state)"
        case .attention: return entry.attention == false ? "Resolved" : "Needs you"
        case .mute: return "Muted"
        case .unmute: return "Unmuted"
        case .gone: return "\(kind) exited"
        case .unknown: return entry.eventName
        }
    }

    static func detail(_ entry: AgentHistoryEntry) -> String? {
        var parts: [String] = []
        if entry.guess == true { parts.append("detected from output") }
        if let source = entry.source, !source.isEmpty { parts.append(source) }
        if let pid = entry.pid { parts.append("pid \(pid)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func symbol(_ entry: AgentHistoryEntry) -> String {
        switch entry.event {
        case .attention: return entry.attention == false ? "checkmark.circle" : "bell.badge"
        case .mute: return "bell.slash"
        case .unmute: return "bell"
        case .gone: return "xmark.circle"
        default:
            switch entry.state {
            case .waiting?: return "hand.raised"
            case .done?: return "checkmark.seal"
            case .error?: return "exclamationmark.triangle"
            case .running?: return "play.circle"
            default: return "circle"
            }
        }
    }

    static func tint(_ entry: AgentHistoryEntry) -> Color {
        switch (entry.event, entry.state) {
        case (.attention, _) where entry.attention != false: return .orange
        case (_, .error?): return .red
        case (_, .waiting?): return .orange
        default: return .selection
        }
    }
}
