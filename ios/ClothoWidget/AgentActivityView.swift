#if LIVE_ACTIVITIES
import ActivityKit
import SwiftUI
import WidgetKit
// Compiled into the tests too, to render the lock screen (where the attributes come from the app).
#if WIDGET_PREVIEW_TEST
@testable import Clotho
#endif

/// The Live Activity for a followed agent: lock screen and Dynamic Island. Where the agent is and what it was
/// asked come from the phone (the attributes); what it's doing comes from the machine (the content state).
struct AgentActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            AgentActivityLockScreen(attributes: context.attributes, state: context.state)
                .widgetURL(Self.url(context.attributes))
        } dynamicIsland: { context in
            let state = context.state, attributes = context.attributes
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: state.symbol).font(.title2).foregroundStyle(activityTint(state))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ActivityTimer(state: state).font(.headline.monospacedDigit()).frame(width: 72, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.headline).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        if let place = attributes.place {
                            Text(place).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        ActivityDetail(attributes: attributes, state: state, lines: 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                HStack(spacing: 4) {
                    Image(systemName: state.symbol).foregroundStyle(activityTint(state))
                    if let tool = state.compactTool {
                        Text(tool).font(.caption2.weight(.semibold)).lineLimit(1).frame(maxWidth: 44, alignment: .leading)
                    }
                }
            } compactTrailing: {
                ActivityTimer(state: state).monospacedDigit().frame(width: 44, alignment: .trailing)
            } minimal: {
                Image(systemName: state.symbol).foregroundStyle(activityTint(state))
            }
            .widgetURL(Self.url(attributes))
        }
    }

    static func url(_ attributes: AgentActivityAttributes) -> URL? {
        URL(string: "clotho://pane/\(attributes.machine.uuidString)/\(attributes.pane)")
    }
}

/// The lock-screen banner: where, what the agent is doing (and on what), its last word, and for how long.
struct AgentActivityLockScreen: View {
    var attributes: AgentActivityAttributes
    var state: AgentActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: state.symbol).foregroundStyle(activityTint(state))
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.headline).font(.headline).lineLimit(1)
                    Text(attributes.place ?? "Clotho").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ActivityTimer(state: state).font(.title3.monospacedDigit()).frame(width: 84, alignment: .trailing)
            }
            ActivityDetail(attributes: attributes, state: state, lines: 3)
        }
        .padding()
    }
}

/// The command or file in mono, then the last message or question, or else the prompt the turn began with.
struct ActivityDetail: View {
    var attributes: AgentActivityAttributes
    var state: AgentActivityAttributes.ContentState
    var lines: Int

    var body: some View {
        if let detail = state.detailLine {
            Text(detail).font(.caption.monospaced()).lineLimit(2).truncationMode(.middle)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
        }
        if let message = state.messageLine {
            Text(message).font(.callout).lineLimit(lines)
        } else if state.detailLine == nil, let prompt = attributes.prompt {
            Text("“\(prompt)”").font(.callout).foregroundStyle(.secondary).lineLimit(lines)
        }
    }
}

/// A running clock while the turn goes on; the final length once it's over. A timer Text takes all the width
/// it's offered and centres in it, so it's right-aligned here and given a fixed width by the caller.
struct ActivityTimer: View {
    var state: AgentActivityAttributes.ContentState

    var body: some View {
        Group {
            if state.isOver {
                let seconds = max(0, state.since - state.started)
                Text(Duration.seconds(seconds), format: .time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
            } else {
                Text(timerInterval: state.startedDate...Date.distantFuture, countsDown: false)
            }
        }
        .multilineTextAlignment(.trailing)
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
