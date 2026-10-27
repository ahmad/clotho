import AppKit
import ClothoKit

// The native chrome around the panes: a sidebar of workspaces ("sessions" in the menus) and a tab
// bar for the focused workspace. Both redraw from the model on every change.

/// A clickable row or tab: highlights on hover and when selected, with an optional close button.
class ChromeItem: NSView {
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onClose: (() -> Void)?
    var contextMenu: (() -> NSMenu?)?
    var isSelected = false { didSet { updateColors() } }
    private var hovering = false { didSet { updateColors() } }
    /// Rows with an attributed title keep its colors on hover and selection.
    var colorsOwnTitle = false
    var selectedColor = Theme.background
    var hoverColor = Theme.hover

    let label = NSTextField(labelWithString: "")
    let closeButton = NSButton()

    init(closable: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        label.font = NSFont.systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        closeButton.isBordered = false
        closeButton.contentTintColor = Theme.dimText
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isHidden = true
        if closable { addSubview(closeButton) }

        var constraints = [
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if closable {
            constraints += [
                closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                closeButton.widthAnchor.constraint(equalToConstant: 16),
                closeButton.heightAnchor.constraint(equalToConstant: 16),
                label.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),
            ]
        } else {
            constraints.append(label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10))
        }
        NSLayoutConstraint.activate(constraints)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() } else { onClick?() }
    }

    @objc private func closeTapped() { onClose?() }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }

    private func updateColors() {
        layer?.backgroundColor = (isSelected ? selectedColor : hovering ? hoverColor : .clear).cgColor
        if !colorsOwnTitle { label.textColor = isSelected ? Theme.foreground : Theme.dimText }
        closeButton.isHidden = !(hovering || isSelected) || onClose == nil
    }
}

final class TabBarView: NSView {
    static let height: CGFloat = 34

    var onSelect: ((TabID) -> Void)?
    var onClose: ((TabID) -> Void)?
    var onRename: ((TabID) -> Void)?
    var onNewTab: (() -> Void)?

    private let stack = NSStackView()
    private let addButton = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.sidebar.cgColor
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        addButton.isBordered = false
        addButton.contentTintColor = Theme.dimText
        addButton.target = self
        addButton.action = #selector(addTapped)
        addButton.toolTip = "New Tab (⌘T)"
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(addButton)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            addButton.leadingAnchor.constraint(equalTo: stack.trailingAnchor, constant: 6),
            addButton.centerYAnchor.constraint(equalTo: stack.centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 24),
            addButton.heightAnchor.constraint(equalToConstant: 24),
            addButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(tabs: [(id: TabID, title: String, maximized: Bool, badge: NSColor?)], selected: TabID?) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, tab) in tabs.enumerated() {
            let item = ChromeItem(closable: true)
            item.label.stringValue = (tab.maximized ? "⤢ " : "") + tab.title
            item.label.alignment = .center
            item.toolTip = index < 9 ? "\(tab.title) (⌘\(index + 1))" : tab.title
            item.isSelected = tab.id == selected
            item.onClick = { [weak self] in self?.onSelect?(tab.id) }
            item.onDoubleClick = { [weak self] in self?.onRename?(tab.id) }
            item.onClose = { [weak self] in self?.onClose?(tab.id) }
            item.isSelected = tab.id == selected
            if let badge = tab.badge {
                // An agent in this tab: a dot at the tab's leading edge.
                let dot = NSView()
                dot.wantsLayer = true
                dot.layer?.cornerRadius = 3
                dot.layer?.backgroundColor = badge.cgColor
                dot.translatesAutoresizingMaskIntoConstraints = false
                item.addSubview(dot)
                // The title moves over to make room for the dot at the tab's leading edge.
                item.constraints.filter { $0.firstItem === item.label && $0.firstAttribute == .leading }.forEach { $0.constant = 20 }
                NSLayoutConstraint.activate([
                    dot.leadingAnchor.constraint(equalTo: item.leadingAnchor, constant: 9),
                    dot.centerYAnchor.constraint(equalTo: item.centerYAnchor),
                    dot.widthAnchor.constraint(equalToConstant: 6),
                    dot.heightAnchor.constraint(equalToConstant: 6),
                ])
            }
            stack.addArrangedSubview(item)
            item.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
            item.widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
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
    var onRename: ((MachineKey, WorkspaceID) -> Void)?
    var onClose: ((MachineKey, WorkspaceID) -> Void)?
    var onNewWorkspace: ((MachineKey) -> Void)?
    var onConnect: ((MachineKey) -> Void)?
    var onAddMachine: (() -> Void)?
    var machineMenu: ((MachineKey) -> NSMenu)?

    // Two panels, as in herdr: on top, one column grouped by machine (this Mac, then each saved SSH
    // machine, each with its sessions); at the bottom, every agent on every machine. A divider between
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
        for view in [scroll, divider, agentsScroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let saved = CGFloat(UserDefaults.standard.double(forKey: "AgentsPanelHeight"))
        agentsHeight = agentsScroll.heightAnchor.constraint(equalToConstant: saved > 0 ? saved : 220)
        // The sessions panel keeps some room even when the window is short.
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
            agentsScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            agentsHeight,
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

    /// A vertical stack in a scroll view that hides its scroller when idle.
    private static func scrollingColumn(_ column: NSStackView) -> NSScrollView {
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = rowSpacing
        column.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 12, right: 8)
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
    static let rowHeight: CGFloat = 28
    static let rowSpacing: CGFloat = 2
    static let groupSpacing: CGFloat = 18

    var onOpenAgent: ((MachineKey, PaneID) -> Void)?
    var agentsMenu: (() -> NSMenu)?

    func update(agents: [AgentEntry], unreachable: [(name: String, reason: String)], groups: [SidebarGroup]) {
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        agentsColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // The agents panel: every agent on every machine, most urgent first.
        let needing = agents.filter(\.info.needsAttention).count
        let agentsHeader = MachineHeader(title: needing > 0 ? "Agents · \(needing)" : "Agents",
                                         status: (needing > 0 ? AgentInfo.State.waiting.color : nil, nil), newSessionTooltip: nil)
        agentsHeader.contextMenu = { [weak self] in self?.agentsMenu?() }
        add(agentsHeader, to: agentsColumn)
        agentsColumn.setCustomSpacing(4, after: agentsHeader)
        for entry in agents {
            let row = AgentRow(entry)
            row.onClick = { [weak self] in self?.onOpenAgent?(entry.machine, entry.pane) }
            add(row, height: 40, to: agentsColumn)
        }
        for machine in unreachable {
            add(note("\(machine.name) is unreachable, so its agents aren't shown", tooltip: machine.reason, color: AgentInfo.State.error.color),
                to: agentsColumn)
        }
        if agents.isEmpty && unreachable.isEmpty {
            add(note("No agents running", tooltip: "Claude Code and Codex sessions in any pane show up here.", color: Theme.dimText),
                to: agentsColumn)
        }

        for (index, group) in groups.enumerated() {
            if index > 0, let last = column.arrangedSubviews.last { column.setCustomSpacing(Self.groupSpacing, after: last) }
            let key = group.key
            let header = MachineHeader(title: group.title, status: group.status,
                                       newSessionTooltip: group.isConnected ? (group.isLocal ? "New Session (⌘N)" : "New session on \(group.title)") : nil)
            header.onNewSession = { [weak self] in self?.onNewWorkspace?(key) }
            header.contextMenu = { [weak self] in self?.machineMenu?(key) }
            add(header)
            column.setCustomSpacing(4, after: header)
            guard group.isConnected else {
                add(actionButton("Connect", symbol: "arrow.right", tooltip: "Connect to \(group.title) and show its sessions") { [weak self] in
                    self?.onConnect?(key)
                })
                continue
            }
            for workspace in group.workspaces {
                let row = WorkspaceRow()
                row.label.stringValue = workspace.name
                // The tab count only when there's more than one.
                row.detail.stringValue = workspace.tabs.count > 1 ? "\(workspace.tabs.count)" : ""
                row.toolTip = workspace.tabs.count == 1 ? "1 tab" : "\(workspace.tabs.count) tabs"
                row.onClick = { [weak self] in self?.onSelect?(key, workspace.id) }
                row.onDoubleClick = { [weak self] in self?.onRename?(key, workspace.id) }
                row.onClose = { [weak self] in self?.onClose?(key, workspace.id) }
                row.isSelected = workspace.id == group.selected
                row.setBadge(group.badges[workspace.id])
                add(row, height: Self.rowHeight)
            }
            if group.workspaces.isEmpty {
                add(actionButton("New Session", symbol: "plus", tooltip: header.toolTip ?? "New Session") { [weak self] in
                    self?.onNewWorkspace?(key)
                })
            }
        }
        if let last = column.arrangedSubviews.last { column.setCustomSpacing(Self.groupSpacing, after: last) }
        add(actionButton("Add Machine", symbol: "plus", tooltip: "Save an SSH machine") { [weak self] in self?.onAddMachine?() })
    }

    private func add(_ view: NSView, height: CGFloat? = nil, to target: NSStackView? = nil) {
        let column = target ?? self.column
        column.addArrangedSubview(view)
        // Everything spans the column, so it follows the sidebar's width.
        view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -16).isActive = true
        if let height { view.heightAnchor.constraint(equalToConstant: height).isActive = true }
    }

    /// A line of dim text, aligned with row titles.
    private func note(_ text: String, tooltip: String?, color: NSColor) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = color
        label.toolTip = tooltip
        let wrapper = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -4),
        ])
        return wrapper
    }

    /// A dim, single-line action, with its icon where row titles start.
    private func actionButton(_ title: String, symbol: String, tooltip: String, action: @escaping () -> Void) -> NSView {
        let button = ClosureButton(title: title, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        button.imagePosition = .imageLeading
        button.isBordered = false
        button.contentTintColor = Theme.dimText
        button.attributedTitle = NSAttributedString(string: " " + title, attributes: [.foregroundColor: Theme.dimText, .font: NSFont.systemFont(ofSize: 12)])
        button.toolTip = tooltip
        let wrapper = NSView()
        button.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 8),
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

/// A machine's name in small capitals, with a status dot, a + for a new session on it, and an optional
/// status line under it. Right-click it for the machine's menu.
final class MachineHeader: NSView {
    var contextMenu: (() -> NSMenu?)?
    var onNewSession: (() -> Void)?

    init(title: String, status: (color: NSColor?, text: String?), newSessionTooltip: String?) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = Theme.accent
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = status.color?.cgColor
        dot.isHidden = status.color == nil
        let detail = NSTextField(wrappingLabelWithString: status.text ?? "")
        detail.font = NSFont.systemFont(ofSize: 11)
        detail.textColor = Theme.dimText
        detail.maximumNumberOfLines = 3
        detail.isHidden = status.text == nil
        detail.toolTip = status.text
        let add = ClosureButton(title: "") { [weak self] in self?.onNewSession?() }
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Session")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        add.isBordered = false
        add.contentTintColor = Theme.dimText
        add.toolTip = newSessionTooltip
        add.isHidden = newSessionTooltip == nil
        toolTip = newSessionTooltip
        for view in [label, dot, detail, add] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            dot.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            dot.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            dot.trailingAnchor.constraint(lessThanOrEqualTo: add.leadingAnchor, constant: -6),
            add.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            add.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            add.widthAnchor.constraint(equalToConstant: 18),
            add.heightAnchor.constraint(equalToConstant: 18),
            detail.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            detail.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 3),
            (status.text == nil ? label.bottomAnchor : detail.bottomAnchor).constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }
}

/// The line between the sessions and agents panels; drag it to resize the agents panel.
final class AgentsDivider: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        Theme.divider.setFill()
        NSRect(x: 0, y: (bounds.height / 2).rounded(), width: bounds.width, height: 1).fill()
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
        label.font = NSFont.systemFont(ofSize: 13)
        detail.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = Theme.dimText
        detail.setContentHuggingPriority(.required, for: .horizontal)
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        detail.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detail)
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 3
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        // The title gives way to the trailing count and badge.
        constraints.filter { $0.firstItem === label && $0.firstAttribute == .trailing }.forEach { $0.isActive = false }
        let end = closeButton.superview == nil ? trailingAnchor : closeButton.leadingAnchor
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 6),
            badge.heightAnchor.constraint(equalToConstant: 6),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: end, constant: closeButton.superview == nil ? -10 : -4),
            detail.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -4),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: detail.leadingAnchor, constant: -6),
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
/// such as an upgrade that needs the sessions restarted.
final class NoticeBar: NSView {
    init(message: String, detail: String?, action: String?, onAction: (() -> Void)?, onDismiss: @escaping () -> Void) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(hex: 0x2A2F25).cgColor
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: nil)!)
        icon.contentTintColor = NSColor(hex: 0xC8A35A)
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = NSFont.systemFont(ofSize: 12)
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
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        close.isBordered = false
        close.contentTintColor = Theme.dimText
        views.append(close)
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
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
