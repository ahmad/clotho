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
            NeedsYouFamilyView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Needs you")
        .description("Agents waiting for you, on every machine.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
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


/// Reads the widget's family and passes it on.
struct NeedsYouFamilyView: View {
    var entry: NeedsYouEntry
    @Environment(\.widgetFamily) private var family

    var body: some View { NeedsYouView(entry: entry, family: family) }
}
