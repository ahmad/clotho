import SwiftUI
import WidgetKit

/// "Needs you": the agents waiting for the user, on the home and lock screens (docs/ios-redesign.md, phase 6).
/// It reads the summary the app and the notification extension keep (AgentsSummary); nothing here connects
/// anywhere. A row opens its pane in the app; the rest of the widget opens Home.
@main
struct ClothoWidgets: WidgetBundle {
    var body: some Widget {
        NeedsYouWidget()
    }
}

struct NeedsYouWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NeedsYou", provider: NeedsYouProvider()) { entry in
            NeedsYouView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Needs you")
        .description("Agents waiting for you, on every machine.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

struct NeedsYouEntry: TimelineEntry {
    var date: Date
    var summary: AgentsSummary
}

struct NeedsYouProvider: TimelineProvider {
    func placeholder(in context: Context) -> NeedsYouEntry {
        NeedsYouEntry(date: Date(), summary: AgentsSummary(updated: 0, agents: [
            .init(machine: UUID(), machineName: "devbox", pane: 1, workspace: "Platform", kind: "claude", state: "waiting",
                  since: Date().timeIntervalSince1970 - 120),
        ]))
    }

    func getSnapshot(in context: Context, completion: @escaping (NeedsYouEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : NeedsYouEntry(date: Date(), summary: AgentsSummary.load()))
    }

    /// The app and the extension reload the timeline when the summary changes; until then the ages tick by
    /// the minute.
    func getTimeline(in context: Context, completion: @escaping (Timeline<NeedsYouEntry>) -> Void) {
        let summary = AgentsSummary.load()
        let now = Date()
        let entries = (0..<30).map { NeedsYouEntry(date: now.addingTimeInterval(Double($0) * 60), summary: summary) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct NeedsYouView: View {
    var entry: NeedsYouEntry
    @Environment(\.widgetFamily) private var family

    private var agents: [AgentsSummary.Agent] { entry.summary.agents }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Text("\(agents.count)").font(.title2.weight(.semibold))
                    Image(systemName: "hand.raised").font(.caption2)
                }
            }
            .widgetURL(URL(string: "clotho://home"))
        case .accessoryRectangular:
            if let first = agents.first {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(agents.count) need\(agents.count == 1 ? "s" : "") you").font(.headline)
                    Text(Self.line(first)).font(.caption).lineLimit(1)
                    Text(Self.age(first, at: entry.date)).font(.caption2).foregroundStyle(.secondary)
                }
                .widgetURL(Self.url(first))
            } else {
                Text("No agents need you").font(.caption)
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Needs you").font(.headline)
                    Spacer()
                    Text("\(agents.count)").font(.headline.monospacedDigit()).foregroundStyle(agents.isEmpty ? .secondary : Color.orange)
                }
                if agents.isEmpty {
                    Spacer()
                    Text("No agents need you.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ForEach(agents.prefix(family == .systemSmall ? 2 : 3)) { agent in
                        Link(destination: Self.url(agent)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Self.line(agent)).font(.caption.weight(.medium)).lineLimit(1)
                                Text("\(agent.machineName) · \(Self.age(agent, at: entry.date))")
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .widgetURL(URL(string: "clotho://home"))
        }
    }

    /// "Claude is waiting · Platform".
    static func line(_ agent: AgentsSummary.Agent) -> String {
        let name = agent.kind.prefix(1).uppercased() + agent.kind.dropFirst()
        let what: String
        switch agent.state {
        case "waiting": what = "\(name) is waiting"
        case "error": what = "\(name) hit an error"
        default: what = "\(name) finished"
        }
        return [what, agent.workspace].compactMap { $0 }.joined(separator: " · ")
    }

    /// "now", "4m", "2h", "earlier" (older than 12 hours).
    static func age(_ agent: AgentsSummary.Agent, at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince1970 - agent.since))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60)m"
        case ..<43200: return "\(seconds / 3600)h"
        default: return "earlier"
        }
    }

    static func url(_ agent: AgentsSummary.Agent) -> URL {
        URL(string: "clotho://pane/\(agent.machine.uuidString)/\(agent.pane)")!
    }
}
