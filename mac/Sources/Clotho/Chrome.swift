import AppKit
import ClothoKit

// The native chrome around the panes: a sidebar of workspaces and a tab
// bar for the focused workspace. Both redraw from the model on every change.

/// Where the pointer is, for hover. Hover state is always recomputed from this, so it can't go stale.
@MainActor
enum Pointer {
    enum Simulation: Equatable {
        /// The real pointer.
        case off
        /// Tests and the TypeText aids: the pointer is here, in screen coordinates, over our window.
        case at(NSPoint)
        /// Tests: the pointer is outside every window of ours.
        case away
    }
    static var simulation = Simulation.off

    /// Whether the pointer is over `view`'s visible part, in its window, with no other app's window (or
    /// one of ours at the same level) on top.
    static func isOver(_ view: NSView) -> Bool {
        guard let window = view.window, !view.isHiddenOrHasHiddenAncestor else { return false }
        let screen: NSPoint
        switch simulation {
        case .away:
            return false
        case .at(let point):
            screen = point
        case .off:
            guard window.isVisible else { return false }
            screen = NSEvent.mouseLocation
            guard isOnTop(window, at: screen) else { return false }
        }
        return visiblePart(of: view).contains(view.convert(window.convertPoint(fromScreen: screen), from: nil))
    }

    /// The part of `view` that can be seen. Since macOS 14 a view that doesn't clip to its bounds (the
    /// default) reports a visibleRect reaching past them, over everything visible in its scroll view, so it
    /// is cut back to the bounds here. Without that, every row counted as "under the pointer" whenever the
    /// pointer was anywhere over the sidebar, and the rows that never got an enter event never got an exit.
    static func visiblePart(of view: NSView) -> NSRect { view.visibleRect.intersection(view.bounds) }

    /// Our window is the top one at `point`, or only our own tooltips and expansion tips are above it.
    private static func isOnTop(_ window: NSWindow, at point: NSPoint) -> Bool {
        let top = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        if top == window.windowNumber { return true }
        guard let above = NSApp.window(withWindowNumber: top) else { return false }
        return above.level > window.level
    }
}

/// A clickable row or tab: highlights on hover and when selected, with an optional close button.
class ChromeItem: NSView, HoverRefreshing, NSDraggingSource {
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onClose: (() -> Void)?
    var contextMenu: (() -> NSMenu?)?
    var isSelected = false { didSet { updateColors() } }
    /// A keyboard cursor ring (the sidebar has keyboard focus and this is its current row).
    var showsCursor = false {
        didSet {
            layer?.borderWidth = showsCursor ? s(1.5) : 0
            layer?.borderColor = Theme.accent.withAlphaComponent(0.8).cgColor
        }
    }

    /// The title's color when not selected (nil: dim, as before), and when selected.
    var restingTextColor: NSColor?
    private(set) var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            updateColors()
            onHoverChanged?(hovering)
        }
    }
    /// The pointer came over the item, or left it.
    var onHoverChanged: ((Bool) -> Void)?
    /// Rows with an attributed title keep its colors on hover and selection.
    var colorsOwnTitle = false
    var selectedColor = Theme.background
    var hoverColor = Theme.hover
    /// Whether the close button also shows on the selected item (tabs), or only under the pointer
    /// (workspace rows).
    var closeShowsWhenSelected = true { didSet { updateColors() } }
    /// Whether the trailing button (close, or a workspace row's +) has something to do.
    var hasTrailingAction: Bool { onClose != nil }
    /// Called whenever the close button is shown or hidden.
    func closeVisibilityChanged() {}

    /// How selection shows. `.row` (workspaces): an accent tint, a bar on the leading edge and a semibold
    /// title. `.tab`: an accent tint and an underline. Both turn grey while the window isn't key, as macOS
    /// does. `.plain` keeps the old look (selectedColor).
    enum SelectionStyle { case plain, row, tab }
    var selectionStyle = SelectionStyle.plain {
        didSet { installMarker(); updateColors() }
    }
    /// The selection bar (rows) or underline (tabs).
    private let marker = NSView()
    private var keyObservers: [NSObjectProtocol] = []

    let label = NSTextField(labelWithString: "")
    let closeButton = NSButton()

    init(closable: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = s(6)
        label.font = NSFont.systemFont(ofSize: s(12))
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(.init(pointSize: s(9), weight: .semibold))
        closeButton.isBordered = false
        closeButton.contentTintColor = Theme.dimText
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isHidden = true
        if closable { addSubview(closeButton) }

        var constraints = [
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: s(10)),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if closable {
            constraints += [
                closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: s(-6)),
                closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                closeButton.widthAnchor.constraint(equalToConstant: s(16)),
                closeButton.heightAnchor.constraint(equalToConstant: s(16)),
                label.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: s(-4)),
            ]
        } else {
            constraints.append(label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: s(-10)))
        }
        NSLayoutConstraint.activate(constraints)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        // An item that appears or scrolls under a pointer that isn't moving gets no mouseEntered (or
        // mouseExited), so where the pointer is now decides. AppKit calls this when the view enters a
        // window and when its visible rect changes.
        refreshHover()
    }

    /// Whether the pointer is over the visible part of this item, in its window, with no other window on top.
    func pointerIsOver() -> Bool { Pointer.isOver(self) }

    /// Hover follows where the pointer is now, never the event history: a mouseEntered that arrives late
    /// (the row moved, the pointer left) is checked against the pointer, and the sidebar calls this on
    /// every row whenever rows move, scroll, or the window or app loses focus.
    func refreshHover() { hovering = pointerIsOver() }

    override func mouseEntered(with event: NSEvent) { refreshHover() }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// For tests: hover as if the pointer came over the item or left it.
    func setHovering(_ on: Bool) { hovering = on }
    var isHovering: Bool { hovering }

    /// A click on a row or tab acts even when the window is in the background, the way Finder's
    /// sidebar does, instead of only bringing the window forward (which felt like a missed click).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownAt = event.locationInWindow
        if event.clickCount == 2 { onDoubleClick?() } else { onClick?() }
    }

    // MARK: Dragging (Drag.swift has the drop side)

    /// What dragging this item carries (a tab or a workspace); nil: it doesn't drag.
    var dragPayload: (() -> ChromeDrag.Payload?)?
    private var mouseDownAt: NSPoint?

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownAt, !ChromeDrag.isActive, !isEditing, let payload = dragPayload?() else { return }
        let point = event.locationInWindow
        guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
        mouseDownAt = nil
        let item = NSPasteboardItem()
        item.setString(payload.encoded, forType: ChromeDrag.type)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        dragging.setDraggingFrame(bounds, contents: snapshot())
        ChromeDrag.begin(payload)
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) { mouseDownAt = nil }

    /// The item as it looks now, for the drag image.
    private func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }

    @objc private func closeTapped() { onClose?() }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        session.animatesToStartingPositionsOnCancelOrFail = true
        alphaValue = 0.35
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        alphaValue = 1
        ChromeDrag.end()
    }

    // MARK: Inline rename

    private(set) var editor: NSTextField?
    private var commitEdit: ((String) -> Void)?
    private var clickMonitor: Any?
    /// Called once an edit ends, committed or not.
    var onEditingEnded: (() -> Void)?
    var isEditing: Bool { editor != nil }

    /// Swaps the title for a field with `text` selected, as Finder does. Return or clicking anywhere
    /// else commits; Esc cancels.
    func beginEditing(_ text: String, commit: @escaping (String) -> Void) {
        guard editor == nil, let window else { return }
        let field = NSTextField(string: text)
        field.font = label.font
        field.alignment = label.alignment
        field.textColor = Theme.foreground
        field.backgroundColor = Theme.background
        field.drawsBackground = true
        field.isBordered = false
        field.focusRingType = .none
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        field.wantsLayer = true
        field.layer?.cornerRadius = s(3)
        field.layer?.borderWidth = 1
        field.layer?.borderColor = Theme.accent.cgColor
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: label.leadingAnchor, constant: s(-3)),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: s(-6)),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        label.isHidden = true
        closeButton.isHidden = true
        editor = field
        closeVisibilityChanged()
        commitEdit = commit
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        // A click outside the field commits, even on views that don't take focus (other rows, the bar).
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, let field = editor, event.window === field.window,
               !field.bounds.contains(field.convert(event.locationInWindow, from: nil)) {
                endEditing(commit: true)
            }
            return event
        }
    }

    func endEditing(commit: Bool) {
        guard let field = editor else { return }
        if UserDefaults.standard.bool(forKey: "TraceFocus") { log("focus: inline edit of \(label.stringValue) ends, commit \(commit)") }
        editor = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        let done = commitEdit
        commitEdit = nil
        field.delegate = nil
        // The commit runs first, so the label comes back already showing the new title.
        if commit { done?(text) }
        field.removeFromSuperview()
        label.isHidden = false
        updateColors()
        onEditingEnded?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        withAppearance { updateColors() }
    }

    private func updateColors() {
        closeButton.isHidden = !(hovering || (isSelected && closeShowsWhenSelected)) || !hasTrailingAction || editor != nil
        closeVisibilityChanged()
        guard selectionStyle != .plain else {
            layer?.backgroundColor = (isSelected ? selectedColor : hovering ? hoverColor : .clear).cgColor
            if !colorsOwnTitle { label.textColor = isSelected ? Theme.foreground : Theme.dimText }
            return
        }
        // The accent while the window is key; grey (still visible) while it isn't.
        let active = window?.isKeyWindow ?? true
        let tint = active ? Theme.accent : Theme.dimText
        let fill: NSColor = isSelected ? tint.withAlphaComponent(active ? Self.tintAlpha : 0.16)
            : hovering ? hoverColor : .clear
        layer?.backgroundColor = fill.cgColor
        marker.isHidden = !isSelected
        marker.layer?.backgroundColor = tint.cgColor
        if !colorsOwnTitle { label.textColor = isSelected ? Theme.foreground : restingTextColor ?? Theme.dimText }
        if selectionStyle == .row, let size = label.font?.pointSize {
            label.font = NSFont.systemFont(ofSize: size, weight: isSelected ? .semibold : .regular)
        }
        if showsCursor { layer?.borderColor = Theme.accent.withAlphaComponent(0.8).cgColor }
    }

    /// The selection tint's opacity over the sidebar and tab bar.
    static let tintAlpha: CGFloat = 0.22

    private func installMarker() {
        guard selectionStyle != .plain, marker.superview == nil else { return }
        marker.wantsLayer = true
        marker.translatesAutoresizingMaskIntoConstraints = false
        addSubview(marker, positioned: .below, relativeTo: nil)
        switch selectionStyle {
        case .row:
            // A 3 pt bar on the leading edge, inside the rounded highlight.
            marker.layer?.cornerRadius = s(1.5)
            NSLayoutConstraint.activate([
                marker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: s(3)),
                marker.widthAnchor.constraint(equalToConstant: s(3)),
                marker.topAnchor.constraint(equalTo: topAnchor, constant: s(6)),
                marker.bottomAnchor.constraint(equalTo: bottomAnchor, constant: s(-6)),
            ])
        case .tab:
            // A 2 pt underline along the bottom edge.
            marker.layer?.cornerRadius = s(1)
            NSLayoutConstraint.activate([
                marker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: s(8)),
                marker.trailingAnchor.constraint(equalTo: trailingAnchor, constant: s(-8)),
                marker.heightAnchor.constraint(equalToConstant: s(2)),
                marker.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        case .plain:
            break
        }
    }

    // Selection turns grey while the window isn't key, and back to the accent when it is.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyObservers.forEach(NotificationCenter.default.removeObserver)
        keyObservers = []
        guard let window, selectionStyle != .plain else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateColors() }
            })
        }
        updateColors()
    }
}

extension ChromeItem: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            endEditing(commit: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endEditing(commit: false)
            return true
        default:
            return false
        }
    }

    // Focus moving elsewhere (another window, the terminal) commits too.
    func controlTextDidEndEditing(_ obj: Notification) { endEditing(commit: true) }
}

/// Titles the user just committed in place. The rename takes a round trip to the daemon, and the
/// views redraw from the model meanwhile, so each shows its held title until the model has the new
/// one. A rename that never arrives (it failed) lets go after a few seconds.
struct HeldTitles<Key: Hashable> {
    static var lifetime: TimeInterval { 3 }
    private var held: [Key: (from: String?, to: String, until: Date)] = [:]

    /// `from` is the title the model has. Renaming again before it caught up keeps the first one.
    mutating func hold(_ key: Key, from: String?, to: String) {
        var from = from
        if let earlier = held[key], Date() < earlier.until { from = earlier.from }
        held[key] = (from, to, Date().addingTimeInterval(Self.lifetime))
    }

    /// The title to show instead of the model's, while the model still has the old one.
    mutating func title(for key: Key, model: String?) -> String? {
        guard let entry = held[key] else { return nil }
        if model == entry.from, Date() < entry.until { return entry.to }
        held[key] = nil
        return nil
    }
}

final class TabBarView: NSView {
    static var height: CGFloat { s(40) }

    var onSelect: ((TabID) -> Void)?
    var onClose: ((TabID) -> Void)?
    /// A tab's title was edited in place (an empty title goes back to the pane's).
    var onRename: ((TabID, String) -> Void)?
    var onNewTab: (() -> Void)?
    /// After an inline edit ends, so the terminal can take focus back.
    var onEditingEnded: (() -> Void)?

    // Dragging tabs (Drag.swift): to reorder in the bar, or onto a workspace in the sidebar.
    /// The machine and workspace the bar shows, which a dragged tab carries.
    var machine: MachineKey = AppDelegate.localKey
    var workspace: WorkspaceID?
    /// Whether tabs can be dragged now (the machine's daemon has `move`).
    var canDrag: () -> Bool = { false }
    /// A tab dropped at `index` among the others.
    var onMoveTab: ((TabID, Int) -> Void)?
    /// The tabs in order, for drop positions.
    private(set) var order: [TabID] = []
    let dropLine = DropIndicator()

    private let stack = NSStackView()
    private var items: [TabID: (item: ChromeItem, title: String, custom: String?)] = [:]
    /// The latest update, held back while a title is being edited so the field isn't rebuilt away.
    private var pending: (() -> Void)?
    /// The latest update, to redraw once a held title lets go.
    private var latest: (() -> Void)?
    private var heldTitles = HeldTitles<TabID>()
    private let addButton = NSButton()
    /// The bar's own constraints, with their sizes at 100%.
    private var scaled: [(NSLayoutConstraint, CGFloat)] = []

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        withAppearance { layer?.backgroundColor = Theme.sidebar.cgColor }
    }

    /// Re-applies the app zoom to what's built once; the tabs themselves are rebuilt by update.
    func applyScale() {
        for (constraint, points) in scaled { constraint.constant = s(points) }
        stack.spacing = s(4)
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")?
            .withSymbolConfiguration(.init(pointSize: s(12), weight: .medium))
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.sidebar.cgColor
        stack.orientation = .horizontal
        stack.spacing = s(4)
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")?
            .withSymbolConfiguration(.init(pointSize: s(11), weight: .medium))
        addButton.isBordered = false
        addButton.contentTintColor = Theme.dimText
        addButton.target = self
        addButton.action = #selector(addTapped)
        addButton.toolTip = "New Tab (⌘T)"
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(addButton)

        // Built once, so kept with their sizes at 100% for applyScale. Tabs are 32 pt in the 40 pt bar.
        scaled = [
            (stack.leadingAnchor.constraint(equalTo: leadingAnchor), 6),
            (stack.topAnchor.constraint(equalTo: topAnchor), 4),
            (stack.bottomAnchor.constraint(equalTo: bottomAnchor), -4),
            (addButton.leadingAnchor.constraint(equalTo: stack.trailingAnchor), 6),
            (addButton.widthAnchor.constraint(equalToConstant: 0), 24),
            (addButton.heightAnchor.constraint(equalToConstant: 0), 24),
            (addButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor), -8),
        ]
        applyScale()
        NSLayoutConstraint.activate(scaled.map(\.0) + [
            addButton.centerYAnchor.constraint(equalTo: stack.centerYAnchor),
        ])
        addSubview(dropLine)
        registerForDraggedTypes([ChromeDrag.type])
        NotificationCenter.default.addObserver(forName: ChromeDrag.ended, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dropLine.hide()
                self?.runPending()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(tabs: [(id: TabID, title: String, custom: String?, maximized: Bool, badge: NSColor?)], selected: TabID?) {
        latest = { [weak self] in self?.update(tabs: tabs, selected: selected) }
        // Held while a title is edited, or a drag is in flight (rebuilding would remove what's dragged).
        if items.values.contains(where: { $0.item.isEditing }) || ChromeDrag.isActive {
            pending = latest
            return
        }
        // Only the selection changed (a click): the tabs stay, so one being pressed can still be dragged.
        let shape = tabs.map { TabShape(id: $0.id, title: $0.title, custom: $0.custom, maximized: $0.maximized, badge: $0.badge) }
        if shape == lastShape, !items.isEmpty {
            for (id, entry) in items { entry.item.isSelected = id == selected }
            return
        }
        lastShape = shape
        order = tabs.map(\.id)
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        items = [:]
        widths = []
        let width = Self.tabWidth(count: tabs.count, barWidth: bounds.width)
        for (index, var tab) in tabs.enumerated() {
            if let held = heldTitles.title(for: tab.id, model: tab.custom) { (tab.title, tab.custom) = (held, held) }
            let item = ChromeItem(closable: true)
            item.selectionStyle = .tab
            items[tab.id] = (item, tab.title, tab.custom)
            item.label.stringValue = (tab.maximized ? "⤢ " : "") + tab.title
            item.label.alignment = .center
            item.label.font = NSFont.systemFont(ofSize: s(13))
            // The title fills the space between the dot's slot and the ×'s, both always kept, and truncates
            // there: nothing in a tab moves when a dot or the × comes and goes.
            item.constraints.filter { $0.firstItem === item.label && $0.firstAttribute == .leading }.forEach { $0.constant = Self.dotSlot }
            item.constraints.filter { $0.firstItem === item.label && $0.firstAttribute == .trailing }.forEach { $0.isActive = false }
            item.label.trailingAnchor.constraint(equalTo: item.closeButton.leadingAnchor, constant: s(-4)).isActive = true
            item.toolTip = index < 9 ? "\(tab.title) (⌘\(index + 1))" : tab.title
            item.onClick = { [weak self] in self?.onSelect?(tab.id) }
            item.dragPayload = { [weak self] in
                guard let self, canDrag(), let workspace else { return nil }
                return ChromeDrag.Payload(kind: .tab, machine: machine, id: tab.id, workspace: workspace)
            }
            item.onDoubleClick = { [weak self] in self?.beginRename(tab.id) }
            item.onClose = { [weak self] in self?.onClose?(tab.id) }
            item.isSelected = tab.id == selected
            if let badge = tab.badge {
                // An agent in this tab: a dot in the slot at the tab's leading edge.
                let dot = NSView()
                dot.wantsLayer = true
                dot.layer?.cornerRadius = s(3)
                dot.layer?.backgroundColor = badge.cgColor
                dot.translatesAutoresizingMaskIntoConstraints = false
                item.addSubview(dot)
                NSLayoutConstraint.activate([
                    dot.leadingAnchor.constraint(equalTo: item.leadingAnchor, constant: s(9)),
                    dot.centerYAnchor.constraint(equalTo: item.centerYAnchor),
                    dot.widthAnchor.constraint(equalToConstant: s(6)),
                    dot.heightAnchor.constraint(equalToConstant: s(6)),
                ])
            }
            stack.addArrangedSubview(item)
            let constraint = item.widthAnchor.constraint(equalToConstant: width)
            // Below the window's own resize priorities, so tabs never hold the window wide; layout() sets
            // the new width as soon as the bar's changes.
            constraint.priority = NSLayoutConstraint.Priority(490)
            constraint.isActive = true
            widths.append(constraint)
        }
        if UserDefaults.standard.bool(forKey: "LogSidebar") {
            log("tabs: " + stack.arrangedSubviews.compactMap { ($0 as? ChromeItem)?.label.stringValue }.joined(separator: ", ")
                + " at \(Int(Self.tabWidth(count: tabs.count, barWidth: bounds.width))) pt each")
        }
    }

    func runPending() {
        let update = pending
        pending = nil
        update?()
    }

    /// The last tabs built, to tell a selection-only update apart.
    private var lastShape: [TabShape]?
    private struct TabShape: Equatable {
        var id: TabID, title: String, custom: String?, maximized: Bool, badge: NSColor?
    }

    /// Every tab's width: the bar shared equally, between a minimum and a maximum. It depends only on
    /// the number of tabs and the bar's width, never on titles, dots, hover or selection, so tabs don't
    /// jump when an agent retitles its pane or a tab is selected.
    static func tabWidth(count: Int, barWidth: CGFloat) -> CGFloat {
        guard count > 0 else { return maxTabWidth }
        // The stack's leading inset, then the + button with its spacing and the trailing margin.
        let available = barWidth - s(6) - s(6) - s(24) - s(8) - s(4) * CGFloat(count - 1)
        return min(maxTabWidth, max(minTabWidth, (available / CGFloat(count)).rounded(.down)))
    }
    static var maxTabWidth: CGFloat { s(240) }
    static var minTabWidth: CGFloat { s(72) }
    /// Room at a tab's leading edge for its agent dot, kept whether or not there is one.
    static var dotSlot: CGFloat { s(22) }
    private var widths: [NSLayoutConstraint] = []

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { needsLayout = true }
    }

    /// Tabs keep their width until the bar's width changes (the window or sidebar resizing).
    override func layout() {
        super.layout()
        let width = Self.tabWidth(count: widths.count, barWidth: bounds.width)
        guard let current = widths.first?.constant, current != width else { return }
        widths.forEach { $0.constant = width }
    }

    /// A tab's frame in the bar's coordinates (drops).
    func frameOfTab(_ id: TabID) -> NSRect? {
        items[id].map { convert($0.item.frame, from: $0.item.superview) }
    }

    /// The tabs' frames (tests and the LogSidebar aid).
    var tabFrames: [NSRect] { stack.arrangedSubviews.map(\.frame) }

    /// Whether a tab's name is being edited (the window leaves the keyboard alone meanwhile).
    var isEditing: Bool { items.values.contains { $0.item.isEditing } }

    /// Edits a tab's title in place, starting from the title it shows.
    func beginRename(_ id: TabID) {
        guard let (item, shown, custom) = items[id] else { return }
        item.onEditingEnded = { [weak self] in
            self?.onEditingEnded?()
            self?.runPending()
        }
        let prefix = item.label.stringValue.hasPrefix("⤢ ") ? "⤢ " : ""
        item.beginEditing(custom ?? shown) { [weak self] text in
            // Committing the pane's own title unchanged leaves the tab following it.
            guard let self, text != (custom ?? shown) else { return }
            // An empty title goes back to the pane's, which only the model knows.
            if !text.isEmpty {
                item.label.stringValue = prefix + text
                heldTitles.hold(id, from: custom, to: text)
                redrawWhenHeldTitlesExpire()
            }
            onRename?(id, text)
        }
    }

    private func redrawWhenHeldTitlesExpire() {
        DispatchQueue.main.asyncAfter(deadline: .now() + HeldTitles<TabID>.lifetime + 0.1) { [weak self] in
            guard let self, !items.values.contains(where: { $0.item.isEditing }) else { return }
            latest?()
        }
    }

    @objc private func addTapped() { onNewTab?() }

    // Clicks on empty tab bar space drag the window; a double-click zooms it.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            NSApp.sendAction(#selector(AppDelegate.zoomWindow(_:)), to: nil, from: self)
        } else {
            window?.performDrag(with: event)
        }
    }
}

final class SidebarView: NSView {
    static let width: CGFloat = 190
    /// Room at the top for the window buttons.
    static let topInset: CGFloat = 34

    var onSelect: ((MachineKey, WorkspaceID) -> Void)?

    // Dragging (Drag.swift): workspaces reorder within their machine; a tab from the bar drops on another
    // workspace of its machine.
    /// Whether this machine's workspaces and tabs can be dragged (its daemon has `move`).
    var canDrag: (MachineKey) -> Bool = { _ in false }
    /// A workspace dropped at `index` among its machine's others.
    var onMoveWorkspace: ((MachineKey, WorkspaceID, Int) -> Void)?
    /// A tab dropped on a workspace.
    var onMoveTab: ((MachineKey, TabID, WorkspaceID) -> Void)?
    let dropLine = DropIndicator()
    let dropTarget = DropTargetHighlight()

    /// A workspace's name was edited in place.
    var onRename: ((MachineKey, WorkspaceID, String) -> Void)?
    /// After an inline edit ends, so the terminal can take focus back.
    var onEditingEnded: (() -> Void)?
    private var rows: [String: (row: WorkspaceRow, name: String)] = [:]
    /// A workspace row's + (a new tab in that workspace).
    var onNewTab: ((MachineKey, WorkspaceID) -> Void)?
    /// Esc in the sidebar: the terminal takes the keyboard back.
    var onFocusTerminal: (() -> Void)?

    /// A row the keyboard can move to.
    enum Item: Hashable {
        case workspace(MachineKey, WorkspaceID)
    }
    /// The rows in order, top to bottom, as the arrow keys walk them.
    private(set) var order: [Item] = []
    private var itemRows: [Item: SidebarRow] = [:]
    /// The selected row: the focused workspace's.
    private var selectedItem: Item?
    /// The keyboard's row while the sidebar has keyboard focus.
    private(set) var cursor: Item?
    /// The latest update, to redraw once a held title lets go.
    private var latest: (() -> Void)?
    private var heldNames = HeldTitles<String>()
    /// Machines whose workspaces are hidden, remembered across launches.
    private var collapsed = Set(UserDefaults.standard.stringArray(forKey: "CollapsedMachines") ?? [])

    func toggleCollapsed(_ machine: MachineKey) {
        if collapsed.contains(machine) { collapsed.remove(machine) } else { collapsed.insert(machine) }
        UserDefaults.standard.set(collapsed.sorted(), forKey: "CollapsedMachines")
        latest?()
    }

    func isCollapsed(_ machine: MachineKey) -> Bool { collapsed.contains(machine) }

    /// Opens a machine's group, so a workspace being renamed or just made is visible.
    func expand(_ machine: MachineKey) {
        if collapsed.contains(machine) { toggleCollapsed(machine) }
    }
    /// The latest update, held back while a name is being edited so the field isn't rebuilt away.
    private var pending: (() -> Void)?
    var onClose: ((MachineKey, WorkspaceID) -> Void)?
    var onConnect: ((MachineKey) -> Void)?
    var onAddMachine: (() -> Void)?
    /// A machine's New Workspace (the header's +, or the row of a machine with none).
    var onCreateWorkspace: ((MachineKey) -> Void)?
    /// The footer's Manage Machines….
    var onManageMachines: (() -> Void)?
    /// The footer, pinned under the Agents panel (for tests).
    private(set) var footer: SidebarFooter!
    var machineMenu: ((MachineKey) -> NSMenu)?

    // Two panels, as in herdr: on top, one column grouped by machine (this Mac, then each saved SSH
    // machine, each with its workspaces); at the bottom, every agent on every machine. A divider between
    // them sets the agents panel's height.
    private let column = NSStackView()
    private let agentsColumn = NSStackView()
    private var agentsHeight: NSLayoutConstraint!
    static let agentsHeightRange: ClosedRange<CGFloat> = 90...900

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.sidebar.cgColor

        let scroll = Self.scrollingColumn(column)
        let agentsScroll = Self.scrollingColumn(agentsColumn)
        let divider = AgentsDivider()
        divider.onDrag = { [weak self] y in self?.setAgentsHeight(y) }
        divider.onEnd = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(Double(agentsHeight.constant), forKey: "AgentsPanelHeight")
        }
        footer = SidebarFooter(frame: .zero)
        footer.onMachines = { [weak self] in self?.onManageMachines?() }
        for view in [scroll, divider, agentsScroll, footer!] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // Rows that scroll under a still pointer get no enter or exit events.
        for clip in [scroll.contentView, agentsScroll.contentView] {
            clip.postsBoundsChangedNotifications = true
            hoverObservers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshHover() }
            })
        }
        let saved = CGFloat(UserDefaults.standard.double(forKey: "AgentsPanelHeight"))
        agentsHeight = agentsScroll.heightAnchor.constraint(equalToConstant: saved > 0 ? saved : 220)
        // The workspaces panel keeps some room even when the window is short.
        let sessionsMinimum = scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80)
        agentsHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: Self.topInset),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: divider.topAnchor),
            sessionsMinimum,
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 9),
            divider.bottomAnchor.constraint(equalTo: agentsScroll.topAnchor),
            agentsScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            agentsScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            agentsScroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            agentsHeight,
            // Always visible, outside the scrolling lists.
            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        for overlay in [dropTarget, dropLine] as [NSView] { addSubview(overlay) }
        registerForDraggedTypes([ChromeDrag.type])
        NotificationCenter.default.addObserver(forName: ChromeDrag.ended, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dropLine.hide()
                self?.dropTarget.hide()
                self?.runPending()
            }
        }

        let handle = ResizeHandle()
        handle.onDrag = { [weak self] x in self?.onResize?(x) }
        handle.onEnd = { [weak self] in self?.onResizeEnd?() }
        handle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(handle)
        NSLayoutConstraint.activate([
            handle.topAnchor.constraint(equalTo: topAnchor),
            handle.bottomAnchor.constraint(equalTo: bottomAnchor),
            handle.trailingAnchor.constraint(equalTo: trailingAnchor),
            handle.widthAnchor.constraint(equalToConstant: 5),
        ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        withAppearance { layer?.backgroundColor = Theme.sidebar.cgColor }
    }

    /// Re-applies the app zoom to the columns, which are built once; their rows are rebuilt by update.
    func applyScale() {
        footer.applyScale()
        for stack in [column, agentsColumn] {
            stack.spacing = Self.rowSpacing
            stack.edgeInsets = NSEdgeInsets(top: s(6), left: s(8), bottom: s(12), right: s(8))
        }
    }

    /// A vertical stack in a scroll view that hides its scroller when idle.
    private static func scrollingColumn(_ column: NSStackView) -> NSScrollView {
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = rowSpacing
        column.edgeInsets = NSEdgeInsets(top: s(6), left: s(8), bottom: s(12), right: s(8))
        let document = FlippedView()
        document.addSubview(column)
        column.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            column.topAnchor.constraint(equalTo: document.topAnchor),
            column.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        return scroll
    }

    /// `y` is the pointer's height above the sidebar's bottom edge.
    private func setAgentsHeight(_ y: CGFloat) {
        let maximum = max(Self.agentsHeightRange.lowerBound, bounds.height - Self.topInset - 90)
        agentsHeight.constant = min(max(y.rounded(), Self.agentsHeightRange.lowerBound), min(maximum, Self.agentsHeightRange.upperBound))
    }

    required init?(coder: NSCoder) { fatalError() }

    // Vertical rhythm: rows sit close together, a machine's header a little apart from its rows,
    // and machines clearly apart from each other.
    static var rowHeight: CGFloat { s(28) }
    static var rowSpacing: CGFloat { s(2) }
    static var groupSpacing: CGFloat { s(18) }

    var onOpenAgent: ((MachineKey, PaneID) -> Void)?
    /// The checkmark on an agent that needs attention.
    var onResolveAgent: ((MachineKey, PaneID) -> Void)?
    /// The bell.slash next to it.
    var onMuteAgent: ((MachineKey, PaneID) -> Void)?
    var agentRowMenu: ((MachineKey, PaneID, Bool) -> NSMenu)?
    var agentsMenu: (() -> NSMenu)?

    func update(agents: [AgentEntry], unreachable: [(name: String, reason: String)], groups: [SidebarGroup]) {
        latest = { [weak self] in self?.update(agents: agents, unreachable: unreachable, groups: groups) }
        // Held while a name is edited, or a drag is in flight (rebuilding would remove what's dragged).
        if isEditing || ChromeDrag.isActive {
            pending = latest
            return
        }
        // A click changes only the selection: move it on the rows there are rather than building them
        // all again (a rebuild costs tens of milliseconds, and it delayed the click's highlight).
        let signature = layoutSignature(agents: agents, unreachable: unreachable, groups: groups)
        if signature == lastSignature, column.arrangedSubviews.count > 0 {
            applySelection(groups)
            return
        }
        lastSignature = signature
        rows = [:]
        order = []
        itemRows = [:]
        selectedItem = nil
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        agentsColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // The agents panel: agents that need the user on top, each with a checkmark to resolve it; every
        // other agent (running, idle, resolved) in a section below, collapsed unless opened.
        let (attention, others) = AgentEntry.split(agents)
        let agentsHeader = MachineHeader(title: attention.isEmpty ? "Agents" : "Agents · \(attention.count)",
                                         status: (attention.isEmpty ? nil : AgentInfo.State.waiting.color, nil), newWorkspaceTooltip: nil)
        agentsHeader.contextMenu = { [weak self] in self?.agentsMenu?() }
        add(agentsHeader, to: agentsColumn)
        agentsColumn.setCustomSpacing(s(4), after: agentsHeader)
        let addAgent = { [weak self] (entry: AgentEntry, resolvable: Bool) in
            guard let self else { return }
            let row = AgentRow(entry, onResolve: resolvable ? { [weak self] in self?.onResolveAgent?(entry.machine, entry.pane) } : nil,
                               onMute: resolvable && entry.canMute ? { [weak self] in self?.onMuteAgent?(entry.machine, entry.pane) } : nil)
            row.onClick = { [weak self] in self?.onOpenAgent?(entry.machine, entry.pane) }
            row.contextMenu = { [weak self] in self?.agentRowMenu?(entry.machine, entry.pane, entry.offersReplies) }
            add(row, height: s(40), to: agentsColumn)
        }
        attention.forEach { addAgent($0, true) }
        if attention.isEmpty, !others.isEmpty {
            add(note("Nothing needs you", tooltip: "Agents show here when they finish, fail or wait for you.", color: Theme.dimText),
                to: agentsColumn)
        }
        if !others.isEmpty {
            let expanded = UserDefaults.standard.bool(forKey: "AgentsOthersExpanded")
            let section = DisclosureRow(title: "Quiet", count: others.count, expanded: expanded)
            section.toolTip = "Agents that don't need you: running, idle or resolved"
            section.onClick = { [weak self, weak section] in
                section?.chevron.setExpanded(!expanded, animated: true) {
                    UserDefaults.standard.set(!expanded, forKey: "AgentsOthersExpanded")
                    self?.latest?()
                }
            }
            if let last = agentsColumn.arrangedSubviews.last { agentsColumn.setCustomSpacing(s(6), after: last) }
            add(section, height: s(26), to: agentsColumn)
            agentsColumn.setCustomSpacing(s(2), after: section)
            if expanded { others.forEach { addAgent($0, false) } }
        }
        if UserDefaults.standard.bool(forKey: "LogSidebar") {
            let names = { (list: [AgentEntry]) in list.map { "\($0.pane):\($0.info.state.rawValue)" }.joined(separator: " ") }
            log("agents: attention [\(names(attention))] others [\(names(others))]")
        }
        for machine in unreachable {
            add(note("\(machine.name) is unreachable, so its agents aren't shown", tooltip: machine.reason, color: AgentInfo.State.error.color),
                to: agentsColumn)
        }
        if agents.isEmpty && unreachable.isEmpty {
            add(note("No agents running", tooltip: "Claude Code and Codex running in any pane show up here.", color: Theme.dimText),
                to: agentsColumn)
        }

        for (index, group) in groups.enumerated() {
            if index > 0, let last = column.arrangedSubviews.last { column.setCustomSpacing(Self.groupSpacing, after: last) }
            let key = group.key
            // Every machine's group collapses, connected or not, so all names line up after the chevron.
            let isCollapsed = collapsed.contains(key)
            let header = MachineHeader(title: group.title, status: group.status,
                                       newWorkspaceTooltip: Self.createWorkspaceTooltip(group),
                                       collapsed: isCollapsed, count: group.isConnected ? group.workspaces.count : 0)
            header.onNewWorkspace = { [weak self] in self?.onCreateWorkspace?(key) }
            header.onToggle = { [weak self, weak header] in
                header?.chevron?.setExpanded(isCollapsed, animated: true) { self?.toggleCollapsed(key) }
            }
            header.contextMenu = { [weak self] in self?.machineMenu?(key) }
            add(header)
            column.setCustomSpacing(s(4), after: header)
            if isCollapsed {
                if UserDefaults.standard.bool(forKey: "LogSidebar") { log("sidebar: \(group.title) collapsed (\(group.workspaces.count))") }
                continue
            }
            guard group.isConnected else {
                add(actionButton("Connect", symbol: "arrow.right", tooltip: "Connect to \(group.title) and show its workspaces",
                                 inset: MachineHeader.nameInset - 2) { [weak self] in
                    self?.onConnect?(key)
                })
                continue
            }
            for workspace in group.workspaces {
                addWorkspace(workspace, of: group)
            }
            // The header's + makes workspaces; a machine with none also says so in its list.
            if group.workspaces.isEmpty { addCreateWorkspace(for: group) }
        }
        if let cursor, !order.contains(cursor) { self.cursor = selectedItem ?? order.first }
        updateCursor()
        if UserDefaults.standard.bool(forKey: "LogSidebar") {
            log("sidebar: " + rows.values.map(\.name).sorted().joined(separator: ", "))
            log("sidebar rows: " + order.map { item in
                let row = itemRows[item]!
                return row.label.stringValue + (row.isSelected ? "*" : "")
            }.joined(separator: " | "))
        }
        refreshHoverSoon()
        startArrivedRename()
    }

    /// Everything the rows show, apart from which one is selected.
    private var lastSignature = ""

    // MARK: Hover

    private var hoverObservers: [NSObjectProtocol] = []
    private var windowObservers: [NSObjectProtocol] = []
    private var hoverCheck: Timer?

    /// Every hover look in the sidebar (rows, toggles, the headers' +), from where the pointer is now:
    /// only what is under it, and nothing once it has left. Enter and exit events alone can't be trusted:
    /// rows move, scroll and are rebuilt under a pointer that isn't moving, and an exit can go missing.
    func refreshHover() {
        var any = false
        func walk(_ view: NSView) {
            for sub in view.subviews {
                if let item = sub as? HoverRefreshing {
                    item.refreshHover()
                    any = any || item.isHovering
                }
                walk(sub)
            }
        }
        walk(self)
        // While anything shows hover, look again twice a second, so a hover can never outlive the pointer.
        if any, hoverCheck == nil {
            hoverCheck = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshHover() }
            }
        } else if !any {
            hoverCheck?.invalidate()
            hoverCheck = nil
        }
    }

    /// Rows were rebuilt, moved or reselected: once they are laid out, hover follows the pointer.
    private func refreshHoverSoon() {
        DispatchQueue.main.async { [weak self] in self?.refreshHover() }
    }

    override func layout() {
        super.layout()
        refreshHover()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { refreshHover() }
    override func mouseMoved(with event: NSEvent) { refreshHover() }
    override func mouseExited(with event: NSEvent) { refreshHover() }

    // The window losing focus, hiding, resizing or changing spaces, or the app going to the background,
    // can each swallow an exit.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        guard let window else {
            hoverCheck?.invalidate()
            hoverCheck = nil
            return
        }
        let windowNames: [Notification.Name] = [
            NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResizeNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
        ]
        let appNames: [Notification.Name] = [
            NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification, NSApplication.didHideNotification,
        ]
        for (names, object) in [(windowNames, window as AnyObject), (appNames, NSApp as AnyObject)] {
            for name in names {
                windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshHover() }
                })
            }
        }
        refreshHover()
    }

    private func layoutSignature(agents: [AgentEntry], unreachable: [(name: String, reason: String)], groups: [SidebarGroup]) -> String {
        var parts: [String] = ["\(UIScale.factor) \(effectiveAppearance.name.rawValue)", collapsed.sorted().joined(separator: ","),
                               "\(UserDefaults.standard.bool(forKey: "AgentsOthersExpanded"))"]
        for agent in agents {
            parts.append("a \(agent.machine) \(agent.machineName) \(agent.pane) \(agent.paneTitle ?? "") \(agent.tabTitle ?? "") "
                         + "\(agent.workspace?.name ?? "") \(agent.canReply) \(agent.canMute) \(agent.info)")
        }
        for machine in unreachable { parts.append("u \(machine.name) \(machine.reason)") }
        for group in groups {
            parts.append("g \(group.key) \(group.title) \(String(describing: group.status.color)) \(group.status.text ?? "") "
                         + "\(group.isConnected) \(group.isLocal)")
            for workspace in group.workspaces {
                let rowKey = Self.rowKey(group.key, workspace.id)
                parts.append("w \(workspace.id) \(heldNames.title(for: rowKey, model: workspace.name) ?? workspace.name) "
                             + "\(String(describing: group.badges[workspace.id]))")
            }
        }
        return parts.joined(separator: "\n")
    }

    /// The selection rules of `addWorkspace`, applied to the rows already there.
    private func applySelection(_ groups: [SidebarGroup]) {
        selectedItem = nil
        for group in groups where !collapsed.contains(group.key) && group.isConnected {
            for workspace in group.workspaces {
                let rowKey = Self.rowKey(group.key, workspace.id)
                guard let row = rows[rowKey]?.row else { continue }
                row.isSelected = workspace.id == group.selected
                if row.isSelected { selectedItem = .workspace(group.key, workspace.id) }
            }
        }
        if let cursor, !order.contains(cursor) { self.cursor = selectedItem ?? order.first }
        updateCursor()
        if UserDefaults.standard.bool(forKey: "LogSidebar") { log("sidebar: selection moved") }
        refreshHoverSoon()
        startArrivedRename()
    }

    /// A name is being edited in place (the sidebar holds its updates until it ends).
    var isEditing: Bool {
        rows.values.contains { $0.row.isEditing }
    }

    /// A workspace's row: its name, and its most urgent agent's dot on the trailing edge.
    private func addWorkspace(_ workspace: Workspace, of group: SidebarGroup) {
        let key = group.key
        let rowKey = Self.rowKey(key, workspace.id)
        let row = WorkspaceRow()
        row.onNewTab = { [weak self] in self?.onNewTab?(key, workspace.id) }
        let name = heldNames.title(for: rowKey, model: workspace.name) ?? workspace.name
        row.label.stringValue = name
        row.toolTip = workspace.tabs.count == 1 ? "1 tab" : "\(workspace.tabs.count) tabs"
        row.onClick = { [weak self] in self?.onSelect?(key, workspace.id) }
        row.dragPayload = { [weak self] in
            guard let self, canDrag(key) else { return nil }
            return ChromeDrag.Payload(kind: .workspace, machine: key, id: workspace.id, workspace: workspace.id)
        }
        row.onDoubleClick = { [weak self] in self?.beginRename(key, workspace.id) }
        row.onClose = { [weak self] in self?.onClose?(key, workspace.id) }
        row.contextMenu = { [weak self] in self?.workspaceMenu(key, workspace.id) }
        rows[rowKey] = (row, name)
        row.isSelected = workspace.id == group.selected
        row.setBadge(group.badges[workspace.id])
        add(row, height: Self.rowHeight)
        let item = Item.workspace(key, workspace.id)
        order.append(item)
        itemRows[item] = row
        if row.isSelected { selectedItem = item }
    }

    /// The quiet New Workspace row's height.
    static var quietRowHeight: CGFloat { s(24) }

    /// A workspace row's right-click menu. Close lives here (and ⇧⌘W), not on the row.
    func workspaceMenu(_ machine: MachineKey, _ id: WorkspaceID) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "New Tab") { [weak self] in self?.onNewTab?(machine, id) })
        menu.addItem(ClosureMenuItem(title: "Rename Workspace") { [weak self] in self?.beginRename(machine, id) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Close Workspace…") { [weak self] in self?.onClose?(machine, id) })
        return menu
    }

    // MARK: Keyboard

    /// Whether the sidebar has the keyboard (View ▸ Move Focus to Sidebar). Only then does it take first
    /// responder, so a click on its empty space never takes typing away from the terminal.
    private var wantsKeyboard = false
    override var acceptsFirstResponder: Bool { wantsKeyboard }
    var hasKeyboard: Bool { window?.firstResponder === self }

    /// Takes the keyboard, with the cursor on the selected row.
    func takeKeyboard() {
        wantsKeyboard = true
        cursor = selectedItem ?? order.first
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        defer { updateCursor() }
        return true
    }

    override func resignFirstResponder() -> Bool {
        // An inline rename borrows the keyboard and gives it back.
        if !isEditing { wantsKeyboard = false }
        DispatchQueue.main.async { [weak self] in self?.updateCursor() }
        return true
    }

    private func updateCursor() {
        let shown = hasKeyboard ? cursor : nil
        for (item, row) in itemRows { row.showsCursor = item == shown }
        if let shown, let row = itemRows[shown] { row.scrollToVisible(row.bounds) }
    }

    /// ↑ ↓ move through workspace rows, selecting as they go; Return renames; Esc goes back to the terminal.
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: move(by: -1)
        case 125: move(by: 1)
        case 36, 76:
            if case .workspace(let key, let id) = cursor { beginRename(key, id) }
        case 53:
            wantsKeyboard = false
            onFocusTerminal?()
        default:
            super.keyDown(with: event)
        }
    }

    private func move(by step: Int) {
        guard !order.isEmpty else { return }
        let index = cursor.flatMap { order.firstIndex(of: $0) } ?? (step > 0 ? -1 : order.count)
        let next = min(max(index + step, 0), order.count - 1)
        guard next != index else { return }
        go(to: order[next])
    }

    private func go(to item: Item) {
        cursor = item
        updateCursor()
        if case .workspace(let key, let id) = item { onSelect?(key, id) }
    }

    static func createWorkspaceTooltip(_ group: SidebarGroup) -> String {
        group.isConnected
            ? (group.isLocal ? "New Workspace on this Mac (⌘N)" : "New Workspace on \(group.title)")
            : "Connect to \(group.title) and make a workspace there"
    }

    /// A quiet "New Workspace" row, for a machine that has none: dim text in line with the workspace
    /// names, brightening under the pointer.
    private func addCreateWorkspace(for group: SidebarGroup) {
        let key = group.key
        let row = ChromeItem(closable: false)
        row.label.stringValue = "New Workspace"
        row.label.font = NSFont.systemFont(ofSize: s(12))
        row.constraints.filter { $0.firstItem === row.label && $0.firstAttribute == .leading }.forEach { $0.constant = MachineHeader.nameInset }
        row.toolTip = Self.createWorkspaceTooltip(group)
        row.onClick = { [weak self] in self?.onCreateWorkspace?(key) }
        row.setAccessibilityLabel("New Workspace")
        add(row, height: Self.quietRowHeight)
        if UserDefaults.standard.bool(forKey: "LogSidebar") { log("sidebar: \(group.title): New Workspace row") }
    }

    private func runPending() {
        let update = pending
        pending = nil
        update?()
    }

    /// A machine's workspace rows, top to bottom (drops; collapsed machines have none).
    func workspaceRows(of machine: MachineKey) -> [(id: WorkspaceID, row: SidebarRow)] {
        order.compactMap { item in
            guard case .workspace(let key, let id) = item, key == machine, let row = itemRows[item] else { return nil }
            return (id, row)
        }
    }

    private static func rowKey(_ machine: MachineKey, _ id: WorkspaceID) -> String { "\(machine)/\(id)" }

    /// A workspace just made here, renamed as soon as its row is listed (New Workspace is make + rename
    /// in one action). It waits for the daemon's model rather than a placeholder row, so a rebuild in
    /// between, or a remote machine's round trip, can't take the field away.
    private var renameOnArrival: (machine: MachineKey, id: WorkspaceID)?

    /// Starts the inline rename of a new workspace once its row is in the sidebar (now, if it already is).
    /// Return names it, Esc or an empty name keeps the default, and either way the terminal gets the keyboard.
    func renameWhenListed(_ machine: MachineKey, _ id: WorkspaceID) {
        renameOnArrival = (machine, id)
        startArrivedRename()
    }

    /// Called after every update: begins a waiting rename once its row exists. One turn of the run loop
    /// later, so the window's own focus changes for the new workspace have happened first.
    private func startArrivedRename() {
        guard let target = renameOnArrival, rows[Self.rowKey(target.machine, target.id)] != nil, !isEditing else { return }
        renameOnArrival = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if UserDefaults.standard.bool(forKey: "LogSidebar") { log("sidebar: renaming new workspace \(target.id)") }
            beginRename(target.machine, target.id, thenTerminal: true)
        }
    }

    /// Edits a workspace's name in place. `thenTerminal`: the terminal takes the keyboard afterwards even
    /// if the sidebar had it.
    func beginRename(_ machine: MachineKey, _ id: WorkspaceID, thenTerminal: Bool = false) {
        expand(machine)
        guard let (row, name) = rows[Self.rowKey(machine, id)] else { return }
        row.scrollToVisible(row.bounds)
        let keyboard = hasKeyboard && !thenTerminal
        row.onEditingEnded = { [weak self] in
            guard let self else { return }
            if UserDefaults.standard.bool(forKey: "LogSidebar") { log("sidebar: editing ended, showing \(row.label.stringValue)") }
            if keyboard { window?.makeFirstResponder(self) } else { onEditingEnded?() }
            runPending()
        }
        row.beginEditing(name) { [weak self] text in
            guard let self, !text.isEmpty, text != name else { return }
            row.label.stringValue = text
            if UserDefaults.standard.bool(forKey: "LogSidebar") { log("sidebar: committed \(text), shown at once") }
            heldNames.hold(Self.rowKey(machine, id), from: name, to: text)
            DispatchQueue.main.asyncAfter(deadline: .now() + HeldTitles<String>.lifetime + 0.1) { [weak self] in
                guard let self, !isEditing else { return }
                latest?()
            }
            onRename?(machine, id, text)
        }
    }

    private func add(_ view: NSView, height: CGFloat? = nil, to target: NSStackView? = nil) {
        let column = target ?? self.column
        column.addArrangedSubview(view)
        // Everything spans the column, so it follows the sidebar's width.
        view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: s(-16)).isActive = true
        if let height { view.heightAnchor.constraint(equalToConstant: height).isActive = true }
    }

    /// A line of dim text, aligned with row titles.
    private func note(_ text: String, tooltip: String?, color: NSColor) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: s(12))
        label.textColor = color
        label.toolTip = tooltip
        let wrapper = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: s(10)),
            label.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: s(-10)),
            label.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: s(4)),
            label.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: s(-4)),
        ])
        return wrapper
    }

    /// A dim, single-line action, with its icon where row titles start.
    /// `inset`: where the icon starts (inside a machine's group, in line with the names).
    private func actionButton(_ title: String, symbol: String, tooltip: String, inset: CGFloat = 8,
                              action: @escaping () -> Void) -> NSView {
        let button = ClosureButton(title: title, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: s(10), weight: .medium))
        button.imagePosition = .imageLeading
        button.isBordered = false
        button.contentTintColor = Theme.dimText
        button.attributedTitle = NSAttributedString(string: " " + title, attributes: [.foregroundColor: Theme.dimText, .font: NSFont.systemFont(ofSize: s(12))])
        button.toolTip = tooltip
        let wrapper = NSView()
        button.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: inset),
            button.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            wrapper.heightAnchor.constraint(equalToConstant: Self.rowHeight),
        ])
        return wrapper
    }

    /// Drag the sidebar's right edge to resize it.
    var onResize: ((CGFloat) -> Void)?
    var onResizeEnd: (() -> Void)?

    // Empty sidebar space drags the window, like a title bar.
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

/// A machine's name in small capitals, with a status dot, a + for a new workspace on it, and an optional
/// status line under it. Right-click it for the machine's menu.
final class MachineHeader: NSView {
    var contextMenu: (() -> NSMenu?)?
    var onNewWorkspace: (() -> Void)?
    /// Clicking the header (not its +) collapses or expands the group, when set.
    var onToggle: (() -> Void)?
    /// The group's disclosure chevron (machines that can collapse).
    private(set) var chevron: DisclosureChevron?
    /// The quiet + that makes a workspace on this machine (shown when there's a tooltip for it).
    private(set) var newWorkspaceButton: QuietButton?
    /// Where a machine's name starts: after its chevron (10 pt in, 14 pt wide) and 6 pt of space. Its
    /// workspace rows and buttons line up with it.
    static var nameInset: CGFloat { s(30) }

    /// `collapsed` nil: no disclosure chevron (the Agents header). `count` shows after the title while
    /// collapsed, so a closed group still says how many workspaces it holds.
    init(title: String, status: (color: NSColor?, text: String?), newWorkspaceTooltip: String?,
         collapsed: Bool? = nil, count: Int = 0) {
        super.init(frame: .zero)
        let shownTitle = title.uppercased() + (collapsed == true && count > 0 ? "  \(count)" : "")
        let label = NSTextField(labelWithString: shownTitle)
        label.font = NSFont.systemFont(ofSize: s(11), weight: .semibold)
        label.textColor = Theme.accent
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = s(3)
        dot.layer?.backgroundColor = status.color?.cgColor
        dot.isHidden = status.color == nil
        let detail = NSTextField(wrappingLabelWithString: status.text ?? "")
        detail.font = NSFont.systemFont(ofSize: s(11))
        detail.textColor = Theme.dimText
        detail.maximumNumberOfLines = 3
        detail.isHidden = status.text == nil
        detail.toolTip = status.text
        let add = QuietButton(symbol: "plus", label: "New Workspace", pointSize: s(11)) { [weak self] in self?.onNewWorkspace?() }
        newWorkspaceButton = add
        add.toolTip = newWorkspaceTooltip
        add.isHidden = newWorkspaceTooltip == nil
        // A machine's chevron comes first, in the Quiet header's column; the name, its rows and their
        // buttons all start at nameInset after it.
        let chevron = DisclosureChevron(expanded: collapsed == false)
        chevron.isHidden = collapsed == nil
        chevron.setAccessibilityLabel(collapsed == true ? "Show workspaces" : "Hide workspaces")
        if collapsed != nil { self.chevron = chevron }
        for view in [chevron, label, dot, detail, add] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: s(10)),
            chevron.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: DisclosureChevron.size),
            chevron.heightAnchor.constraint(equalToConstant: DisclosureChevron.size),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: collapsed == nil ? 10 : Self.nameInset),
            label.topAnchor.constraint(equalTo: topAnchor, constant: s(6)),
            dot.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: s(6)),
            dot.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: s(6)),
            dot.heightAnchor.constraint(equalToConstant: s(6)),
            dot.trailingAnchor.constraint(lessThanOrEqualTo: add.leadingAnchor, constant: s(-6)),
            add.trailingAnchor.constraint(equalTo: trailingAnchor, constant: s(-6)),
            add.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            add.widthAnchor.constraint(equalToConstant: s(18)),
            add.heightAnchor.constraint(equalToConstant: s(18)),
            detail.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: s(-10)),
            detail.topAnchor.constraint(equalTo: label.bottomAnchor, constant: s(3)),
            (status.text == nil ? label.bottomAnchor : detail.bottomAnchor).constraint(equalTo: bottomAnchor, constant: s(-2)),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let onToggle else { return window?.performDrag(with: event) ?? () }
        onToggle()
    }
}

/// The line between the workspaces and agents panels; drag it to resize the agents panel.
final class AgentsDivider: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        Theme.divider.setFill()
        NSRect(x: 0, y: (bounds.height / 2).rounded(), width: bounds.width, height: s(1)).fill()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {
        guard let sidebar = superview else { return }
        // The pointer's height above the sidebar's bottom is the agents panel's new height.
        onDrag?(sidebar.convert(event.locationInWindow, from: nil).y)
    }
    override func mouseUp(with event: NSEvent) { onEnd?() }
}

/// The sidebar's draggable right edge.
final class ResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {
        guard let sidebar = superview else { return }
        // The pointer's distance from the sidebar's left edge is its new width.
        onDrag?(sidebar.convert(event.locationInWindow, from: nil).x)
    }
    override func mouseUp(with event: NSEvent) { onEnd?() }
}

/// A borderless button that runs a closure.
final class ClosureButton: NSButton {
    private var handler: (() -> Void)?

    convenience init(title: String, action handler: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        self.handler = handler
        target = self
        action = #selector(run)
    }

    @objc private func run() { handler?() }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

/// A row of the sidebar's workspace list: the name in line with the machine's, and a dot on the trailing
/// edge (the workspace's most urgent agent), whose place the hover button takes.
class SidebarRow: ChromeItem {
    let badge = NSView()
    /// Where the dot's centre (and the hover button's) sits, from the row's trailing edge.
    static var dotInset: CGFloat { s(13) }

    /// `trailingSpace`: what the title leaves free at the end, for the dot and the hover button.
    init(indent: CGFloat, fontSize: CGFloat, closable: Bool = true, trailingSpace: CGFloat = s(12)) {
        super.init(closable: closable)
        label.font = NSFont.systemFont(ofSize: s(fontSize))
        selectionStyle = .row
        closeShowsWhenSelected = false
        badge.wantsLayer = true
        badge.layer?.cornerRadius = s(3.5)
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        constraints.filter { $0.firstItem === label && $0.firstAttribute == .leading }.forEach { $0.constant = indent }
        // The title stops before the dot's column, shown or not, so titles truncate at one edge.
        constraints.filter { $0.firstItem === label && $0.firstAttribute == .trailing }.forEach { $0.isActive = false }
        if closeButton.superview != nil {
            constraints.filter { $0.firstItem === closeButton && $0.firstAttribute == .trailing }.forEach { $0.isActive = false }
            closeButton.centerXAnchor.constraint(equalTo: trailingAnchor, constant: -Self.dotInset).isActive = true
        }
        NSLayoutConstraint.activate([
            badge.centerXAnchor.constraint(equalTo: trailingAnchor, constant: -Self.dotInset),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: s(7)),
            badge.heightAnchor.constraint(equalToConstant: s(7)),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -(Self.dotInset + trailingSpace)),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows a colored dot (nil hides it).
    func setBadge(_ color: NSColor?) {
        badge.layer?.backgroundColor = color?.cgColor
        badgeColor = color
        closeVisibilityChanged()
    }

    private var badgeColor: NSColor?

    /// The dot gives its place to the hover button while that shows.
    override func closeVisibilityChanged() {
        badge.isHidden = badgeColor == nil || !closeButton.isHidden
    }
}

/// A workspace: its name and its most urgent agent's dot. Under the pointer it offers a new tab (+) in the
/// dot's place; closing it is in its right-click menu (and ⇧⌘W), not on the row.
final class WorkspaceRow: SidebarRow {
    var onNewTab: (() -> Void)?
    /// The + that makes a tab in this workspace: the trailing button, shown on hover.
    var newTabButton: NSButton { closeButton }

    init() {
        super.init(indent: MachineHeader.nameInset, fontSize: 13, closable: true)
        restingTextColor = Theme.foreground
        closeButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")?
            .withSymbolConfiguration(.init(pointSize: s(10), weight: .semibold))
        closeButton.setAccessibilityLabel("New Tab")
        closeButton.toolTip = "New Tab"
        closeButton.target = self
        closeButton.action = #selector(newTabTapped)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func newTabTapped() { onNewTab?() }

    override var hasTrailingAction: Bool { onNewTab != nil }
}

/// A strip under the tab bar for things that need the user's attention but shouldn't block anything,
/// such as an upgrade that needs clothod restarted.
final class NoticeBar: NSView {
    private var appearanceColors: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        withAppearance { appearanceColors?() }
    }

    init(message: String, detail: String?, action: String?, onAction: (() -> Void)?, onDismiss: @escaping () -> Void) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.noticeBackground.cgColor
        appearanceColors = { [weak self] in self?.layer?.backgroundColor = Theme.noticeBackground.cgColor }
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: nil)!)
        icon.contentTintColor = Theme.caution
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = NSFont.systemFont(ofSize: s(12))
        label.textColor = Theme.foreground
        label.toolTip = detail
        var views: [NSView] = [icon, label]
        if let action, let onAction {
            let button = ClosureButton(title: action, action: onAction)
            button.bezelStyle = .rounded
            button.isBordered = true
            button.controlSize = .small
            views.append(button)
        }
        let close = ClosureButton(title: "", action: onDismiss)
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")?
            .withSymbolConfiguration(.init(pointSize: s(9), weight: .semibold))
        close.isBordered = false
        close.contentTintColor = Theme.dimText
        views.append(close)
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = s(10)
        stack.edgeInsets = NSEdgeInsets(top: s(6), left: s(12), bottom: s(6), right: s(12))
        stack.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// A disclosure chevron: SF Symbols chevron.right, turned down when expanded (animated). It's drawn in its
/// own layer, so the rotation animates around its centre without disturbing Auto Layout.
final class DisclosureChevron: NSView {
    static var size: CGFloat { s(14) }
    private let glyph = CALayer()
    private(set) var isExpanded: Bool

    init(expanded: Bool) {
        isExpanded = expanded
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        wantsLayer = true
        let config = NSImage.SymbolConfiguration(pointSize: s(9), weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [Theme.dimText]))
        glyph.contents = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        glyph.contentsGravity = .center
        glyph.setAffineTransform(Self.transform(expanded))
        layer?.addSublayer(glyph)
        setAccessibilityRole(.disclosureTriangle)
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func transform(_ expanded: Bool) -> CGAffineTransform {
        // Clockwise a quarter turn: right becomes down.
        expanded ? CGAffineTransform(rotationAngle: -.pi / 2) : .identity
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyph.bounds = bounds
        glyph.position = CGPoint(x: bounds.midX, y: bounds.midY)
        glyph.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        glyph.contentsScale = window?.backingScaleFactor ?? 2
    }

    /// Turns the chevron, then calls `done` (after the animation when animated).
    func setExpanded(_ expanded: Bool, animated: Bool, then done: (() -> Void)? = nil) {
        isExpanded = expanded
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.15 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        CATransaction.setDisableActions(!animated)
        CATransaction.setCompletionBlock { done?() }
        glyph.setAffineTransform(Self.transform(expanded))
        CATransaction.commit()
    }
}

/// A subsection header inside a panel, such as the Agents panel's Quiet section: a row that highlights on
/// hover and toggles on click, with the chevron in the rows' icon column, the title in secondary text, and a
/// small count badge at the end, like Mail's and Finder's sidebars.
final class DisclosureRow: ChromeItem {
    let chevron: DisclosureChevron
    private let badge = NSTextField(labelWithString: "")
    private let pill = NSView()

    init(title: String, count: Int, expanded: Bool) {
        chevron = DisclosureChevron(expanded: expanded)
        super.init(closable: false)
        colorsOwnTitle = true
        label.stringValue = title
        label.font = NSFont.systemFont(ofSize: s(12), weight: .medium)
        label.textColor = Theme.dimText
        badge.stringValue = "\(count)"
        badge.font = NSFont.monospacedDigitSystemFont(ofSize: s(10), weight: .medium)
        badge.textColor = Theme.faintText
        badge.alignment = .center
        pill.wantsLayer = true
        pill.layer?.backgroundColor = Theme.pill.cgColor
        pill.layer?.cornerRadius = s(7)
        pill.isHidden = count == 0
        setAccessibilityLabel("\(title), \(count) agents")
        for view in [chevron, pill, badge] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // The title follows the chevron, which sits where the agent rows show their status icons.
        constraints.filter { $0.firstItem === label && $0.firstAttribute == .leading }.forEach { $0.isActive = false }
        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: s(10)),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: DisclosureChevron.size),
            chevron.heightAnchor.constraint(equalToConstant: DisclosureChevron.size),
            label.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: s(6)),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: s(-8)),
            pill.centerYAnchor.constraint(equalTo: centerYAnchor),
            pill.heightAnchor.constraint(equalToConstant: s(14)),
            pill.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
            badge.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: s(5)),
            badge.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: s(-5)),
            badge.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: pill.leadingAnchor, constant: s(-6)),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}


/// The sidebar's bottom bar: icon buttons for Machines (Manage Machines…), Settings, and light or dark.
/// Pinned under the lists, with a thin separator on top, in the sidebar's quiet style.
final class SidebarFooter: NSView {
    static var height: CGFloat { s(34) }
    var onMachines: (() -> Void)?
    var onSettings: (() -> Void)?
    /// Light, Dark or Match System, chosen here.
    var onSetAppearance: ((Theme.Mode) -> Void)?

    private(set) var machinesButton: QuietButton!
    private(set) var settingsButton: QuietButton!
    /// A click switches between Light and Dark; its right-click menu also offers Match System.
    private(set) var appearanceButton: QuietButton!
    private let separator = NSView()
    private let row = NSStackView()
    private var heightConstraint: NSLayoutConstraint!
    private var leading: NSLayoutConstraint!
    private var buttonSizes: [NSLayoutConstraint] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        separator.wantsLayer = true
        separator.layer?.backgroundColor = Theme.divider.cgColor
        machinesButton = QuietButton(symbol: "server.rack", label: "Machines", pointSize: s(12)) { [weak self] in self?.onMachines?() }
        machinesButton.toolTip = "Machines: add, edit, remove and reorder them"
        settingsButton = QuietButton(symbol: "gearshape", label: "Settings", pointSize: s(12)) { [weak self] in self?.onSettings?() }
        settingsButton.toolTip = "Settings (⌘,)"
        appearanceButton = QuietButton(symbol: "moon", label: "Appearance", pointSize: s(12)) { [weak self] in self?.toggleAppearance() }
        row.orientation = .horizontal
        row.alignment = .centerY
        for button in [machinesButton!, settingsButton!, appearanceButton!] { row.addArrangedSubview(button) }
        for view in [separator, row] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        leading = row.leadingAnchor.constraint(equalTo: leadingAnchor)
        NSLayoutConstraint.activate([
            heightConstraint, leading,
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            row.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
        ])
        applyScale()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        withAppearance { separator.layer?.backgroundColor = Theme.divider.cgColor }
        updateAppearanceButton()
    }

    /// Whether the window shows dark now (whatever chose it).
    private var showsDark: Bool { effectiveAppearance.isDark }

    private func toggleAppearance() { onSetAppearance?(showsDark ? .light : .dark) }

    /// The toggle's icon shows what's in effect (a half circle while it follows the system); its tooltip
    /// and right-click menu say what it does.
    func updateAppearanceButton() {
        let mode = Theme.Mode.current
        let symbol = mode == .system ? "circle.lefthalf.filled" : (mode == .dark ? "moon" : "sun.max")
        appearanceButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Appearance")?
            .withSymbolConfiguration(.init(pointSize: s(12), weight: .medium))
        let target = showsDark ? "Light" : "Dark"
        appearanceButton.toolTip = mode == .system
            ? "Switch to \(target) (now matching the system)"
            : "Switch to \(target) (right-click to match the system)"
        appearanceButton.setAccessibilityValue(mode.title)
        let menu = NSMenu()
        for each in Theme.Mode.allCases {
            let item = menu.addItem(withTitle: each.title, action: #selector(chooseAppearance(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = each.rawValue
            item.state = each == mode ? .on : .off
        }
        appearanceButton.menu = menu
    }

    @objc private func chooseAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = Theme.Mode(rawValue: raw) else { return }
        onSetAppearance?(mode)
    }

    /// Re-applies the app zoom (the footer is built once).
    func applyScale() {
        heightConstraint.constant = Self.height
        leading.constant = s(12)
        row.spacing = s(10)
        for (button, symbol) in [(machinesButton!, "server.rack"), (settingsButton!, "gearshape")] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: button.accessibilityLabel())?
                .withSymbolConfiguration(.init(pointSize: s(12), weight: .medium))
        }
        NSLayoutConstraint.deactivate(buttonSizes)
        buttonSizes = [machinesButton!, settingsButton!, appearanceButton!].flatMap {
            [$0.widthAnchor.constraint(equalToConstant: s(24)), $0.heightAnchor.constraint(equalToConstant: s(24))]
        }
        NSLayoutConstraint.activate(buttonSizes)
        updateAppearanceButton()
    }
}
