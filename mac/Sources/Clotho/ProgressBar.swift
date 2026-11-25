import AppKit
import ClothoKit
import QuartzCore

// A pane's progress (clothod 0.1.33's `pane.progress`: OSC 9;4 and OSC 7501) as a thin bar: on the pane's
// Tab, along the pane header's bottom edge, and on the agent's sidebar row and Overview card when the pane
// has an agent. It is only drawn: it never alerts, badges or notifies, and it carries no text.
//
// Progress arrives up to once a second per pane, so a bar is updated in place (`progress = …`), never by
// rebuilding the view it sits on.

extension PaneProgress.State {
    /// The bar's colour: the accent while it runs, the palette's red for an error, its amber when paused.
    var barColor: NSColor {
        switch self {
        case .running, .indeterminate: return Theme.accent
        case .error: return Theme.danger
        case .paused: return Theme.caution
        }
    }

    /// The colour's palette value, for tests.
    func barHex(for appearance: ClothoPalette.Appearance) -> UInt32 {
        let palette = ClothoPalette.for(appearance)
        switch self {
        case .running, .indeterminate: return palette.accent
        case .error: return palette.ansi[1]
        case .paused: return palette.ansi[3]
        }
    }
}

/// The bar. Hidden with no progress. With a percent the fill is that share of the width; without one
/// (indeterminate, or a state that gave none) a segment slides across, and under Reduce Motion, or outside
/// a window, the whole width shows still and dimmer instead.
final class ProgressBarView: NSView {
    static var height: CGFloat { s(2) }
    /// The sliding segment's share of the width, and one pass in seconds.
    static let segmentShare: CGFloat = 0.3
    static let period: CFTimeInterval = 1.4
    /// The still bar's opacity when nothing may move.
    static let stillOpacity: Float = 0.45

    var progress: PaneProgress? {
        didSet { if progress != oldValue { apply() } }
    }

    private let track = CALayer()
    private let fill = CALayer()
    private static let slideKey = "slide"

    init(_ progress: PaneProgress? = nil) {
        self.progress = progress
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Progress")
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(motionChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        apply()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }
    // Never in the way of a click on what it sits over.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Whether the segment is sliding now.
    var isSliding: Bool { fill.animation(forKey: Self.slideKey) != nil }
    /// The fill, in the bar's coordinates (for tests).
    var fillFrame: CGRect { fill.frame }
    var fillOpacity: Float { fill.opacity }
    /// Whether the bar has no percent to show.
    var isIndeterminate: Bool { progress != nil && progress?.fraction == nil }

    /// "40 percent", "55 percent, error", "in progress": what follows the label "Progress", so VoiceOver
    /// reads "Progress 40 percent".
    static func spokenValue(_ progress: PaneProgress) -> String {
        let text = progress.spokenText
        for lead in ["Progress, ", "Progress "] where text.hasPrefix(lead) { return String(text.dropFirst(lead.count)) }
        return text
    }

    override func layout() {
        super.layout()
        apply()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply()
    }

    @objc private func motionChanged() { apply() }

    private func apply() {
        isHidden = progress == nil
        guard let progress else {
            fill.removeAnimation(forKey: Self.slideKey)
            setAccessibilityValue(nil)
            return
        }
        setAccessibilityValue(Self.spokenValue(progress))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        withAppearance {
            track.backgroundColor = Theme.divider.cgColor
            fill.backgroundColor = progress.state.barColor.cgColor
        }
        let slides: Bool
        if let fraction = progress.fraction {
            fill.frame = CGRect(x: 0, y: 0, width: (bounds.width * CGFloat(fraction)).rounded(), height: bounds.height)
            fill.opacity = 1
            slides = false
        } else if window == nil || AgentMarkView.reducesMotion() || bounds.width <= 0 {
            fill.frame = bounds
            fill.opacity = Self.stillOpacity
            slides = false
        } else {
            fill.frame = CGRect(x: 0, y: 0, width: (bounds.width * Self.segmentShare).rounded(), height: bounds.height)
            fill.opacity = 1
            slides = true
        }
        CATransaction.commit()
        guard slides else { return fill.removeAnimation(forKey: Self.slideKey) }
        // Again on every pass through here: the width may have changed.
        let slide = CABasicAnimation(keyPath: "position.x")
        let half = fill.bounds.width / 2
        slide.fromValue = -half
        slide.toValue = bounds.width + half
        slide.duration = Self.period
        slide.repeatCount = .infinity
        slide.isRemovedOnCompletion = false
        // In step with every other bar, from the clock.
        slide.timeOffset = CACurrentMediaTime().truncatingRemainder(dividingBy: Self.period)
        fill.add(slide, forKey: Self.slideKey)
    }
}
