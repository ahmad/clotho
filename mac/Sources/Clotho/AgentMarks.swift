import AppKit
import ClothoKit
import QuartzCore

// The one state every surface shows for an agent: the sidebar's inbox, a workspace row, a tab, the pane
// header, the ask bar and the command bar all draw from AgentMark, so they can't disagree about whether
// an agent needs the user, failed, finished or is working.

/// What an agent is to the user right now. An agent with nothing to show (idle, resolved, settling, or
/// muted and not running) has no mark.
enum AgentMark: Equatable, CaseIterable {
    /// It waits for the user: a permission request, a question, a bell.
    case needsYou
    /// Its turn failed.
    case error
    /// Its turn finished and nobody has looked yet.
    case done
    /// It's running.
    case working

    var color: NSColor {
        switch self {
        case .needsYou: return Theme.caution
        case .error: return Theme.danger
        case .done: return Theme.success
        case .working: return Theme.accent
        }
    }

    /// The colour's palette value, for the tint and for contrast checks.
    func hex(for appearance: ClothoPalette.Appearance) -> UInt32 {
        let palette = ClothoPalette.for(appearance)
        switch self {
        case .needsYou: return palette.ansi[3]
        case .error: return palette.ansi[1]
        case .done: return palette.ansi[2]
        case .working: return palette.accent
        }
    }

    var label: String {
        switch self {
        case .needsYou: return "Needs you"
        case .error: return "Error"
        case .done: return "Done"
        case .working: return "Working"
        }
    }

    /// How much of the mark's colour a chip's background takes, over whatever is behind it. Chip text is
    /// `Theme.foreground`, which stays above 4.5:1 on these over the chrome and over a pane (AgentMarkTests).
    static func tintAlpha(for appearance: ClothoPalette.Appearance) -> CGFloat {
        appearance == .dark ? 0.22 : 0.18
    }

    /// A chip's background in one appearance.
    func tint(for appearance: ClothoPalette.Appearance) -> NSColor {
        NSColor(hex: hex(for: appearance)).withAlphaComponent(Self.tintAlpha(for: appearance))
    }

    /// A chip's background, following the appearance it's drawn in.
    var tint: NSColor {
        NSColor(name: nil) { [self] in tint(for: $0.isDark ? .dark : .light) }
    }

    /// "waiting 2 min" for an agent that needs the user, "6 min" for one that's working, nothing for the
    /// rest (and when the daemon gave no time).
    func elapsedText(since: Double?, now: Date = Date()) -> String {
        guard let since, self == .needsYou || self == .working else { return "" }
        let seconds = max(0, Int(now.timeIntervalSince1970 - since))
        let time: String
        switch seconds {
        case ..<60: time = "<1 min"
        case ..<3600: time = "\(seconds / 60) min"
        case ..<86400: time = "\(seconds / 3600) h"
        default: time = "\(seconds / 86400) d"
        }
        return self == .needsYou ? "waiting \(time)" : time
    }

    /// The most urgent mark among some agents (by `AgentInfo.urgency`) and how many of them carry it; nil
    /// when none has a mark.
    static func summary(of agents: [AgentInfo]) -> AgentMarkCount? {
        let marked = agents.compactMap { info in info.mark.map { (mark: $0, urgency: info.urgency) } }
        guard let first = marked.min(by: { ($0.urgency, $0.mark.order) < ($1.urgency, $1.mark.order) }) else { return nil }
        return AgentMarkCount(mark: first.mark, count: marked.filter { $0.mark == first.mark }.count)
    }

    /// Between agents of the same urgency.
    private var order: Int { Self.allCases.firstIndex(of: self)! }
}

/// A place's mark (a workspace's, a tab's): its most urgent agent's, and how many of its agents carry it.
struct AgentMarkCount: Equatable {
    var mark: AgentMark
    var count: Int
}

extension AgentInfo {
    /// The agent's mark. Anything whose attention is raised shows, so nothing that wants the user
    /// disappears: a failed turn as Error, a finished turn that asks nothing as Done, and the rest (a
    /// wait, a finished turn that asks, a bell while it runs) as Needs you. With no attention only a
    /// running or starting agent has one.
    var mark: AgentMark? {
        if needsAttention {
            if state == .error { return .error }
            return state != .done || asksUser ? .needsYou : .done
        }
        return state == .running || state == .starting ? .working : nil
    }

    /// The agent's line in the inbox: the request it waits on ("Allow Bash: npm test"), else what it asks
    /// or last said, on one line. Nil when it said nothing.
    var inboxText: String? {
        pendingRequests.first?.askText ?? headline
    }
}

extension PermissionRequest {
    /// "Allow Bash: npm test": the question without its "?", for a row or a button beside Allow and Deny.
    var askText: String { String(question.dropLast()) }
}

/// The sidebar's inbox: every agent with a mark, in three sections.
enum AgentInbox {
    /// Needs you holds the agents that wait and the ones that failed, the longest wait first (one with no
    /// time last). Done and Working have the most recent first. Agents with no mark are in none.
    static func sections(_ entries: [AgentEntry]) -> (needsYou: [AgentEntry], done: [AgentEntry], working: [AgentEntry]) {
        func recent(_ mark: AgentMark) -> [AgentEntry] {
            entries.filter { $0.info.mark == mark }.sorted { ($0.info.since ?? 0) > ($1.info.since ?? 0) }
        }
        let needsYou = entries.filter { $0.info.mark == .needsYou || $0.info.mark == .error }
            .sorted { ($0.info.since ?? .infinity) < ($1.info.since ?? .infinity) }
        return (needsYou, recent(.done), recent(.working))
    }
}

extension AppDelegate {
    /// The most urgent agent mark for a workspace's or a tab's panes on a machine, and how many of their
    /// agents carry it. Nil when no agent there has a mark, or the machine's agents aren't watched.
    func agentMark(machine: MachineKey, panes: [PaneID]) -> AgentMarkCount? {
        guard monitorsAgents(machine), let state = connections[machine]?.store.state else { return nil }
        return AgentMark.summary(of: panes.compactMap { state.pane($0)?.agent })
    }
}

/// An agent's mark, 8 pt: a dot in the mark's colour, or for a working agent a three-quarter ring that
/// turns. The turn's phase comes from the clock, so every ring is in step, including one in a row that
/// was just rebuilt. Under Reduce Motion, and outside a window, the ring stands still.
final class AgentMarkView: NSView {
    static var side: CGFloat { s(8) }
    /// One turn of the ring, in seconds.
    static let period: CFTimeInterval = 1
    /// Tests set this; otherwise the system's Reduce Motion.
    static var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var mark: AgentMark {
        didSet { if mark != oldValue { apply() } }
    }

    private let shape = CAShapeLayer()
    private static let spinKey = "spin"

    init(_ mark: AgentMark) {
        self.mark = mark
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        wantsLayer = true
        layer?.addSublayer(shape)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(motionChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        apply()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    /// Whether the ring is turning now.
    var isSpinning: Bool { shape.animation(forKey: Self.spinKey) != nil }

    override func layout() {
        super.layout()
        apply()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSpin()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply()
    }

    @objc private func motionChanged() { updateSpin() }

    private func apply() {
        setAccessibilityLabel(mark.label)
        let side = min(bounds.width, bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        shape.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let color = resolved(mark.color)
        if mark == .working {
            let width = s(1.5)
            let path = CGMutablePath()
            path.addArc(center: CGPoint(x: side / 2, y: side / 2), radius: max(0, (side - width) / 2),
                        startAngle: 0, endAngle: .pi * 1.5, clockwise: false)
            shape.path = path
            shape.lineWidth = width
            shape.lineCap = .round
            shape.strokeColor = color
            shape.fillColor = nil
        } else {
            shape.path = CGPath(ellipseIn: shape.bounds, transform: nil)
            shape.lineWidth = 0
            shape.strokeColor = nil
            shape.fillColor = color
        }
        CATransaction.commit()
        updateSpin()
    }

    private func resolved(_ color: NSColor) -> CGColor {
        var result = color.cgColor
        withAppearance { result = color.cgColor }
        return result
    }

    private func updateSpin() {
        let spins = mark == .working && window != nil && !Self.reducesMotion()
        guard spins != isSpinning else { return }
        guard spins else { return shape.removeAnimation(forKey: Self.spinKey) }
        // Clockwise, from where the clock says every ring is now.
        let phase = CACurrentMediaTime().truncatingRemainder(dividingBy: Self.period) / Self.period
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = -2 * Double.pi * phase
        spin.toValue = -2 * Double.pi * (phase + 1)
        spin.duration = Self.period
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        shape.add(spin, forKey: Self.spinKey)
    }
}

/// A place's agents in one chip, for workspace rows and the pane header: how many carry its most urgent
/// mark, on that mark's tint. Finished agents show a check instead of a number.
final class AgentChip: NSView {
    enum Content: Equatable {
        case count(Int)
        case check
    }

    /// What the chip says: a check for Done, else the number of agents.
    static func content(_ value: AgentMarkCount) -> Content {
        value.mark == .done ? .check : .count(value.count)
    }

    /// "Needs you", or "Needs you: 3 agents".
    static func description(_ value: AgentMarkCount) -> String {
        value.count > 1 ? "\(value.mark.label): \(value.count) agents" : value.mark.label
    }

    static var height: CGFloat { s(16) }

    var value: AgentMarkCount {
        didSet { if value != oldValue { apply() } }
    }

    let label = NSTextField(labelWithString: "")
    let check = NSImageView()

    init(_ value: AgentMarkCount) {
        self.value = value
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.monospacedDigitSystemFont(ofSize: s(10.5), weight: .semibold)
        label.textColor = Theme.foreground
        label.alignment = .center
        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: s(8.5), weight: .bold))
        check.contentTintColor = Theme.foreground
        for view in [label, check] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: centerXAnchor),
                view.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        apply()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A circle for one digit or the check, a pill for more.
    override var intrinsicContentSize: NSSize {
        let inner = label.isHidden ? 0 : label.intrinsicContentSize.width
        return NSSize(width: max(Self.height, (inner + s(10)).rounded(.up)), height: Self.height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }

    private func apply() {
        switch Self.content(value) {
        case .count(let count):
            label.stringValue = "\(count)"
            (label.isHidden, check.isHidden) = (false, true)
        case .check:
            (label.isHidden, check.isHidden) = (true, false)
        }
        layer?.cornerRadius = Self.height / 2
        applyTint()
        setAccessibilityLabel(Self.description(value))
        toolTip = Self.description(value)
        invalidateIntrinsicContentSize()
    }

    private func applyTint() {
        withAppearance { layer?.backgroundColor = value.mark.tint.cgColor }
    }
}
