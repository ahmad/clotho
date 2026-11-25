import ClothoKit
import SwiftUI

/// A pane's progress (clothod 0.1.33's `pane.progress`: OSC 9;4 and OSC 7501) as a thin bar, as on the Mac
/// (`ProgressBarView`): under the pane screen's navigation bar for the Tab, on a pane's chip in the pane strip,
/// and on the Tab's row in the machine's list and the iPad's sidebar. It is only drawn: it never alerts, badges
/// or notifies, it carries no text, and it is never in the way of a touch.
///
/// With a percent the fill is that share of the width; without one (indeterminate, or a state that gave none) a
/// segment slides across, and under Reduce Motion the whole width shows still and dimmer instead.
struct ProgressStrip: View {
    /// Nil only for a reserved slot (`init(reserving:)`), which then draws nothing at the strip's height.
    let progress: PaneProgress?

    @ScaledMetric(relativeTo: .caption) private var scaledHeight: CGFloat = ProgressStrip.baseHeight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The track's height at the default text size, and the most it grows to with larger text.
    static let baseHeight: CGFloat = 2
    static let maxHeight: CGFloat = 4
    /// The sliding segment's share of the width, and one pass in seconds.
    static let segmentShare: CGFloat = 0.3
    static let period: TimeInterval = 1.4
    /// The still bar's opacity when nothing may move.
    static let stillOpacity: Double = 0.45

    init(progress: PaneProgress) {
        self.progress = progress
    }

    /// The strip's room whether or not there is progress, so progress coming and going never resizes what
    /// is under it (the pane screen: a terminal that changed height would resize its pane).
    init(reserving progress: PaneProgress?) {
        self.progress = progress
    }

    // MARK: What it shows (pure, for tests)

    /// The fill's share of the width, 0 to 1; nil when there is no percent.
    static func fillFraction(_ progress: PaneProgress) -> Double? {
        progress.fraction.map { min(max($0, 0), 1) }
    }

    /// Whether the bar has no percent to show.
    static func isIndeterminate(_ progress: PaneProgress) -> Bool {
        fillFraction(progress) == nil
    }

    /// The fill's colour: the accent while it runs, red for an error, orange when paused. System colours, so
    /// light and dark both work.
    static func tint(for state: PaneProgress.State) -> Color {
        switch state {
        case .running, .indeterminate: return .accentColor
        case .error: return .red
        case .paused: return .orange
        }
    }

    /// "40 percent", "55 percent, error", "in progress": what follows the label "Progress", so VoiceOver
    /// reads "Progress 40 percent" (as the Mac's `ProgressBarView.spokenValue`).
    static func spokenValue(_ progress: PaneProgress) -> String {
        let text = progress.spokenText
        for lead in ["Progress, ", "Progress "] where text.hasPrefix(lead) { return String(text.dropFirst(lead.count)) }
        return text
    }

    /// The sliding segment's leading edge at `time`, for a bar `width` wide: from fully off the leading edge
    /// to fully off the trailing one, once a `period`. From the clock, so every bar is in step.
    static func segmentOffset(at time: TimeInterval, width: CGFloat) -> CGFloat {
        let segment = width * segmentShare
        let phase = time.truncatingRemainder(dividingBy: period) / period
        return -segment + (width + segment) * CGFloat(phase)
    }

    // MARK: View

    private var height: CGFloat { min(max(scaledHeight, Self.baseHeight), Self.maxHeight) }

    var body: some View {
        if let progress {
            bar(progress)
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .clipped()
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityLabel("Progress")
                .accessibilityValue(Self.spokenValue(progress))
        } else {
            Color.clear
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func bar(_ progress: PaneProgress) -> some View {
        let tint = Self.tint(for: progress.state)
        return GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Color(.separator)
                if let fraction = Self.fillFraction(progress) {
                    tint.frame(width: (width * CGFloat(fraction)).rounded())
                } else if reduceMotion || width <= 0 {
                    tint.opacity(Self.stillOpacity)
                } else {
                    TimelineView(.animation) { timeline in
                        tint.frame(width: (width * Self.segmentShare).rounded())
                            .offset(x: Self.segmentOffset(at: timeline.date.timeIntervalSinceReferenceDate, width: width))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

extension ModelStore {
    /// Whether this machine's progress is drawn: its daemon has `pane.progress`, it is connected, and the
    /// model is the live one (a saved or stale model keeps the last progress it heard of, and a bar must not
    /// stand still for a machine that is gone).
    var showsProgress: Bool {
        Self.showsProgress(features: features, connected: isConnected, saved: isSaved)
    }

    /// The one progress a Tab shows: `PaneProgress.forTab` over its panes in layout order (the first error,
    /// else the first), as on the Mac. Nil when progress isn't drawn for this machine.
    func tabProgress(_ tab: ClothoKit.Tab) -> PaneProgress? {
        Self.tabProgress(tab, in: state, shows: showsProgress)
    }

    /// One pane's own progress, under the same gate.
    func paneProgress(_ id: PaneID) -> PaneProgress? {
        Self.paneProgress(id, in: state, shows: showsProgress)
    }

    nonisolated static func showsProgress(features: Set<Hello.Feature>, connected: Bool, saved: Bool) -> Bool {
        features.contains(.paneProgress) && connected && !saved
    }

    nonisolated static func tabProgress(_ tab: ClothoKit.Tab, in state: ModelState, shows: Bool) -> PaneProgress? {
        guard shows else { return nil }
        return PaneProgress.forTab(tab.layout.panes.compactMap { paneProgress($0, in: state, shows: shows) })
    }

    /// An exited pane's last progress isn't drawn (as on the Mac).
    nonisolated static func paneProgress(_ id: PaneID, in state: ModelState, shows: Bool) -> PaneProgress? {
        guard shows, let pane = state.pane(id), pane.exited == nil else { return nil }
        return pane.progress
    }
}
