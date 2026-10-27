import AppKit

/// The app's zoom: one factor (View › Zoom In / Zoom Out / Actual Size) that scales every chrome font and
/// metric (sidebar, Agents panel, tab bar, notices, toasts, Settings) and the terminal font together.
/// Chrome sizes are written as `s(points at 100%)`, so layouts stay proportional at any zoom.
enum UIScale {
    static let range: ClosedRange<CGFloat> = 0.8...1.6
    static let step: CGFloat = 0.1
    static let defaultsKey = "UIScale"
    static let didChange = Notification.Name("ClothoUIScaleDidChange")

    /// The current factor. Set it through `AppDelegate.setUIScale`, which also rebuilds the chrome.
    nonisolated(unsafe) static var factor: CGFloat = load()

    /// Snapped to the 0.1 grid and kept in range.
    static func clamp(_ value: CGFloat) -> CGFloat {
        let snapped = (value / step).rounded() * step
        return min(max((snapped * 100).rounded() / 100, range.lowerBound), range.upperBound)
    }

    /// `steps` notches up (positive) or down from `value`.
    static func next(_ value: CGFloat, steps: Int) -> CGFloat { clamp(value + CGFloat(steps) * step) }

    static func load(_ defaults: UserDefaults = .standard) -> CGFloat {
        let saved = CGFloat(defaults.double(forKey: defaultsKey))
        return saved > 0 ? clamp(saved) : 1
    }

    static func save(_ value: CGFloat, _ defaults: UserDefaults = .standard) {
        defaults.set(Double(clamp(value)), forKey: defaultsKey)
    }
}

/// A chrome size at the current zoom: `points` at 100%.
func s(_ points: CGFloat) -> CGFloat { points * UIScale.factor }
