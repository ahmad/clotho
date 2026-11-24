import AppKit
import ClothoKit

// A changed file's full diff, side by side, in the centre of the window: the old file on the left, the
// new one on the right, with line numbers. It opens from the Changes list (Return or a double-click).
//
// It is a view of this window shown over the pane area, not a Tab: opening it creates no shell and
// nothing on the daemon, the panes under it keep their layout and size, and every Tab shortcut still
// means the Tabs. "‹ <the Tab's name>" at its leading edge, Esc and ⌘W go back to the panes. It leaves
// by itself when the focus moves to another Tab, pane or machine.
//
// In a wide centre it lists the changed files at its side (the same list as the inspector's, sharing
// its selection); in a narrow one the inspector's list drives it, and ↑ and ↓ step through the files.

final class ChangesDiffView: NSView {
    let model: ChangesModel
    let backButton = NSButton()
    let letter = NSTextField(labelWithString: "")
    let path = NSTextField(labelWithString: "")
    let counts = NSTextField(labelWithString: "")
    let openButton = NSButton()
    let copyButton = NSButton()
    let list = ChangesListView()
    let leftTitle = NSTextField(labelWithString: "")
    let rightTitle = NSTextField(labelWithString: "")
    let diffArea = DiffAreaView(mode: .sideBySide)
    private let listDivider = NSBox()
    private var diffLeading: NSLayoutConstraint!
    private var compactButtons: Bool?
    /// Back, Esc or ⌘W.
    var onClose: (() -> Void)?
    /// Open in Editor: the file's machine and full path.
    var onOpenInEditor: ((MachineKey, String) -> Void)?
    /// What the pasteboard gets (tests replace it).
    var copy: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static var headerHeight: CGFloat { s(36) }
    static var titlesHeight: CGFloat { s(24) }
    static var listWidth: CGFloat { s(250) }
    /// Narrower than this, the view's own file list is left out.
    static var listMinWidth: CGFloat { s(700) }
    /// Narrower than this, Open in Editor and Copy Path are icons.
    static var wordsMinWidth: CGFloat { s(620) }

    init(model: ChangesModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityLabel("Diff")
        setAccessibilityIdentifier("ChangesDiff")

        backButton.bezelStyle = .inline
        backButton.isBordered = false
        backButton.font = .systemFont(ofSize: s(12), weight: .medium)
        backButton.contentTintColor = Theme.accent
        backButton.lineBreakMode = .byTruncatingTail
        backButton.target = self
        backButton.action = #selector(close)
        backButton.toolTip = "Back to the Tab (esc)"
        backButton.setAccessibilityLabel("Back to the Tab")
        backButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        backButton.title = "‹ Back"
        backButton.widthAnchor.constraint(lessThanOrEqualToConstant: s(180)).isActive = true

        letter.font = .monospacedSystemFont(ofSize: s(12), weight: .medium)
        path.font = .monospacedSystemFont(ofSize: s(12), weight: .regular)
        path.textColor = Theme.foreground
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        counts.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Quiet text buttons in the accent, as the strip's pull request is: a bezel greys out whenever the
        // window isn't key, and reads as off.
        for (button, action) in [(openButton, #selector(openInEditor)), (copyButton, #selector(copyPath))] {
            button.bezelStyle = .inline
            button.isBordered = false
            button.contentTintColor = Theme.accent
            button.target = self
            button.action = action
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        openButton.toolTip = "Open the file in its default app"
        openButton.setAccessibilityLabel("Open in Editor")
        copyButton.toolTip = "Copy the file's full path"
        copyButton.setAccessibilityLabel("Copy Path")

        let header = NSStackView(views: [backButton, Self.rule(vertical: true), letter, path, counts, NSView(), openButton, copyButton])
        header.orientation = .horizontal
        header.spacing = s(8)
        header.edgeInsets = NSEdgeInsets(top: 0, left: s(10), bottom: 0, right: s(10))
        header.setHuggingPriority(.defaultLow, for: .horizontal)
        let headerRule = Self.rule(vertical: false)

        list.onSelect = { [weak self] file, group in
            // The list here never empties the selection: the view is of one file.
            guard let file else { return }
            self?.model.select(file, group: group)
        }
        list.onOpen = { [weak self] file, group in self?.model.select(file, group: group) }
        list.onLeave = { [weak self] in self?.onClose?() }
        listDivider.boxType = .custom
        listDivider.borderWidth = 0
        listDivider.fillColor = Theme.divider

        for label in [leftTitle, rightTitle] {
            label.font = .systemFont(ofSize: s(11))
            label.textColor = Theme.dimText
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let titlesRule = Self.rule(vertical: false)

        for view in [header, headerRule, list, listDivider, leftTitle, rightTitle, titlesRule, diffArea] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        diffLeading = diffArea.leadingAnchor.constraint(equalTo: leadingAnchor)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            headerRule.topAnchor.constraint(equalTo: header.bottomAnchor),
            headerRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            list.topAnchor.constraint(equalTo: headerRule.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: leadingAnchor),
            list.widthAnchor.constraint(equalToConstant: Self.listWidth),
            list.bottomAnchor.constraint(equalTo: bottomAnchor),
            listDivider.topAnchor.constraint(equalTo: list.topAnchor),
            listDivider.bottomAnchor.constraint(equalTo: bottomAnchor),
            listDivider.trailingAnchor.constraint(equalTo: diffArea.leadingAnchor),
            listDivider.widthAnchor.constraint(equalToConstant: 1),
            diffLeading,
            diffArea.trailingAnchor.constraint(equalTo: trailingAnchor),
            diffArea.bottomAnchor.constraint(equalTo: bottomAnchor),
            diffArea.topAnchor.constraint(equalTo: headerRule.bottomAnchor, constant: Self.titlesHeight),
            titlesRule.bottomAnchor.constraint(equalTo: diffArea.topAnchor),
            titlesRule.leadingAnchor.constraint(equalTo: diffArea.leadingAnchor),
            titlesRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            leftTitle.leadingAnchor.constraint(equalTo: diffArea.leadingAnchor, constant: s(10)),
            leftTitle.centerYAnchor.constraint(equalTo: headerRule.bottomAnchor, constant: Self.titlesHeight / 2),
            leftTitle.trailingAnchor.constraint(lessThanOrEqualTo: diffArea.centerXAnchor, constant: -s(8)),
            rightTitle.leadingAnchor.constraint(equalTo: diffArea.centerXAnchor, constant: s(10)),
            rightTitle.centerYAnchor.constraint(equalTo: leftTitle.centerYAnchor),
            rightTitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -s(10)),
        ])
        model.observe { [weak self] in self?.update() }
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func rule(vertical: Bool) -> NSBox {
        let rule = NSBox()
        rule.boxType = .custom
        rule.borderWidth = 0
        rule.fillColor = Theme.divider
        rule.translatesAutoresizingMaskIntoConstraints = false
        if vertical {
            rule.widthAnchor.constraint(equalToConstant: 1).isActive = true
            rule.heightAnchor.constraint(equalToConstant: s(16)).isActive = true
        } else {
            rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        }
        return rule
    }

    private func applyColors() {
        withAppearance { layer?.backgroundColor = Theme.background.cgColor }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// The Tab to go back to, by name.
    var tabTitle = "" {
        didSet {
            backButton.title = "‹ \(tabTitle.isEmpty ? "Back" : tabTitle)"
        }
    }

    /// What each side is: the base (or HEAD) on the left, the work tree (or the branch) on the right.
    static func titles(group: GitChangeGroup, changes: GitChanges?) -> (old: String, new: String) {
        switch group {
        case .uncommitted: return ("HEAD", "working tree")
        case .branch:
            let base = changes?.branchChanges.map { DiffText.display($0.base) } ?? "base"
            return (base, changes?.branch.map { DiffText.display($0) } ?? "HEAD")
        }
    }

    func update() {
        guard !isHidden else { return }
        var listed: GitChanges?
        if case let .loaded(changes) = model.list { listed = changes }
        list.show(listed, selection: model.selection)
        if let file = model.selectedFile, let selection = model.selection {
            letter.stringValue = file.status.letter
            letter.textColor = ChangedFileCell.letterColor(file.status)
            letter.setAccessibilityLabel(file.status.word)
            path.stringValue = DiffText.display(file.path)
            path.toolTip = ChangedFileCell.tooltip(file)
            counts.attributedStringValue = ChangedFileCell.counts(file) ?? NSAttributedString()
            let titles = Self.titles(group: selection.group, changes: listed)
            leftTitle.stringValue = titles.old
            rightTitle.stringValue = titles.new
        }
        let canOpen = fullPath != nil && model.selectedFile?.status != .deleted
        openButton.isEnabled = canOpen
        copyButton.isEnabled = fullPath != nil
        // The file left the list (committed, reverted): say so where its diff was.
        diffArea.show(model.selection == nil ? .failed("This file has no changes any more.") : model.diff)
    }

    /// The selected file's full path on its machine, when Clotho has its exact name.
    var fullPath: String? {
        guard let file = model.selectedFile, case let .loaded(changes) = model.list else { return nil }
        return ChangesModel.absolutePath(root: changes.root, file: file)
    }

    override func layout() {
        let showsList = bounds.width >= Self.listMinWidth
        if list.isHidden == showsList {
            list.isHidden = !showsList
            listDivider.isHidden = !showsList
            diffLeading.constant = showsList ? Self.listWidth + 1 : 0
        }
        let compact = bounds.width < Self.wordsMinWidth
        if compact != compactButtons {
            compactButtons = compact
            for (button, title, symbol) in [(openButton, "Open in Editor", "square.and.pencil"), (copyButton, "Copy Path", "doc.on.doc")] {
                if compact {
                    button.title = ""
                    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
                        .withSymbolConfiguration(.init(pointSize: s(11), weight: .medium))
                    button.imagePosition = .imageOnly
                } else {
                    button.image = nil
                    button.imagePosition = .noImage
                    button.attributedTitle = NSAttributedString(string: title, attributes: [
                        .font: NSFont.systemFont(ofSize: s(11.5), weight: .medium), .foregroundColor: Theme.accent,
                    ])
                }
            }
        }
        super.layout()
    }

    // MARK: Keys

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onClose?()
        case 125: model.step(by: 1)
        case 126: model.step(by: -1)
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onClose?() }

    // Clicks stay here, not the panes underneath.
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func scrollWheel(with event: NSEvent) {}
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    /// Whether the keyboard is in this view (the view itself, or its list).
    var hasKeyboard: Bool {
        guard !isHidden, let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    @objc private func close() { onClose?() }

    @objc private func openInEditor() {
        guard let fullPath, let machine = model.target?.machine, model.selectedFile?.status != .deleted else { return NSSound.beep() }
        onOpenInEditor?(machine, fullPath)
    }

    @objc private func copyPath() {
        guard let fullPath else { return NSSound.beep() }
        copy(fullPath)
    }
}

// MARK: The centre diff in the window

/// A machine and the focus on it.
struct FocusPlace: Equatable {
    var machine: MachineKey
    var focus: Focus
}

extension AppDelegate {
    var isChangesDiffShown: Bool { changesDiff?.isHidden == false }

    /// Whether the keyboard is in the inspector's Changes or Activity list. (In Files it never held the
    /// keyboard against the terminal, and still doesn't.)
    var inspectorHoldsKeyboard: Bool {
        guard let fileSidebar, isFileSidebarShown, fileSidebar.shown != .files else { return false }
        return fileSidebar.hasKeyboard
    }

    /// Once per sync: whether the inspector's list keeps the keyboard against the focused pane's terminal.
    /// It does while the focus is where it was when the list took the keyboard. A new Tab, another Tab,
    /// pane, workspace or machine gives the keyboard to the terminal there, as from any other place.
    func inspectorKeepsKeyboard() -> Bool {
        let now = FocusPlace(machine: focusedMachine, focus: store.state.focus)
        defer { lastSyncedFocus = now }
        guard inspectorHoldsKeyboard else {
            inspectorHold = nil
            return false
        }
        // The list took the keyboard since the last sync (a click on a row tells nobody): the focus then
        // was what that sync saw.
        if inspectorHold == nil { inspectorHold = lastSyncedFocus ?? now }
        guard inspectorHold == now else {
            // The focus moved: the terminal there takes the keyboard. Taken again later, the list holds
            // it from where the focus is then.
            inspectorHold = nil
            return false
        }
        return true
    }

    /// Builds the centre diff, hidden, over the pane area. The caller pins it to the pane area's edges.
    func makeChangesDiff() -> ChangesDiffView {
        let diff = ChangesDiffView(model: changesModel)
        diff.isHidden = true
        diff.translatesAutoresizingMaskIntoConstraints = false
        diff.onClose = { [weak self] in self?.closeChangesDiff() }
        diff.onOpenInEditor = { [weak self] key, path in
            guard let self, let machine = connections[key]?.machine else { return NSSound.beep() }
            // This Mac: the file itself, in its default app. Another machine: a copy whose saves go back,
            // as a double-click in Files does.
            openFile(Location(machine: machine, path: path), size: nil)
        }
        container.addSubview(diff)
        changesDiff = diff
        return diff
    }

    /// Shows the selected file's side-by-side diff over the panes. Nothing is created on the daemon:
    /// no Tab, no pane, no shell.
    func openChangesDiff() {
        guard changesModel.selection != nil, let diff = changesDiff else { return NSSound.beep() }
        changesDiffOpened = (focusedMachine, store.state.focus, changesModel.target?.pane)
        diff.tabTitle = store.focusedTab.map { store.displayTitle(of: $0) } ?? ""
        diff.isHidden = false
        inspectorVisibilityChanged()
        diff.update()
        window.makeFirstResponder(diff)
        log("changes: full diff of \(changesModel.selection?.path ?? "?")")
    }

    /// Back to the panes (Back, Esc, ⌘W, or the focus moved).
    func closeChangesDiff() {
        guard isChangesDiffShown else { return }
        let hadKeyboard = changesDiff.hasKeyboard
        changesDiff.isHidden = true
        changesDiffOpened = nil
        inspectorVisibilityChanged()
        if hadKeyboard { window.makeFirstResponder(activeTerminal) }
    }

    /// Every sync: the diff belongs to where the focus was. Another Tab, pane or machine, or a list that
    /// moved to another pane (the one it was on is gone), closes it.
    func closeChangesDiffIfMoved() {
        guard isChangesDiffShown, let opened = changesDiffOpened else { return }
        if opened.machine != focusedMachine || opened.focus != store.state.focus || opened.target != changesModel.target?.pane {
            closeChangesDiff()
        }
    }
}
