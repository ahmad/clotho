import AppKit
import ClothoKit

// ⌘P quick open: type a few letters of a machine, workspace, tab or agent, and Return jumps to it. Ranking
// is ClothoKit's QuickOpen, the same as on iOS. With nothing typed it lists agents that need you, then
// this machine's workspaces and tabs, then other machines'.

extension AppDelegate {
    @objc func showQuickOpen(_ sender: Any?) {
        if let quickOpen {
            quickOpen.dismiss()
            return
        }
        let (items, actions) = quickOpenItems()
        let overlay = QuickOpenOverlay(items: items)
        overlay.onOpen = { [weak self] item in
            log("quick open: \(item.kind) \(item.title)")
            actions[item.id]?()
            self?.quickOpen?.dismiss()
        }
        overlay.onDismiss = { [weak self] in
            guard let self else { return }
            quickOpen = nil
            window.makeFirstResponder(activeTerminal)
        }
        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        quickOpen = overlay
        overlay.focusField()
    }

    /// Everything quick open can jump to, in the order shown before anything is typed, with what each does.
    func quickOpenItems() -> ([QuickOpenItem], [String: () -> Void]) {
        var items: [QuickOpenItem] = []
        var actions: [String: () -> Void] = [:]
        func add(_ item: QuickOpenItem, _ action: @escaping () -> Void) {
            items.append(item)
            actions[item.id] = action
        }

        for entry in AgentEntry.sorted(agentEntries()) {
            let title = "\(entry.info.kindName): \(entry.paneTitle ?? entry.tabTitle ?? "agent")"
            let place = [entry.machineName, entry.place].filter { !$0.isEmpty }.joined(separator: " › ")
            add(QuickOpenItem(kind: .agent, title: title, subtitle: "\(entry.info.shownState.label) · \(place)",
                              id: "agent|\(entry.machine)|\(entry.pane)")) { [weak self] in
                self?.openAgent(machine: entry.machine, pane: entry.pane)
            }
        }

        // The focused machine first, then the others in sidebar order.
        let keys = [focusedMachine] + ([Self.localKey] + remoteMachines.map(\.key)).filter { $0 != focusedMachine }
        for key in keys {
            guard let session = connections[key] else { continue }
            let store = session.store
            let machine = session.title
            for workspace in store.state.workspaces {
                add(QuickOpenItem(kind: .workspace, title: workspace.name, subtitle: machine, id: "ws|\(key)|\(workspace.id)")) { [weak self] in
                    self?.focusNow(.workspace(workspace.id), on: key, trace: "quick open")
                }
            }
            for workspace in store.state.workspaces {
                for tab in workspace.tabs {
                    add(QuickOpenItem(kind: .tab, title: store.displayTitle(of: tab), subtitle: "\(machine) › \(workspace.name)",
                                      id: "tab|\(key)|\(tab.id)")) { [weak self] in
                        self?.focusNow(.tab(tab.id), on: key, trace: "quick open")
                    }
                }
            }
        }

        for machine in [Machine.local] + remoteMachines {
            let connected = connections[machine.key] != nil
            let name = machine.isLocal ? ComputerName.current : machine.label
            add(QuickOpenItem(kind: .machine, title: name, subtitle: connected ? "Connected" : "Connect",
                              id: "machine|\(machine.key)")) { [weak self] in
                guard let self else { return }
                if connections[machine.key] != nil { focus(machine: machine.key) } else { connect(machine, show: true) }
            }
        }
        return (items, actions)
    }
}

final class QuickOpenOverlay: NSView, NSTextFieldDelegate {
    var onOpen: ((QuickOpenItem) -> Void)?
    var onDismiss: (() -> Void)?
    let card = NSView()
    private let field = NSTextField()
    private let list = NSStackView()
    private let empty = NSTextField(labelWithString: "No matches")
    private let items: [QuickOpenItem]
    private(set) var results: [QuickOpen.Result] = []
    private(set) var selected = 0
    static let visibleRows = 10

    init(items: [QuickOpenItem]) {
        self.items = items
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.backdrop.cgColor

        field.placeholderString = "Go to a workspace, tab, agent or machine"
        field.font = .systemFont(ofSize: s(16))
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = Theme.foreground
        field.delegate = self
        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = Theme.dimText
        let top = NSStackView(views: [icon, field])
        top.orientation = .horizontal
        top.spacing = s(10)
        top.edgeInsets = NSEdgeInsets(top: s(14), left: s(16), bottom: s(12), right: s(16))
        let rule = NSBox()
        rule.boxType = .custom
        rule.borderWidth = 0
        rule.fillColor = Theme.divider
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.edgeInsets = NSEdgeInsets(top: s(6), left: s(6), bottom: s(6), right: s(6))
        empty.textColor = Theme.dimText
        empty.font = .systemFont(ofSize: s(13))

        let stack = NSStackView(views: [top, rule, list])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        for view in [top, rule, list] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }

        card.wantsLayer = true
        card.layer?.backgroundColor = Theme.background.cgColor
        card.layer?.cornerRadius = s(12)
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Theme.divider.cgColor
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.4
        card.layer?.shadowRadius = 24
        card.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        addSubview(card)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.topAnchor.constraint(equalTo: topAnchor, constant: s(90)),
            card.widthAnchor.constraint(equalToConstant: s(580)),
        ])
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    func focusField() { window?.makeFirstResponder(field) }

    func dismiss() {
        removeFromSuperview()
        onDismiss?()
    }

    /// Testing aid and typing: sets the query and ranks again.
    func setQuery(_ text: String) {
        field.stringValue = text
        update()
    }

    func controlTextDidChange(_ obj: Notification) { update() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(moveDown(_:)), #selector(insertTab(_:)): move(1)
        case #selector(moveUp(_:)), #selector(insertBacktab(_:)): move(-1)
        case #selector(insertNewline(_:)): open()
        case #selector(cancelOperation(_:)): dismiss()
        default: return false
        }
        return true
    }

    func open() {
        guard results.indices.contains(selected) else { return }
        onOpen?(results[selected].item)
    }

    private func move(_ by: Int) {
        guard !results.isEmpty else { return }
        selected = (selected + by + results.count) % results.count
        render()
    }

    private func update() {
        results = QuickOpen.rank(items, query: field.stringValue, limit: Self.visibleRows)
        selected = 0
        render()
    }

    private func render() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if results.isEmpty {
            list.addArrangedSubview(empty)
            return
        }
        for (index, result) in results.enumerated() {
            let row = QuickOpenRow(result: result, selected: index == selected) { [weak self] in
                self?.selected = index
                self?.open()
            }
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -s(12)).isActive = true
        }
    }

    // Clicks on the backdrop close it; nothing reaches the terminal behind.
    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { dismiss() }
    }
    override func scrollWheel(with event: NSEvent) {}
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

/// One result: the kind's icon, the title with the matched letters in the accent colour, and where it is.
final class QuickOpenRow: NSView {
    private let action: () -> Void

    init(result: QuickOpen.Result, selected: Bool, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = s(6)
        layer?.backgroundColor = selected ? Theme.accent.withAlphaComponent(0.22).cgColor : NSColor.clear.cgColor

        let symbol = switch result.item.kind {
        case .agent: "sparkles"
        case .workspace: "square.stack"
        case .tab: "rectangle.topthird.inset.filled"
        case .machine: "server.rack"
        }
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = result.item.kind == .agent ? Theme.accent : Theme.dimText
        icon.widthAnchor.constraint(equalToConstant: s(20)).isActive = true

        let title = NSTextField(labelWithString: "")
        title.attributedStringValue = Self.highlighted(result.item.title, result.titleIndices)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let subtitle = NSTextField(labelWithString: result.item.subtitle)
        subtitle.font = .systemFont(ofSize: s(12))
        subtitle.textColor = Theme.dimText
        subtitle.lineBreakMode = .byTruncatingHead
        subtitle.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        subtitle.alignment = .right

        let row = NSStackView(views: [icon, title, NSView(), subtitle])
        row.orientation = .horizontal
        row.spacing = s(8)
        row.edgeInsets = NSEdgeInsets(top: s(7), left: s(10), bottom: s(7), right: s(10))
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    static func highlighted(_ text: String, _ indices: [Int]) -> NSAttributedString {
        let marked = Set(indices)
        let result = NSMutableAttributedString()
        for (offset, character) in text.enumerated() {
            let hit = marked.contains(offset)
            result.append(NSAttributedString(string: String(character), attributes: [
                .font: NSFont.systemFont(ofSize: s(14), weight: hit ? .semibold : .regular),
                .foregroundColor: hit ? Theme.accent : Theme.foreground,
            ]))
        }
        return result
    }

    override func mouseDown(with event: NSEvent) { action() }
}
