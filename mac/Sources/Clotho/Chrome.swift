import AppKit
import ClothoKit

// The native chrome around the panes: a sidebar of workspaces and a tab
// bar for the focused workspace. Both redraw from the model on every change.

/// A clickable row or tab: highlights on hover and when selected, with an optional close button.
class ChromeItem: NSView {
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onClose: (() -> Void)?
    var contextMenu: (() -> NSMenu?)?
    var isSelected = false { didSet { updateColors() } }
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
        hovering = pointerIsOver()
    }

    /// Whether the pointer is over the visible part of this item, in its window, with no other window on top.
    func pointerIsOver() -> Bool {
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor else { return false }
        let screenPoint = NSEvent.mouseLocation
        guard NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0) == window.windowNumber else { return false }
        return visibleRect.contains(convert(window.convertPoint(fromScreen: screenPoint), from: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// For tests: hover as if the pointer came over the item or left it.
    func setHovering(_ on: Bool) { hovering = on }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() } else { onClick?() }
    }

    @objc private func closeTapped() { onClose?() }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }

    // MARK: Inline rename

    private var editor: NSTextField?
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
        closeButton.isHidden = !(hovering || isSelected) || onClose == nil || editor != nil
        guard selectionStyle != .plain else {
            layer?.backgroundColor = (isSelected ? selectedColor : hovering ? hoverColor : .clear).cgColor
            if !colorsOwnTitle { label.textColor = isSelected ? Theme.foreground : Theme.dimText }
            return
        }
        // The accent while the window is key; grey (still visible) while it isn't.
        let active = window?.isKeyWindow ?? true
        let tint = active ? Theme.accent : Theme.dimText
        layer?.backgroundColor = (isSelected ? tint.withAlphaComponent(active ? Self.tintAlpha : 0.16) : hovering ? hoverColor : .clear).cgColor
        marker.isHidden = !isSelected
        marker.layer?.backgroundColor = tint.cgColor
        if !colorsOwnTitle { label.textColor = isSelected ? Theme.foreground : Theme.dimText }
        if selectionStyle == .row, let size = label.font?.pointSize {
            label.font = NSFont.systemFont(ofSize: size, weight: isSelected ? .semibold : .regular)
        }
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
        stack.distribution = .fillEqually
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
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(tabs: [(id: TabID, title: String, custom: String?, maximized: Bool, badge: NSColor?)], selected: TabID?) {
        latest = { [weak self] in self?.update(tabs: tabs, selected: selected) }
        if items.values.contains(where: { $0.item.isEditing }) {
            pending = latest
            return
        }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        items = [:]
        for (index, var tab) in tabs.enumerated() {
            if let held = heldTitles.title(for: tab.id, model: tab.custom) { (tab.title, tab.custom) = (held, held) }
            let item = ChromeItem(closable: true)
            item.selectionStyle = .tab
            items[tab.id] = (item, tab.title, tab.custom)
            item.label.stringValue = (tab.maximized ? "⤢ " : "") + tab.title
            item.label.alignment = .center
            item.label.font = NSFont.systemFont(ofSize: s(13))
            // A little more room around the title than other rows.
            item.constraints.filter { $0.firstItem === item.label && $0.firstAttribute == .leading }.forEach { $0.constant = s(14) }
            item.toolTip = index < 9 ? "\(tab.title) (⌘\(index + 1))" : tab.title
            item.isSelected = tab.id == selected
            item.onClick = { [weak self] in self?.onSelect?(tab.id) }
            item.onDoubleClick = { [weak self] in self?.beginRename(tab.id) }
            item.onClose = { [weak self] in self?.onClose?(tab.id) }
            item.isSelected = tab.id == selected
            if let badge = tab.badge {
                // An agent in this tab: a dot at the tab's leading edge.
                let dot = NSView()
                dot.wantsLayer = true
                dot.layer?.cornerRadius = s(3)
                dot.layer?.backgroundColor = badge.cgColor
                dot.translatesAutoresizingMaskIntoConstraints = false
                item.addSubview(dot)
                // The title moves over to make room for the dot at the tab's leading edge.
                item.constraints.filter { $0.firstItem === item.label && $0.firstAttribute == .leading }.forEach { $0.constant = s(22) }
                NSLayoutConstraint.activate([
                    dot.leadingAnchor.constraint(equalTo: item.leadingAnchor, constant: s(9)),
                    dot.centerYAnchor.constraint(equalTo: item.centerYAnchor),
                    dot.widthAnchor.constraint(equalToConstant: s(6)),
                    dot.heightAnchor.constraint(equalToConstant: s(6)),
                ])
            }
            stack.addArrangedSubview(item)
            item.widthAnchor.constraint(lessThanOrEqualToConstant: s(240)).isActive = true
            item.widthAnchor.constraint(greaterThanOrEqualToConstant: s(72)).isActive = true
        }
        if UserDefaults.standard.bool(forKey: "LogSidebar") {
            log("tabs: " + stack.arrangedSubviews.compactMap { ($0 as? ChromeItem)?.label.stringValue }.joined(separator: ", "))
        }
    }

    private func runPending() {
        let update = pending
        pending = nil
        update?()
    }

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
    /// A workspace's name was edited in place.
    var onRename: ((MachineKey, WorkspaceID, String) -> Void)?
    /// After an inline edit ends, so the terminal can take focus back.
    var onEditingEnded: (() -> Void)?
    private var rows: [String: (row: WorkspaceRow, name: String)] = [:]
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
    var onNewWorkspace: ((MachineKey) -> Void)?
    var onConnect: ((MachineKey) -> Void)?
    var onAddMachine: (() -> Void)?
    /// A machine's Create Workspace button.
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
        footer = SidebarFooter(title: "Manage Machines…", symbol: "server.rack")
        footer.onClick = { [weak self] in self?.onManageMachines?() }
        footer.toolTip = "Add, edit, remove and reorder machines"
        for view in [scroll, divider, agentsScroll, footer!] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
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
        if rows.values.contains(where: { $0.row.isEditing }) {
            pending = latest
            return
        }
        rows = [:]
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
                                       newWorkspaceTooltip: nil,
                                       collapsed: isCollapsed, count: group.isConnected ? group.workspaces.count : 0)
            header.onNewWorkspace = { [weak self] in self?.onNewWorkspace?(key) }
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
                addCreateWorkspace(for: group)
                continue
            }
            for workspace in group.workspaces {
                let row = WorkspaceRow()
                let name = heldNames.title(for: Self.rowKey(key, workspace.id), model: workspace.name) ?? workspace.name
                row.label.stringValue = name
                // The tab count only when there's more than one.
                row.detail.stringValue = workspace.tabs.count > 1 ? "\(workspace.tabs.count)" : ""
                row.toolTip = workspace.tabs.count == 1 ? "1 tab" : "\(workspace.tabs.count) tabs"
                row.onClick = { [weak self] in self?.onSelect?(key, workspace.id) }
                row.onDoubleClick = { [weak self] in self?.beginRename(key, workspace.id) }
                rows[Self.rowKey(key, workspace.id)] = (row, name)
                row.onClose = { [weak self] in self?.onClose?(key, workspace.id) }
                row.isSelected = workspace.id == group.selected
                row.setBadge(group.badges[workspace.id])
                add(row, height: Self.rowHeight)
            }
            addCreateWorkspace(for: group)
        }
        if UserDefaults.standard.bool(forKey: "LogSidebar") {
            log("sidebar: " + rows.values.map(\.name).sorted().joined(separator: ", "))
        }
    }

    /// The outline "Create Workspace" button at the end of a machine's list, in line with the workspace
    /// titles. On a machine that isn't connected it connects first.
    private func addCreateWorkspace(for group: SidebarGroup) {
        let key = group.key
        let button = OutlineButton(title: "Create Workspace", symbol: "plus")
        button.toolTip = group.isConnected
            ? (group.isLocal ? "Create a workspace on this Mac (⌘N)" : "Create a workspace on \(group.title)")
            : "Connect to \(group.title) and create a workspace there"
        button.onClick = { [weak self] in self?.onCreateWorkspace?(key) }
        let wrapper = NSView()
        button.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(button)
        NSLayoutConstraint.activate([
            // The plus lines up with the workspace titles; the border starts just before it.
            button.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: MachineHeader.nameInset - OutlineButton.iconInset),
            button.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: s(-4)),
            button.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: s(4)),
            button.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            button.heightAnchor.constraint(equalToConstant: OutlineButton.height),
        ])
        if let last = column.arrangedSubviews.last { column.setCustomSpacing(s(4), after: last) }
        add(wrapper)
        if UserDefaults.standard.bool(forKey: "LogSidebar") { log("sidebar: \(group.title): Create Workspace (\(group.isConnected ? "connected" : "connects first"))") }
    }

    private func runPending() {
        let update = pending
        pending = nil
        update?()
    }

    private static func rowKey(_ machine: MachineKey, _ id: WorkspaceID) -> String { "\(machine)/\(id)" }

    /// Edits a workspace's name in place.
    func beginRename(_ machine: MachineKey, _ id: WorkspaceID) {
        expand(machine)
        guard let (row, name) = rows[Self.rowKey(machine, id)] else { return }
        row.onEditingEnded = { [weak self] in
            if UserDefaults.standard.bool(forKey: "LogSidebar") { log("sidebar: editing ended, showing \(row.label.stringValue)") }
            self?.onEditingEnded?()
            self?.runPending()
        }
        row.beginEditing(name) { [weak self] text in
            guard let self, !text.isEmpty, text != name else { return }
            row.label.stringValue = text
            if UserDefaults.standard.bool(forKey: "LogSidebar") { log("sidebar: committed \(text), shown at once") }
            heldNames.hold(Self.rowKey(machine, id), from: name, to: text)
            DispatchQueue.main.asyncAfter(deadline: .now() + HeldTitles<String>.lifetime + 0.1) { [weak self] in
                guard let self, !rows.values.contains(where: { $0.row.isEditing }) else { return }
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
        let add = ClosureButton(title: "") { [weak self] in self?.onNewWorkspace?() }
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Workspace")?
            .withSymbolConfiguration(.init(pointSize: s(11), weight: .medium))
        add.isBordered = false
        add.contentTintColor = Theme.dimText
        add.toolTip = newWorkspaceTooltip
        add.isHidden = newWorkspaceTooltip == nil
        toolTip = newWorkspaceTooltip
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

/// A workspace in the sidebar, with a slot for a status badge (agent status, later).
final class WorkspaceRow: ChromeItem {
    /// Short trailing text, such as a tab count.
    let detail = NSTextField(labelWithString: "")
    let badge = NSView()

    override init(closable: Bool = true) {
        super.init(closable: closable)
        label.font = NSFont.systemFont(ofSize: s(13))
        selectionStyle = .row
        detail.font = NSFont.monospacedDigitSystemFont(ofSize: s(11), weight: .regular)
        detail.textColor = Theme.dimText
        detail.setContentHuggingPriority(.required, for: .horizontal)
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        detail.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detail)
        badge.wantsLayer = true
        badge.layer?.cornerRadius = s(3)
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        // The title lines up with the machine's name above it, after the header's chevron.
        constraints.filter { $0.firstItem === label && $0.firstAttribute == .leading }.forEach { $0.constant = MachineHeader.nameInset }
        // The title gives way to the trailing count and badge.
        constraints.filter { $0.firstItem === label && $0.firstAttribute == .trailing }.forEach { $0.isActive = false }
        let end = closeButton.superview == nil ? trailingAnchor : closeButton.leadingAnchor
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: s(6)),
            badge.heightAnchor.constraint(equalToConstant: s(6)),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: end, constant: closeButton.superview == nil ? -10 : -4),
            detail.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: s(-4)),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: detail.leadingAnchor, constant: s(-6)),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows a colored dot (nil hides it).
    func setBadge(_ color: NSColor?) {
        badge.isHidden = color == nil
        badge.layer?.backgroundColor = color?.cgColor
    }
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


/// A subtle outline button in the sidebar ("Create Workspace"): a 1 pt low-contrast border, no fill,
/// 12 pt secondary text after a small plus. Hover brightens the border and the text.
final class OutlineButton: NSView {
    static var height: CGFloat { s(26) }
    /// The plus's distance from the button's leading edge.
    static var iconInset: CGFloat { s(9) }
    static let border = Theme.border
    static let borderHover = Theme.borderHover
    var onClick: (() -> Void)?
    let label: NSTextField
    private let icon = NSImageView()
    private(set) var hovering = false { didSet { updateColors() } }

    init(title: String, symbol: String) {
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerRadius = s(6)
        label.font = NSFont.systemFont(ofSize: s(12))
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: s(10), weight: .semibold))
        for view in [icon, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.iconInset),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: s(6)),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: s(-9)),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        withAppearance { updateColors() }
    }

    private func updateColors() {
        layer?.borderColor = (hovering ? Self.borderHover : Self.border).cgColor
        label.textColor = hovering ? Theme.foreground : Theme.dimText
        icon.contentTintColor = label.textColor
    }

    func setHovering(_ on: Bool) { hovering = on }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// The sidebar's footer row (Manage Machines…): pinned under the lists, a thin separator on top, an icon
/// and secondary text, highlighted on hover.
final class SidebarFooter: NSView {
    static var height: CGFloat { s(34) }
    var onClick: (() -> Void)? {
        get { item.onClick }
        set { item.onClick = newValue }
    }
    private let item = ChromeItem(closable: false)
    private let separator = NSView()
    private let icon = NSImageView()
    private let symbol: String
    private var heightConstraint: NSLayoutConstraint!
    private var scaled: [(NSLayoutConstraint, CGFloat)] = []

    init(title: String, symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        separator.wantsLayer = true
        separator.layer?.backgroundColor = Theme.divider.cgColor
        item.label.stringValue = title
        item.setAccessibilityRole(.button)
        item.setAccessibilityLabel(title)
        icon.contentTintColor = Theme.dimText
        for view in [separator, item, icon] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        // The title moves right of the icon.
        item.constraints.filter { $0.firstItem === item.label && $0.firstAttribute == .leading }.forEach { $0.isActive = false }
        scaled = [
            (item.leadingAnchor.constraint(equalTo: leadingAnchor), 8),
            (item.trailingAnchor.constraint(equalTo: trailingAnchor), -8),
            (item.topAnchor.constraint(equalTo: separator.bottomAnchor), 4),
            (item.bottomAnchor.constraint(equalTo: bottomAnchor), -4),
            (icon.leadingAnchor.constraint(equalTo: item.leadingAnchor), 10),
            (item.label.leadingAnchor.constraint(equalTo: icon.trailingAnchor), 6),
        ]
        NSLayoutConstraint.activate(scaled.map(\.0) + [
            heightConstraint,
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            icon.centerYAnchor.constraint(equalTo: item.centerYAnchor),
        ])
        applyScale()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        withAppearance { separator.layer?.backgroundColor = Theme.divider.cgColor }
    }

    /// Re-applies the app zoom (the footer is built once).
    func applyScale() {
        heightConstraint.constant = Self.height
        for (constraint, points) in scaled { constraint.constant = s(points) }
        item.label.font = NSFont.systemFont(ofSize: s(12))
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: s(11), weight: .regular))
    }
}
