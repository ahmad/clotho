import AppKit
import ClothoKit

// Every pane has a thin header across its top: on the left what runs in it (an agent's chip, "Claude ·
// Needs you", with how long it has waited or worked; else the program's name), on the right the pane's
// folder. The header's height is the same for every pane, so nothing about an agent's state ever resizes a
// shell. The pane's × sits at its trailing end on hover (PaneClose.swift), in room the folder never takes.

/// What a pane's header, outline and ask bar show, from the model on every sync.
struct PaneChrome: Equatable {
    /// The pane's agent, when its machine's agents are watched.
    var agent: AgentInfo?
    /// The pane's spawn command.
    var command: [String]?
    var cwd: String?
    /// The machine's home folder, when it said.
    var home: String?
    /// Whether the machine's daemon answers permission requests (`agent.decide`).
    var canDecide = false
    /// How far the pane's program says it is (clothod 0.1.33's `pane.progress`), when the machine's daemon
    /// has the feature: a bar along the header's bottom edge, with or without an agent.
    var progress: PaneProgress?

    /// The program's name for a pane with no agent: the spawn command's, so a shell running vim still
    /// reads "zsh". A login shell's leading "-" is dropped.
    var program: String {
        guard let first = command?.first else { return "shell" }
        let name = (first as NSString).lastPathComponent
        let plain = name.hasPrefix("-") ? String(name.dropFirst()) : name
        return plain.isEmpty ? "shell" : plain
    }

    /// The folder as shown: inside the machine's home it starts at "~".
    var folder: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        guard let home, home.count > 1, cwd == home || cwd.hasPrefix(home + "/") else { return cwd }
        return "~" + cwd.dropFirst(home.count)
    }

    /// "Claude · Needs you": the agent's short name and its mark, or its state when it has no mark
    /// ("Claude · Idle", "Claude · Done").
    var chipTitle: String? {
        agent.map { "\($0.shortKindName) · \($0.mark?.label ?? $0.shownState.label)" }
    }

    /// "waiting 2 min" or "6 min", for an agent that needs the user or works.
    func elapsed(now: Date) -> String {
        guard let agent, let mark = agent.mark else { return "" }
        return mark.elapsedText(since: agent.since, now: now)
    }

    /// "Claude: Needs you, waiting 2 minutes", for VoiceOver.
    func spokenAgent(now: Date) -> String? {
        guard let agent else { return nil }
        var text = "\(agent.shortKindName): \(agent.mark?.label ?? agent.shownState.label)"
        if let mark = agent.mark, mark == .needsYou || mark == .working, let since = agent.since {
            let time = Self.spoken(seconds: max(0, Int(now.timeIntervalSince1970 - since)))
            text += mark == .needsYou ? ", waiting \(time)" : ", \(time)"
        }
        if agent.isMuted { text += ", muted" }
        return text
    }

    /// "less than a minute", "1 minute", "2 hours", "3 days".
    static func spoken(seconds: Int) -> String {
        func count(_ value: Int, _ unit: String) -> String { "\(value) \(unit)\(value == 1 ? "" : "s")" }
        switch seconds {
        case ..<60: return "less than a minute"
        case ..<3600: return count(seconds / 60, "minute")
        case ..<86400: return count(seconds / 3600, "hour")
        default: return count(seconds / 86400, "day")
        }
    }

    /// The permission requests the ask bar can answer, oldest first.
    var asks: [PermissionRequest] {
        canDecide ? agent?.pendingRequests ?? [] : []
    }
}

/// The agent's chip: its name and state on the mark's tint (a plain dim chip when it has no mark, a
/// crossed bell when muted). A click or a right-click opens the agent's menu.
final class PaneHeaderChip: NSButton {
    static var height: CGFloat { s(18) }

    /// The agent's menu (Resolve, Mute or Unmute, History…, the permission and reply items).
    var onMenu: (() -> NSMenu?)?
    private(set) var mark: AgentMark?
    private(set) var isMuted = false
    private(set) var text = ""
    /// The kind's SF Symbol (one of ClothoKit's `AgentKind` literals), leading the name.
    private(set) var symbol = AgentKind.genericSymbol
    /// Without the kind's symbol: the header sets it in a pane too narrow for the symbol and the whole
    /// title, so the title is never the one cut. (A muted agent's crossed bell stays.)
    var isCompact = false {
        didSet { if isCompact != oldValue { apply() } }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        isBordered = false
        setButtonType(.momentaryChange)
        imagePosition = .imageLeading
        imageHugsTitle = true
        refusesFirstResponder = true
        target = self
        action = #selector(openMenu)
        apply()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(text: String, mark: AgentMark?, muted: Bool, symbol: String = AgentKind.genericSymbol) {
        guard text != self.text || mark != self.mark || muted != isMuted || symbol != self.symbol else { return }
        (self.text, self.mark, isMuted, self.symbol) = (text, mark, muted, symbol)
        apply()
    }

    /// The chip's background: the mark's tint, or the plain pill.
    var fill: NSColor { mark?.tint ?? Theme.pill }
    private var textColor: NSColor { mark == nil ? Theme.secondaryText : Theme.foreground }
    private var titleFont: NSFont { .systemFont(ofSize: s(11), weight: .medium) }

    /// Fonts and sizes again, after a zoom or a change.
    func apply() {
        attributedTitle = NSAttributedString(string: text, attributes: [.font: titleFont, .foregroundColor: textColor])
        // The crossed bell for a muted agent, else the kind's symbol. Decorative: the name is in the title.
        let glyph = (isMuted ? NSImage(systemSymbolName: "bell.slash", accessibilityDescription: "Muted")
            : NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: AgentKind.genericSymbol, accessibilityDescription: nil))?
            .withSymbolConfiguration(.init(pointSize: s(9), weight: .medium))
        fullWidth = Self.width(title: attributedTitle, image: glyph)
        image = isMuted || !isCompact ? glyph : nil
        contentTintColor = textColor
        layer?.cornerRadius = s(5)
        layer?.cornerCurve = .continuous
        applyFill()
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private func applyFill() {
        withAppearance { layer?.backgroundColor = fill.cgColor }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFill()
    }

    /// The title, the symbol before it, and side padding.
    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.width(title: attributedTitle, image: image), height: Self.height)
    }

    /// The chip's width with its symbol, compact or not: what the header asks before it decides.
    private(set) var fullWidth: CGFloat = 0

    private static func width(title: NSAttributedString, image: NSImage?) -> CGFloat {
        var width = title.size().width.rounded(.up) + s(14)
        if let image { width += image.size.width.rounded(.up) + s(5) }
        return width
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with event: NSEvent) { openMenu() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    @objc private func openMenu() {
        guard let menu = onMenu?() else { return }
        // Under the chip (a button is flipped).
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + s(4)), in: self)
    }
}

extension NSTextField {
    /// The room a label's text needs on one line, from its cell. A label placed by frame is sized from
    /// this: its `intrinsicContentSize` comes out a few points short of what the cell then wants, and the
    /// text truncates with room to spare.
    var textSize: NSSize {
        guard let cell else { return intrinsicContentSize }
        let size = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: 10_000))
        return NSSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
    }
}

final class PaneHeader: NSView {
    static var height: CGFloat { s(24) }

    let chip = PaneHeaderChip()
    /// The program's name, for a pane with no agent.
    let program = NSTextField(labelWithString: "")
    let elapsed = NSTextField(labelWithString: "")
    let folder = NSTextField(labelWithString: "")
    /// Room kept free at the trailing end for the pane's ×, hovered or not, so nothing moves on hover.
    var trailingReserve: CGFloat = 0 {
        didSet { if trailingReserve != oldValue { needsLayout = true } }
    }
    /// The clock, which tests set.
    var now: () -> Date = { Date() }
    private(set) var chrome = PaneChrome()
    private let bottomLine = CALayer()
    /// The pane's progress, over the bottom line: the header's height never changes for it.
    let progressBar = ProgressBarView()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        program.lineBreakMode = .byTruncatingTail
        elapsed.lineBreakMode = .byClipping
        // The folder's end is what tells two panes apart.
        folder.lineBreakMode = .byTruncatingHead
        // Its time is in the chip's description.
        elapsed.setAccessibilityElement(false)
        for view in [chip, program, elapsed, folder, progressBar] as [NSView] { addSubview(view) }
        applyScale()
        show(chrome)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Fonts at the current zoom.
    func applyScale() {
        program.font = .systemFont(ofSize: s(11), weight: .medium)
        program.textColor = Theme.secondaryText
        elapsed.font = .monospacedDigitSystemFont(ofSize: s(11), weight: .regular)
        elapsed.textColor = Theme.dimText
        folder.font = .systemFont(ofSize: s(11))
        folder.textColor = Theme.dimText
        chip.apply()
        needsLayout = true
    }

    func show(_ chrome: PaneChrome) {
        self.chrome = chrome
        if let agent = chrome.agent {
            chip.show(text: chrome.chipTitle ?? "", mark: agent.mark, muted: agent.isMuted, symbol: agent.kindSymbolName)
        }
        progressBar.progress = chrome.progress
        chip.isHidden = chrome.agent == nil
        program.isHidden = chrome.agent != nil
        program.stringValue = chrome.program
        program.setAccessibilityLabel("Program \(chrome.program)")
        folder.stringValue = chrome.folder ?? ""
        folder.toolTip = chrome.cwd
        folder.setAccessibilityLabel(chrome.folder.map { "Folder \($0)" })
        refreshElapsed()
        needsLayout = true
    }

    /// The time moved on (the app's 30 s clock, and every sync).
    func refreshElapsed() {
        let now = now()
        let text = chrome.elapsed(now: now)
        if elapsed.stringValue != text {
            elapsed.stringValue = text
            needsLayout = true
        }
        let spoken = chrome.spokenAgent(now: now)
        chip.setAccessibilityLabel(spoken)
        chip.toolTip = spoken
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // Only the bottom edge: a 1 pt line drawn by a sublayer.
        bottomLine.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        withAppearance {
            layer?.backgroundColor = Theme.sidebar.cgColor
            bottomLine.backgroundColor = Theme.divider.cgColor
        }
        if bottomLine.superlayer == nil { layer?.addSublayer(bottomLine) }
    }

    /// By hand: the chip (or the program) keeps its whole width; in a narrow pane the time goes first,
    /// then the folder. The folder ends before the ×'s room.
    override func layout() {
        super.layout()
        needsDisplay = true
        let gap = s(8)
        let limit = bounds.width - trailingReserve
        func place(_ view: NSView, x: CGFloat, width: CGFloat, height: CGFloat) {
            let frame = NSRect(x: x, y: ((bounds.height - height) / 2).rounded(), width: width, height: height)
            if view.frame != frame { view.frame = frame }
        }
        let barFrame = NSRect(x: 0, y: bounds.height - ProgressBarView.height, width: bounds.width, height: ProgressBarView.height)
        if progressBar.frame != barFrame { progressBar.frame = barFrame }
        var x = s(8)
        let lead: NSView = chrome.agent == nil ? program : chip
        if chrome.agent != nil {
            // The symbol shows where the chip fits with it; a narrower pane keeps the whole title instead.
            let compact = chip.fullWidth > limit - x
            if chip.isCompact != compact { chip.isCompact = compact }
        }
        let leadSize = chrome.agent == nil ? program.textSize : chip.intrinsicContentSize
        let leadWidth = min(leadSize.width.rounded(.up), max(0, limit - x))
        place(lead, x: x, width: leadWidth, height: leadSize.height)
        x += leadWidth

        let elapsedSize = elapsed.textSize
        let folderSize = folder.textSize
        let elapsedWidth = elapsed.stringValue.isEmpty ? 0 : elapsedSize.width.rounded(.up)
        let folderWidth = folder.stringValue.isEmpty ? 0 : folderSize.width.rounded(.up)
        // The least of the folder worth showing.
        let folderLeast = min(folderWidth, s(56))
        let showsElapsed = elapsedWidth > 0 && limit - x >= gap + elapsedWidth + (folderWidth > 0 ? gap + folderLeast : 0)
        elapsed.isHidden = !showsElapsed
        if showsElapsed {
            place(elapsed, x: x + gap, width: elapsedWidth, height: elapsedSize.height)
            x += gap + elapsedWidth
        }
        let room = limit - x - gap
        let showsFolder = folderWidth > 0 && room >= folderLeast
        folder.isHidden = !showsFolder
        if showsFolder {
            let width = min(folderWidth, room)
            place(folder, x: limit - width, width: width, height: folderSize.height)
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

extension PaneHostView {
    /// Where the things that float over the terminal's top go (the restored note, the find bar): just
    /// under the header.
    static var belowHeader: CGFloat { PaneHeader.height + padding + 2 }

    /// The header, the outline and the ask bar follow `chrome`.
    func updateChrome() {
        header.show(chrome)
        updateAskBar()
        updateOutline()
        needsLayout = true
    }

    /// The header's time, from the app's 30 s clock.
    func refreshElapsed() { header.refreshElapsed() }

    /// Whether the amber outline shows: the pane's agent needs the user.
    var showsNeedsYouOutline: Bool { chrome.agent?.mark == .needsYou }

    /// The amber line around a pane whose agent needs the user. The accent focus ring is the layer's own
    /// border; when both show, the amber line sits 1 pt inside it.
    func updateOutline() {
        let ring = isFocusedPane && showsFocusRing
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.isHidden = !showsNeedsYouOutline
        outline.frame = ring ? bounds.insetBy(dx: 1, dy: 1) : bounds
        outline.cornerRadius = ring ? 3 : 4
        outline.borderWidth = 1.5
        withAppearance { outline.borderColor = Theme.caution.cgColor }
        CATransaction.commit()
    }
}
