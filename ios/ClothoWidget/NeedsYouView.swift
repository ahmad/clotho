import ClothoKit
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
    /// Every number counts only the agents that need the user; plain Done agents list after them.
    private var count: Int { entry.summary.needingYou }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Text("\(count)").font(.title2.weight(.semibold))
                    Image(systemName: "hand.raised").font(.caption2)
                }
            }
            .widgetURL(URL(string: "clotho://home"))
        case .accessoryRectangular:
            if let first = agents.first {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.heading(count)).font(.headline)
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
                    Text("\(count)").font(.headline.monospacedDigit()).foregroundStyle(count == 0 ? .secondary : Color.orange)
                }
                if agents.isEmpty {
                    Spacer()
                    Text("No agents need you.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ForEach(agents.prefix(family == .systemSmall ? 2 : 3)) { agent in
                        Link(destination: Self.url(agent)) {
                            // Plain text colours: a Link would otherwise take the tint.
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                // The kind's symbol; the line beside it already says the name.
                                Image(systemName: Self.symbol(agent)).font(.caption).foregroundStyle(.secondary)
                                    .frame(width: 16).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(Self.what(agent)).font(.caption.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                                    Text(Self.where(agent, at: entry.date)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
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

    /// "1 needs you", "3 need you"; "No agents need you" when only plain Done agents are listed.
    static func heading(_ count: Int) -> String {
        count == 0 ? "No agents need you" : "\(count) need\(count == 1 ? "s" : "") you"
    }

    /// "Claude needs you", "Claude is done"; without `needsUser` (an older daemon, app or extension) by the
    /// state: "Claude is waiting", "Claude finished", "Claude hit an error". ClothoKit's wording.
    static func what(_ agent: AgentsSummary.Agent) -> String {
        let state = AgentInfo.State(rawValue: agent.state) ?? .unknown
        return "\(AgentInfo.shortName(ofKind: agent.kind)) \(state.alertVerb(needsUser: agent.needsUser))"
    }

    /// The kind's SF Symbol, from ClothoKit's table: a fixed name per known kind and the generic one for
    /// every other, never a name made from the kind's text.
    static func symbol(_ agent: AgentsSummary.Agent) -> String { AgentKind.of(agent.kind).symbolName }

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
