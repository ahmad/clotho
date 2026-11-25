import AppKit
import ClothoKit

// The Overview: one card per agent on every machine, in three lanes (Needs you, Working, Done), over the
// whole window under the window buttons. A card shows the agent's mark, where it is, how long, what it
// asks or last said, a live two-line peek at its pane's screen, its branch and how much changed.
//
// The model is OverviewModel.swift (cards, lanes, the filter, the grid's arrow keys); this file draws it and
// takes the keys and the mouse; Overview.swift puts it in the window. Frames are set by hand from
// `OverviewLayout`, as the rest of the app does: there are few cards.
//
// Keys, with the keyboard in the grid: the arrows move, Return opens the agent's pane, ⌘↩ opens its Tab
// beside the current pane, R resolves, M mutes or unmutes, / goes to the filter, Esc goes back. A card has
// no Allow or Deny: a permission ask is answered in its pane, where what it asks is in view.

/// A label inside a card or a lane: clicks go to the card.
private final class OverviewLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A view whose y grows downwards.
class OverviewFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One lane: its title ("Needs you · 2") over its cards. A group for VoiceOver ("Needs you, 2").
final class OverviewLaneView: OverviewFlippedView {
    let lane: AgentStatusGroup
    let header: NSTextField = OverviewLabel(labelWithString: "")
    private(set) var count = 0

    init(lane: AgentStatusGroup) {
        self.lane = lane
        super.init(frame: .zero)
        header.lineBreakMode = .byTruncatingTail
        // The lane says its title itself.
        header.setAccessibilityElement(false)
        header.cell?.setAccessibilityElement(false)
        addSubview(header)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        applyScale()
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyScale() {
        header.font = .systemFont(ofSize: s(10.5), weight: .semibold)
        header.textColor = Theme.dimText
        set(count: count)
    }

    /// "NEEDS YOU · 2" on screen, "Needs you, 2" said.
    func set(count: Int) {
        self.count = count
        let text = "\(lane.title) · \(count)"
        header.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: s(10.5), weight: .semibold), .foregroundColor: Theme.dimText, .kern: s(0.7),
        ])
        setAccessibilityLabel("\(lane.title), \(count)")
    }

    /// The header's words as they read (tests).
    var title: String { "\(lane.title) · \(count)" }
}

/// One agent's card. One element for VoiceOver: a button whose label is the whole card.
final class OverviewCardView: NSView {
    static var height: CGFloat { s(136) }
    static var peekHeight: CGFloat { s(36) }
    static var footerHeight: CGFloat { s(22) }
    static var cornerRadius: CGFloat { s(8) }
    /// How far outside the card its selection ring is drawn.
    static var ringOutset: CGFloat { s(3) }

    var card: OverviewCard {
        didSet { if card != oldValue { apply() } }
    }
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            updateRing()
            NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
        }
    }
    /// A click: how many (2 opens).
    var onClick: ((Int) -> Void)?
    var contextMenu: (() -> NSMenu?)?
    var onPress: (() -> Void)?
    var actions: (() -> [NSAccessibilityCustomAction])?

    let body = OverviewFlippedView()
    let markView: AgentMarkView
    let place: NSTextField = OverviewLabel(labelWithString: "")
    let age: NSTextField = OverviewLabel(labelWithString: "")
    let message: NSTextField = OverviewLabel(wrappingLabelWithString: "")
    let sub: NSTextField = OverviewLabel(labelWithString: "")
    /// The peek block: the last two rows of the pane's screen. Hidden on a machine that sends none.
    let peek = OverviewFlippedView()
    let peekRows: [NSTextField] = [OverviewLabel(labelWithString: ""), OverviewLabel(labelWithString: "")]
    let footer = OverviewFlippedView()
    let branch: NSTextField = OverviewLabel(labelWithString: "")
    let counts: NSTextField = OverviewLabel(labelWithString: "")
    private let peekRule = NSView()
    private let footerRule = NSView()
    private let ring = CALayer()
    /// The rows the peek shows, oldest first.
    private(set) var peekLines: [String] = []

    init(card: OverviewCard) {
        self.card = card
        markView = AgentMarkView(card.mark)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        ring.isHidden = true
        layer?.addSublayer(ring)

        body.wantsLayer = true
        body.layer?.masksToBounds = true
        body.layer?.borderWidth = 1
        addSubview(body)
        // Frames are set by hand here.
        markView.translatesAutoresizingMaskIntoConstraints = true
        // The mark is part of the card's one element.
        markView.setAccessibilityElement(false)
        for label in [place, age, sub, branch, counts] + peekRows {
            label.lineBreakMode = .byTruncatingTail
            label.usesSingleLineMode = true
            label.cell?.truncatesLastVisibleLine = true
        }
        age.alignment = .right
        counts.alignment = .right
        message.maximumNumberOfLines = 2
        message.lineBreakMode = .byWordWrapping
        message.cell?.truncatesLastVisibleLine = true
        message.isSelectable = false
        for view in [peek, footer, peekRule, footerRule] { view.wantsLayer = true }
        for view in [markView, place, age, message, sub, peek, footer] as [NSView] { body.addSubview(view) }
        peek.addSubview(peekRule)
        peekRows.forEach(peek.addSubview)
        footer.addSubview(footerRule)
        footer.addSubview(branch)
        footer.addSubview(counts)
        applyScale()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Fonts and sizes at the app's zoom, then the card's content again.
    func applyScale() {
        body.layer?.cornerRadius = Self.cornerRadius
        body.layer?.cornerCurve = .continuous
        place.font = .systemFont(ofSize: s(12), weight: .semibold)
        age.font = .systemFont(ofSize: s(11))
        message.font = .systemFont(ofSize: s(12))
        sub.font = .systemFont(ofSize: s(11))
        let mono = AppDelegate.terminalFont(size: s(10))
        peekRows.forEach { $0.font = mono }
        branch.font = AppDelegate.terminalFont(size: s(10.5))
        place.textColor = Theme.foreground
        message.textColor = Theme.foreground
        for label in [age, sub, branch] + peekRows { label.textColor = Theme.dimText }
        apply()
    }

    private func apply() {
        markView.mark = card.mark
        place.stringValue = card.place
        place.toolTip = card.place
        age.stringValue = card.age
        message.stringValue = card.message ?? ""
        message.toolTip = card.message
        message.isHidden = card.message == nil
        sub.stringValue = card.sub
        sub.toolTip = card.sub
        peek.isHidden = !card.hasPeek
        // A branch's name is the repository's text: bidi and control characters show as what they are.
        branch.stringValue = card.branch.map { "⎇ " + DiffText.display($0) } ?? OverviewCard.noRepo
        branch.toolTip = card.branch.map(DiffText.display)
        counts.attributedStringValue = Self.countsTitle(card.changes) ?? NSAttributedString()
        counts.toolTip = ChangeCountText.spoken(card.changes)
        applyColors()
        needsLayout = true
    }

    /// "+128" in the palette's green and "−32" in its red, or "6 files" dim when the lines weren't
    /// counted. Nil when nothing changed or nothing is known.
    static func countsTitle(_ changes: PaneGit.Changes?) -> NSAttributedString? {
        guard let total = changes?.total, total.files > 0 else { return nil }
        let font = AppDelegate.terminalFont(size: s(10.5))
        guard let lines = ChangeCountText.lines(added: total.added, removed: total.removed), let space = lines.firstIndex(of: " ") else {
            return NSAttributedString(string: ChangeCountText.files(total.files), attributes: [.font: font, .foregroundColor: Theme.dimText])
        }
        let title = NSMutableAttributedString(string: String(lines[..<space]), attributes: [.font: font, .foregroundColor: Theme.success])
        title.append(NSAttributedString(string: String(lines[space...]), attributes: [.font: font, .foregroundColor: Theme.danger]))
        return title
    }

    /// Layer colours are resolved once: set again when the appearance changes.
    func applyColors() {
        withAppearance {
            body.layer?.backgroundColor = Theme.sidebar.cgColor
            // Needs you has the amber outline, as the pane that asks has.
            body.layer?.borderColor = (card.lane == .needsYou ? Theme.caution : Theme.divider).cgColor
            peek.layer?.backgroundColor = Theme.background.cgColor
            peekRule.layer?.backgroundColor = Theme.divider.cgColor
            footerRule.layer?.backgroundColor = Theme.divider.cgColor
            ring.borderColor = Theme.accent.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// The selection: a ring in the accent, outside the card's own outline with a gap between, so it
    /// reads apart from the amber one.
    private func updateRing() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds.insetBy(dx: -Self.ringOutset, dy: -Self.ringOutset)
        ring.cornerRadius = Self.cornerRadius + Self.ringOutset
        ring.cornerCurve = .continuous
        ring.borderWidth = s(2)
        ring.isHidden = !isSelected
        CATransaction.commit()
    }

    /// Whether the selection ring shows (tests).
    var showsRing: Bool { !ring.isHidden }

    /// The last rows of the pane's screen, oldest first: exactly two rows show, each on one line. Only
    /// the two labels change. Control and bidi characters show as what they are (`DiffText.display`).
    func setPeek(_ lines: [String]) {
        guard lines != peekLines else { return }
        peekLines = lines
        let shown = Array(lines.suffix(peekRows.count))
        for (index, row) in peekRows.enumerated() {
            row.stringValue = index < shown.count ? DiffText.display(shown[index]) : ""
        }
    }

    override func layout() {
        super.layout()
        body.frame = bounds
        updateRing()
        let pad = s(9), width = bounds.width
        let inner = max(0, width - 2 * pad)
        let side = AgentMarkView.side
        let rowHeight = s(16)
        markView.frame = CGRect(x: pad, y: s(7) + ((rowHeight - side) / 2).rounded(), width: side, height: side)
        // Measured from its words: a label's own fitting size can lag behind a change of them.
        let ageWidth = min(Self.width(of: age), inner / 2)
        age.frame = CGRect(x: width - pad - ageWidth, y: s(7), width: ageWidth, height: rowHeight)
        let placeX = pad + side + s(7)
        place.frame = CGRect(x: placeX, y: s(7), width: max(0, age.frame.minX - s(7) - placeX), height: rowHeight)

        // At most two lines of the message, then the dim line right under it.
        let messageY = s(27)
        var messageHeight: CGFloat = 0
        if !message.isHidden, let cell = message.cell {
            let two = Self.twoLineHeight(of: message, width: inner)
            messageHeight = min(ceil(cell.cellSize(forBounds: CGRect(x: 0, y: 0, width: inner, height: 10000)).height), two)
            message.preferredMaxLayoutWidth = inner
            message.frame = CGRect(x: pad, y: messageY, width: inner, height: messageHeight)
        }
        sub.frame = CGRect(x: pad, y: messageY + messageHeight + (messageHeight > 0 ? s(1) : 0), width: inner, height: s(14))

        let footerHeight = Self.footerHeight
        footer.frame = CGRect(x: 0, y: bounds.height - footerHeight, width: width, height: footerHeight)
        footerRule.frame = CGRect(x: 0, y: 0, width: width, height: 1)
        let countsWidth = min(ceil(counts.attributedStringValue.size().width) + (counts.attributedStringValue.length > 0 ? s(4) : 0), inner / 2)
        let lineHeight = s(14)
        let footerY = ((footerHeight - lineHeight) / 2).rounded()
        counts.frame = CGRect(x: width - pad - countsWidth, y: footerY, width: countsWidth, height: lineHeight)
        branch.frame = CGRect(x: pad, y: footerY, width: max(0, counts.frame.minX - (countsWidth > 0 ? s(8) : 0) - pad), height: lineHeight)

        // The peek: a fixed block above the footer.
        let peekHeight = Self.peekHeight
        peek.frame = CGRect(x: 0, y: footer.frame.minY - peekHeight, width: width, height: peekHeight)
        peekRule.frame = CGRect(x: 0, y: 0, width: width, height: 1)
        for (index, row) in peekRows.enumerated() {
            row.frame = CGRect(x: pad, y: s(4) + CGFloat(index) * s(14), width: inner, height: s(14))
        }
    }

    /// The height a wrapping label's own cell needs for two lines at this width, in its font. Not twice a
    /// line's height: the cell rounds each line up, so at some zooms twice a line's height is short of
    /// two lines, and a label that short shows only its first.
    static func twoLineHeight(of label: NSTextField, width: CGFloat) -> CGFloat {
        guard let cell = label.cell?.copy() as? NSCell else { return 0 }
        cell.stringValue = "A\nA"
        return ceil(cell.cellSize(forBounds: CGRect(x: 0, y: 0, width: width, height: 10000)).height)
    }

    /// The room a one-line label's words take, with the label's own margins.
    static func width(of label: NSTextField) -> CGFloat {
        guard !label.stringValue.isEmpty else { return 0 }
        return ceil(label.attributedStringValue.size().width) + s(6)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) { onClick?(event.clickCount) }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }

    // MARK: Accessibility: one element

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { card.spoken }
    override func accessibilityChildren() -> [Any]? { [] }
    override func isAccessibilitySelected() -> Bool { isSelected }
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return onPress != nil
    }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? { actions?() }
}

final class OverviewView: NSView, NSSearchFieldDelegate {
    /// Back, or Esc.
    var onClose: (() -> Void)?
    var onOpen: ((PaneKey) -> Void)?
    var onOpenBeside: ((PaneKey) -> Void)?
    var onResolve: ((PaneKey) -> Void)?
    /// Mute (true) or unmute.
    var onMute: ((PaneKey, Bool) -> Void)?
    /// The filter left other cards: the peeks follow.
    var onFilterChange: (() -> Void)?
    /// Every 30 s while shown: the ages move on.
    var onTick: (() -> Void)?
    /// What a key that can't act does (tests count them).
    static var beep: () -> Void = { NSSound.beep() }

    let titleBar = NSView()
    let titleLabel = NSTextField(labelWithString: "")
    /// A short line when a key couldn't act ("Already in this Tab"): after the title, or on a row of its
    /// own under the title row when it doesn't fit there whole.
    let noteLabel = NSTextField(labelWithString: "")
    let filterField = NSSearchField()
    let backButton = NSButton()
    private let titleRule = NSView()
    let scrollView = NSScrollView()
    let document = OverviewFlippedView()
    let emptyTitle = NSTextField(labelWithString: "")
    let emptyLine = NSTextField(labelWithString: "")

    /// Every lane, before the filter.
    private(set) var lanes: [(lane: AgentStatusGroup, cards: [OverviewCard])] = []
    /// The lanes on screen: what the filter leaves.
    private(set) var shownLanes: [(lane: AgentStatusGroup, cards: [OverviewCard])] = []
    /// The cards on screen, in reading order.
    var shownCards: [OverviewCard] { OverviewModel.cards(shownLanes) }
    private(set) var cardViews: [PaneKey: OverviewCardView] = [:]
    private(set) var laneViews: [AgentStatusGroup: OverviewLaneView] = [:]
    /// The selected card's pane, and where it is among the cards on screen.
    private(set) var selected: PaneKey?
    private var selectedIndex: Int?
    /// The rows each card's peek shows.
    private var peeks: [PaneKey: [String]] = [:]
    private var clock: Timer?
    private var noteTimer: Timer?

    static let filterPlaceholder = "Filter"
    static let backTip = "Back to the window (esc)"
    static let emptyTitle = "No agents"
    static let emptyLine = "Agents running in any Tab show here."
    static func noMatch(_ query: String) -> String { "No agents match \u{201C}\(query)\u{201D}" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        titleBar.wantsLayer = true
        titleRule.wantsLayer = true
        addSubview(titleBar)
        addSubview(titleRule)

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        noteLabel.lineBreakMode = .byTruncatingTail
        noteLabel.isHidden = true

        filterField.placeholderString = Self.filterPlaceholder
        filterField.delegate = self
        filterField.sendsSearchStringImmediately = true
        filterField.sendsWholeSearchString = false
        filterField.focusRingType = .none
        // The field's × clears it without a text change: its action says so.
        filterField.target = self
        filterField.action = #selector(filterAction)
        filterField.toolTip = "Filter by machine, Workspace, Tab, branch or agent; or needs, working, done (/)"
        filterField.setAccessibilityLabel("Filter agents")

        backButton.bezelStyle = .inline
        backButton.isBordered = false
        backButton.target = self
        backButton.action = #selector(back)
        backButton.toolTip = Self.backTip
        backButton.setAccessibilityLabel("Back to the window")
        for view in [titleLabel, noteLabel, filterField, backButton] as [NSView] { addSubview(view) }

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = document
        addSubview(scrollView)

        for label in [emptyTitle, emptyLine] {
            label.alignment = .center
            label.lineBreakMode = .byTruncatingMiddle
            label.isHidden = true
            addSubview(label)
        }

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Overview")
        applyScale()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// The grid at the app's zoom.
    var grid: OverviewLayout {
        OverviewLayout(sideInset: s(18), gap: s(10), minCardWidth: s(250), cardHeight: OverviewCardView.height,
                       headerHeight: s(28), laneGap: s(14))
    }
    static var titleHeight: CGFloat { TabBarView.height }
    /// Above the first lane and under the last.
    static var topInset: CGFloat { s(8) }
    static var bottomInset: CGFloat { s(20) }

    // MARK: Looks

    /// Fonts and sizes at the app's zoom (View ▸ Zoom In, Zoom Out, Actual Size).
    func applyScale() {
        noteLabel.font = .systemFont(ofSize: s(12))
        filterField.font = .systemFont(ofSize: s(12))
        filterField.controlSize = .small
        emptyTitle.font = .systemFont(ofSize: s(15), weight: .semibold)
        emptyLine.font = .systemFont(ofSize: s(12))
        emptyTitle.textColor = Theme.foreground
        emptyLine.textColor = Theme.dimText
        noteLabel.textColor = Theme.caution
        let back = NSMutableAttributedString(string: "Back", attributes: [.font: NSFont.systemFont(ofSize: s(12), weight: .medium), .foregroundColor: Theme.accent])
        back.append(NSAttributedString(string: "  esc", attributes: [.font: NSFont.systemFont(ofSize: s(11)), .foregroundColor: Theme.dimText]))
        backButton.attributedTitle = back
        updateTitle()
        laneViews.values.forEach { $0.applyScale() }
        cardViews.values.forEach { $0.applyScale() }
        refreshColors()
        needsLayout = true
        place()
    }

    /// Layer colours are resolved once: set again when the appearance changes.
    func refreshColors() {
        withAppearance {
            layer?.backgroundColor = Theme.background.cgColor
            titleBar.layer?.backgroundColor = Theme.sidebar.cgColor
            titleRule.layer?.backgroundColor = Theme.divider.cgColor
        }
        cardViews.values.forEach { $0.applyColors() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func updateTitle() {
        let all = OverviewModel.cards(lanes)
        let text = OverviewModel.title(cards: all)
        let title = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: s(13)), .foregroundColor: Theme.dimText])
        let name = (text as NSString).range(of: "Overview")
        if name.location != NSNotFound {
            title.addAttributes([.font: NSFont.systemFont(ofSize: s(13), weight: .semibold), .foregroundColor: Theme.foreground], range: name)
        }
        guard title != titleLabel.attributedStringValue else { return }
        titleLabel.attributedStringValue = title
        needsLayout = true
    }

    /// The title as it reads: "Overview · 6 agents on 2 machines".
    var title: String { titleLabel.stringValue }

    // MARK: The cards

    /// Every lane's cards, before the filter. Runs on every model change while the Overview shows: a
    /// card's view is touched only when its card changed.
    func update(lanes new: [(lane: AgentStatusGroup, cards: [OverviewCard])]) {
        lanes = new
        let all = Set(OverviewModel.cards(new).map(\.key))
        if peeks.keys.contains(where: { !all.contains($0) }) { peeks = peeks.filter { all.contains($0.key) } }
        updateTitle()
        apply()
    }

    /// The filter's words. Setting it filters, as typing does.
    var query: String {
        get { filterField.stringValue }
        set {
            guard newValue != filterField.stringValue else { return }
            filterField.stringValue = newValue
            filterChanged()
        }
    }

    private func filterChanged() {
        apply()
        onFilterChange?()
    }

    private func apply() {
        shownLanes = OverviewModel.filter(lanes, query: query)
        let cards = shownCards
        let keys = cards.map(\.key)
        selectedIndex = OverviewLayout.selectionAfter(change: keys, selected: selected, at: selectedIndex)
        selected = selectedIndex.map { keys[$0] }

        let shownKeys = Set(keys)
        for (key, view) in cardViews where !shownKeys.contains(key) {
            view.removeFromSuperview()
            cardViews[key] = nil
        }
        let shownGroups = Set(shownLanes.map(\.lane))
        for (lane, view) in laneViews where !shownGroups.contains(lane) {
            view.removeFromSuperview()
            laneViews[lane] = nil
        }
        for lane in shownLanes {
            let laneView = laneViews[lane.lane] ?? makeLane(lane.lane)
            if laneView.count != lane.cards.count { laneView.set(count: lane.cards.count) }
            for card in lane.cards {
                let view = cardViews[card.key] ?? makeCard(card)
                view.card = card
                if view.superview !== laneView { laneView.addSubview(view) }
                view.isSelected = card.key == selected
            }
        }
        // Lanes in their order for VoiceOver and the key loop.
        let ordered: [NSView] = shownLanes.compactMap { laneViews[$0.lane] }
        if document.subviews != ordered {
            ordered.forEach { $0.removeFromSuperview() }
            ordered.forEach(document.addSubview)
        }
        place()

        let query = query.trimmingCharacters(in: .whitespaces)
        let empty = cards.isEmpty
        emptyTitle.isHidden = !empty
        emptyLine.isHidden = !empty || !lanes.isEmpty
        if empty {
            emptyTitle.stringValue = lanes.isEmpty ? Self.emptyTitle : Self.noMatch(query)
            emptyLine.stringValue = Self.emptyLine
            needsLayout = true
        }
    }

    private func makeLane(_ lane: AgentStatusGroup) -> OverviewLaneView {
        let view = OverviewLaneView(lane: lane)
        laneViews[lane] = view
        document.addSubview(view)
        return view
    }

    private func makeCard(_ card: OverviewCard) -> OverviewCardView {
        let key = card.key
        let view = OverviewCardView(card: card)
        view.onClick = { [weak self] clicks in
            guard let self else { return }
            select(key)
            window?.makeFirstResponder(self)
            if clicks == 2 { onOpen?(key) }
        }
        view.contextMenu = { [weak self] in
            self?.select(key)
            return self?.menu(for: key)
        }
        view.onPress = { [weak self] in self?.onOpen?(key) }
        view.actions = { [weak self] in self?.accessibilityActions(for: key) ?? [] }
        if let lines = peeks[key] { view.setPeek(lines) }
        cardViews[key] = view
        return view
    }

    /// Frames from `OverviewLayout`, for the width there is. No animation.
    private func place() {
        let width = scrollView.contentSize.width
        guard width > 0 else { return }
        let frames = grid.frames(lanes: shownLanes.map(\.cards.count), width: width)
        let top = Self.topInset
        // A lane's view runs a little past its last row, for that row's selection ring.
        let ringRoom = OverviewCardView.ringOutset + 1
        for (index, lane) in shownLanes.enumerated() {
            guard let laneView = laneViews[lane.lane] else { continue }
            let header = frames.headers[index], cards = frames.cards[index]
            let frame = CGRect(x: 0, y: top + header.minY, width: width, height: (cards.last?.maxY ?? header.maxY) - header.minY + ringRoom)
            if laneView.frame != frame { laneView.frame = frame }
            let headerFrame = CGRect(x: header.minX, y: s(8), width: header.width, height: header.height - s(8))
            if laneView.header.frame != headerFrame { laneView.header.frame = headerFrame }
            for (card, rect) in zip(lane.cards, cards) {
                let frame = rect.offsetBy(dx: 0, dy: -header.minY)
                if let view = cardViews[card.key], view.frame != frame { view.frame = frame }
            }
        }
        let size = CGSize(width: width, height: max(top + frames.height + Self.bottomInset, scrollView.contentSize.height))
        if document.frame.size != size { document.setFrameSize(size) }
    }

    override func layout() {
        super.layout()
        let height = Self.titleHeight
        titleBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        titleRule.frame = CGRect(x: 0, y: height, width: bounds.width, height: 1)

        backButton.sizeToFit()
        let backSize = backButton.frame.size
        backButton.frame = CGRect(x: bounds.width - s(12) - backSize.width, y: ((height - backSize.height) / 2).rounded(),
                                  width: backSize.width, height: backSize.height)
        let lead = WindowButtons.width + s(10)
        let filterHeight = max(filterField.intrinsicContentSize.height, s(22))
        let room = backButton.frame.minX - s(12) - lead
        let filterWidth = min(s(200), max(s(90), room / 3))
        filterField.frame = CGRect(x: backButton.frame.minX - s(12) - filterWidth, y: ((height - filterHeight) / 2).rounded(),
                                   width: filterWidth, height: filterHeight)
        let textRoom = max(0, filterField.frame.minX - s(12) - lead)
        let titleSize = titleLabel.intrinsicContentSize
        let titleWidth = min(OverviewCardView.width(of: titleLabel), textRoom)
        titleLabel.frame = CGRect(x: lead, y: ((height - titleSize.height) / 2).rounded(), width: titleWidth, height: titleSize.height)
        let noteHeight = noteLabel.intrinsicContentSize.height
        let noteRoom = max(0, lead + textRoom - titleLabel.frame.maxX - s(14))
        var top = height + 1
        if noteLabel.isHidden || OverviewCardView.width(of: noteLabel) <= noteRoom {
            noteLabel.frame = CGRect(x: titleLabel.frame.maxX + s(14), y: ((height - noteHeight) / 2).rounded(), width: noteRoom, height: noteHeight)
        } else {
            // No room for the whole line after the title: it has the row under the title row, and the
            // cards start below it while it shows.
            let inset = grid.sideInset
            noteLabel.frame = CGRect(x: inset, y: top + s(6), width: max(0, bounds.width - 2 * inset), height: noteHeight)
            top = noteLabel.frame.maxY + s(2)
        }

        let body = CGRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        if scrollView.frame != body { scrollView.frame = body }
        place()

        let titleHeight = emptyTitle.intrinsicContentSize.height, lineHeight = emptyLine.intrinsicContentSize.height
        let middle = body.midY - s(10)
        emptyTitle.frame = CGRect(x: s(16), y: middle - titleHeight, width: max(0, bounds.width - s(32)), height: titleHeight)
        emptyLine.frame = CGRect(x: s(16), y: middle + s(6), width: max(0, bounds.width - s(32)), height: lineHeight)
    }

    // MARK: Peeks

    /// The rows a card's peek shows (already picked from what its daemon sent). Only that card's two
    /// labels change.
    func setPeek(_ key: PaneKey, lines: [String]) {
        peeks[key] = lines
        cardViews[key]?.setPeek(lines)
    }

    func clearPeeks() {
        peeks.removeAll()
        cardViews.values.forEach { $0.setPeek([]) }
    }

    // MARK: Shown and hidden

    /// The key loop: the filter, the grid, Back. Set once the view is in its window and again whenever
    /// it shows: AppKit links a view into its siblings' loop as it is added.
    private func linkKeyLoop() {
        filterField.nextKeyView = self
        nextKeyView = backButton
        backButton.nextKeyView = filterField
    }

    /// Shown: the ages move on every 30 s.
    func didShow() {
        linkKeyLoop()
        clock?.invalidate()
        clock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTick?() }
        }
        scrollView.contentView.scroll(to: .zero)
        showNote(nil)
    }

    func didHide() {
        clock?.invalidate()
        clock = nil
        showNote(nil)
    }

    /// Whether the clock that moves the ages on is running (tests).
    var isTicking: Bool { clock != nil }

    /// Whether the keyboard is in the Overview: its grid, its filter or Back.
    var hasKeyboard: Bool {
        guard !isHidden, let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    /// A short line after the title, also said by VoiceOver: why a key did nothing. Nil clears it.
    func showNote(_ text: String?) {
        noteTimer?.invalidate()
        noteTimer = nil
        noteLabel.stringValue = text ?? ""
        // The whole line, should a narrow window still cut it.
        noteLabel.toolTip = text
        noteLabel.isHidden = text == nil
        needsLayout = true
        guard let text else { return }
        NSAccessibility.post(element: window ?? self, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        noteTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.showNote(nil) }
        }
    }

    /// The line showing after the title, if one is.
    var note: String? { noteLabel.isHidden ? nil : noteLabel.stringValue }

    // MARK: Selection and actions

    var selectedCard: OverviewCard? { selected.flatMap { key in shownCards.first { $0.key == key } } }

    func select(_ key: PaneKey) {
        let keys = shownCards.map(\.key)
        guard let index = keys.firstIndex(of: key) else { return }
        selected = key
        selectedIndex = index
        for (other, view) in cardViews { view.isSelected = other == key }
        if let view = cardViews[key] {
            let room = OverviewCardView.ringOutset + s(6)
            view.scrollToVisible(view.bounds.insetBy(dx: 0, dy: -room))
        }
    }

    func move(_ direction: OverviewLayout.Direction) {
        let cards = shownCards
        guard !cards.isEmpty else { return }
        let columns = grid.columns(width: scrollView.contentSize.width)
        let next = OverviewLayout.move(from: selectedIndex ?? 0, direction: direction, in: shownLanes.map(\.cards.count), columns: columns)
        select(cards[next].key)
    }

    func openSelected() {
        guard let key = selected else { return Self.beep() }
        onOpen?(key)
    }

    func openSelectedBeside() {
        guard let key = selected else { return Self.beep() }
        onOpenBeside?(key)
    }

    /// R: clears the agent's attention. Nothing to clear: a beep.
    func resolveSelected() {
        guard let card = selectedCard, card.canResolve else { return Self.beep() }
        onResolve?(card.key)
    }

    /// M: mutes, or unmutes. A machine that can't mute: a beep.
    func muteSelected() {
        guard let card = selectedCard, card.canMute else { return Self.beep() }
        onMute?(card.key, !card.isMuted)
    }

    func focusFilter() { window?.makeFirstResponder(filterField) }
    func focusGrid() { window?.makeFirstResponder(self) }

    @objc private func back() { onClose?() }

    /// The card's menu. No Allow or Deny: a permission ask is answered in its pane.
    func menu(for key: PaneKey) -> NSMenu? {
        guard let card = shownCards.first(where: { $0.key == key }) else { return nil }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Open") { [weak self] in self?.onOpen?(key) })
        menu.addItem(ClosureMenuItem(title: "Open Beside") { [weak self] in self?.onOpenBeside?(key) })
        if card.canResolve { menu.addItem(ClosureMenuItem(title: "Resolve") { [weak self] in self?.onResolve?(key) }) }
        if card.canMute {
            let muted = card.isMuted
            menu.addItem(ClosureMenuItem(title: muted ? "Unmute" : "Mute") { [weak self] in self?.onMute?(key, !muted) })
        }
        return menu
    }

    private func accessibilityActions(for key: PaneKey) -> [NSAccessibilityCustomAction] {
        guard let card = shownCards.first(where: { $0.key == key }) else { return [] }
        var actions = [NSAccessibilityCustomAction(name: "Open Beside") { [weak self] in
            self?.onOpenBeside?(key)
            return true
        }]
        if card.canResolve {
            actions.append(NSAccessibilityCustomAction(name: "Resolve") { [weak self] in
                self?.onResolve?(key)
                return true
            })
        }
        if card.canMute {
            let muted = card.isMuted
            actions.append(NSAccessibilityCustomAction(name: muted ? "Unmute" : "Mute") { [weak self] in
                self?.onMute?(key, !muted)
                return true
            })
        }
        return actions
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        showNote(nil)
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        switch event.keyCode {
        case 123 where modifiers.isEmpty: move(.left)
        case 124 where modifiers.isEmpty: move(.right)
        case 125 where modifiers.isEmpty: move(.down)
        case 126 where modifiers.isEmpty: move(.up)
        case 36, 76:
            // ⌘↩ is `performKeyEquivalent`'s.
            if modifiers.isEmpty { openSelected() }
        case 53: onClose?()
        case 48:
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) } else { window?.selectNextKeyView(self) }
        default:
            // Everything else stops here: nothing typed reaches what the Overview covers.
            guard modifiers.isEmpty else { return }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "r": resolveSelected()
            case "m": muteSelected()
            case "/": focusFilter()
            default: break
            }
        }
    }

    override func cancelOperation(_ sender: Any?) { onClose?() }

    /// ⌘↩ with the keyboard in the grid: the agent's Tab beside the current pane.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !isHidden, window?.firstResponder === self, event.type == .keyDown, [36, 76].contains(event.keyCode), modifiers == .command else {
            return super.performKeyEquivalent(with: event)
        }
        showNote(nil)
        openSelectedBeside()
        return true
    }

    // The filter: Esc with text clears it and goes back to the grid, Esc on an empty one closes; the down
    // arrow and Return go to the grid.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            if filterField.stringValue.isEmpty {
                onClose?()
            } else {
                query = ""
                focusGrid()
            }
            return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            focusGrid()
            return true
        default:
            return false
        }
    }

    func controlTextDidChange(_ obj: Notification) { filterChanged() }

    @objc private func filterAction() { filterChanged() }

    // MARK: Mouse and drags: all of it stops here

    /// The title row drags the window, and a double-click zooms it, as the tab bar it covers does. A
    /// click anywhere else gives the grid the keyboard.
    override func mouseDown(with event: NSEvent) {
        if convert(event.locationInWindow, from: nil).y <= Self.titleHeight {
            if event.clickCount == 2 {
                NSApp.sendAction(#selector(AppDelegate.zoomWindow(_:)), to: nil, from: self)
            } else {
                window?.performDrag(with: event)
            }
            return
        }
        window?.makeFirstResponder(self)
    }
    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    /// What the terminals, the sidebar, the tab bar and the inspector take, so that a drag over the
    /// Overview stops here (a view that takes no part in a drag lets it through to what is underneath):
    /// refused, as NSView does.
    static let refusedDragTypes: [NSPasteboard.PasteboardType] = [.fileURL, ChromeDrag.type, .clothoRemoteFile]

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes(Self.refusedDragTypes)
        linkKeyLoop()
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
}
