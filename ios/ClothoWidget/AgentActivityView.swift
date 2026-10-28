#if LIVE_ACTIVITIES
import ActivityKit
import SwiftUI
import WidgetKit

/// The Live Activity for a followed agent: lock screen and Dynamic Island. State, kind and elapsed time only.
struct AgentActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            AgentActivityLockScreen(state: context.state)
                .widgetURL(URL(string: "clotho://pane/\(context.attributes.machine.uuidString)/\(context.attributes.pane)"))
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(state.name, systemImage: state.symbol).font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    activityElapsed(state).font(.headline.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("\(state.name) \(state.verb)").font(.callout).foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: state.symbol).foregroundStyle(activityTint(state))
            } compactTrailing: {
                activityElapsed(state).monospacedDigit().frame(maxWidth: 52)
            } minimal: {
                Image(systemName: state.symbol).foregroundStyle(activityTint(state))
            }
            .widgetURL(URL(string: "clotho://pane/\(context.attributes.machine.uuidString)/\(context.attributes.pane)"))
        }
    }
}

/// The lock-screen banner: what the agent is doing and for how long.
struct AgentActivityLockScreen: View {
    var state: AgentActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state.symbol).font(.title2).foregroundStyle(activityTint(state))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(state.name) \(state.verb)").font(.headline)
                Text("Clotho").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            activityElapsed(state).font(.title3.monospacedDigit())
        }
        .padding()
    }
}

/// A running clock while the turn goes on; the final length once it's over.
@ViewBuilder
func activityElapsed(_ state: AgentActivityAttributes.ContentState) -> some View {
    if state.isOver {
        let seconds = max(0, state.since - state.started)
        Text(Duration.seconds(seconds), format: .time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    } else {
        Text(timerInterval: state.startedDate...Date.distantFuture, countsDown: false)
    }
}

func activityTint(_ state: AgentActivityAttributes.ContentState) -> Color {
    switch state.state {
    case "waiting": return .orange
    case "error": return .red
    case "done": return .green
    default: return .blue
    }
}
#endif
