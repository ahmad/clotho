import SwiftUI
import WidgetKit
// Compiled into the tests too, to render the widget's sizes (where AgentsSummary comes from the app).
#if WIDGET_PREVIEW_TEST
@testable import Clotho
#endif

/// One entry of the "Needs you" widget's timeline.
struct NeedsYouEntry: TimelineEntry {
    var date: Date
    var summary: AgentsSummary
}

/// The widget's content for one size. Takes the family as a value, so tests can render every size.
struct NeedsYouView: View {
    var entry: NeedsYouEntry
    var family: WidgetFamily

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
                    Text(Self.what(first)).font(.caption).lineLimit(1)
                    Text(Self.where(first, at: entry.date)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
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
                            // Plain text colours: a Link would otherwise take the tint.
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Self.what(agent)).font(.caption.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                                Text(Self.where(agent, at: entry.date)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .tint(Color.primary)
                    }
                    Spacer(minLength: 0)
                }
            }
            .widgetURL(URL(string: "clotho://home"))
        }
    }

    /// "Platform · devbox · 2m": where it is and how long it has waited.
    static func `where`(_ agent: AgentsSummary.Agent, at date: Date) -> String {
        [agent.workspace, agent.machineName, age(agent, at: date)].compactMap { $0 }.joined(separator: " · ")
    }

    /// "Claude is waiting".
    static func what(_ agent: AgentsSummary.Agent) -> String {
        let name = agent.kind.prefix(1).uppercased() + agent.kind.dropFirst()
        let what: String
        switch agent.state {
        case "waiting": what = "\(name) is waiting"
        case "error": what = "\(name) hit an error"
        default: what = "\(name) finished"
        }
        return what
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
