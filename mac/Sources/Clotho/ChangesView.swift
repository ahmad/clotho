import AppKit
import ClothoKit

// The inspector's Changes view (ChangesModel has what it shows): a summary line ("6 files vs main  +128
// −32"), the changed files in two groups (Uncommitted, On this branch), and under the list the selected
// file's diff, unified. Return or a double-click opens the file's side-by-side diff in the centre
// (ChangesDiffView). Read-only: nothing here stages, commits or discards.
//
// Paths and diff text come from the repository and are drawn as plain text, through `DiffText.display`.

/// The list of changed files, in the inspector and beside the centre diff.
final class ChangesListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    enum Row: Equatable {
        /// "Uncommitted" with its count, "On this branch" with "4 commits · vs origin/main".
        case group(String, String)
        case file(GitChangedFile, GitChangeGroup)
        /// "and 12 more": the list was cut.
        case more(Int)
        /// Why a group has no list.
        case note(String)
    }

    /// The table takes Return and Esc itself: a list has no default button to give them to.
    final class Table: NSTableView {
        var onReturn: (() -> Void)?
        var onEscape: (() -> Void)?

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 36, 76: onReturn?()
            case 53: onEscape?()
            default: super.keyDown(with: event)
            }
        }

        override func cancelOperation(_ sender: Any?) { onEscape?() }
    }

    /// The selection in the app's accent, as the command bar draws it, key window or not.
    final class RowView: NSTableRowView {
        override func drawSelection(in dirtyRect: NSRect) {
            Theme.accent.withAlphaComponent(0.22).setFill()
            bounds.fill()
        }

        override var isEmphasized: Bool {
            get { false }
            set {}
        }
    }

    let table = Table()
    let scroll = NSScrollView()
    private(set) var rows: [Row] = []
    /// A file was selected (nil: none is).
    var onSelect: ((GitChangedFile?, GitChangeGroup) -> Void)?
    /// Return or a double-click on a file.
    var onOpen: ((GitChangedFile, GitChangeGroup) -> Void)?
    /// Esc: the keyboard goes back to the terminal.
    var onLeave: (() -> Void)?
    private var applying = false
    private var laidOutWidth: CGFloat = 0

    static var fileRowHeight: CGFloat { s(24) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: .init("file"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.onReturn = { [weak self] in self?.openSelected() }
        table.onEscape = { [weak self] in self?.onLeave?() }
        table.setAccessibilityLabel("Changed files")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The rows of a reply: each group's header, its files, and what stands in for files that aren't listed.
    static func rows(for changes: GitChanges) -> [Row] {
        var rows: [Row] = [.group("Uncommitted", "\(changes.uncommitted.total)")]
        rows += changes.uncommitted.files.map { .file($0, .uncommitted) }
        if changes.uncommitted.more > 0 { rows.append(.more(changes.uncommitted.more)) }
        if let branch = changes.branchChanges {
            let commits = branch.commits == 1 ? "1 commit" : "\(branch.commits) commits"
            rows.append(.group("On this branch", "\(commits) · vs \(DiffText.display(branch.base))"))
            rows += branch.files.map { .file($0, .branch) }
            if branch.more > 0 { rows.append(.more(branch.more)) }
        } else if let words = GitText.branchReason(changes.branchReason) {
            rows.append(.group("On this branch", ""))
            rows.append(.note(words))
        }
        return rows
    }

    func show(_ changes: GitChanges?, selection: ChangesModel.Selection?) {
        let new = changes.map(Self.rows) ?? []
        applying = true
        defer { applying = false }
        if new != rows {
            rows = new
            table.reloadData()
        }
        let index = selection.flatMap { selection in
            rows.firstIndex { if case let .file(file, group) = $0 { group == selection.group && file.path == selection.path } else { false } }
        }
        if let index {
            if table.selectedRow != index { table.selectRowIndexes([index], byExtendingSelection: false) }
        } else if table.selectedRow >= 0 {
            table.deselectAll(nil)
        }
    }

    /// Gives the list the keyboard, on its selected file or else its first.
    func takeKeyboard() {
        window?.makeFirstResponder(table)
        guard table.selectedRow < 0, let first = rows.firstIndex(where: { if case .file = $0 { true } else { false } }) else { return }
        table.selectRowIndexes([first], byExtendingSelection: false)
        table.scrollRowToVisible(first)
    }

    func openSelected() {
        guard rows.indices.contains(table.selectedRow), case let .file(file, group) = rows[table.selectedRow] else { return }
        onOpen?(file, group)
    }

    @objc private func doubleClicked() {
        guard rows.indices.contains(table.clickedRow), case let .file(file, group) = rows[table.clickedRow] else { return }
        onOpen?(file, group)
    }

    override func layout() {
        super.layout()
        // A note wraps, so its row's height follows the width.
        guard abs(bounds.width - laidOutWidth) > 0.5 else { return }
        laidOutWidth = bounds.width
        let notes = IndexSet(rows.indices.filter { if case .note = rows[$0] { true } else { false } })
        if !notes.isEmpty { table.noteHeightOfRows(withIndexesChanged: notes) }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .group: return s(26)
        case .file: return Self.fileRowHeight
        case .more: return s(22)
        case let .note(text):
            let width = max(bounds.width - s(24), s(120))
            let size = (text as NSString).boundingRect(with: NSSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin],
                                                       attributes: [.font: NSFont.systemFont(ofSize: s(11))])
            return ceil(size.height) + s(10)
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .file = rows[row] { true } else { false }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { RowView() }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applying else { return }
        if rows.indices.contains(table.selectedRow), case let .file(file, group) = rows[table.selectedRow] {
            onSelect?(file, group)
        } else {
            onSelect?(nil, .uncommitted)
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        cell(for: rows[row])
    }

    /// One row's view (tests read rows through this too).
    func cell(for row: Row) -> NSView {
        switch row {
        case let .group(title, detail): return Self.groupCell(title, detail)
        case let .file(file, _): return ChangedFileCell(file)
        case let .more(count): return Self.textCell("and \(count.formatted()) more", color: Theme.dimText, wraps: false)
        case let .note(text): return Self.textCell(text, color: Theme.dimText, wraps: true)
        }
    }

    private static func groupCell(_ title: String, _ detail: String) -> NSView {
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: s(11), weight: .semibold)
        name.textColor = Theme.secondaryText
        name.setContentCompressionResistancePriority(.required, for: .horizontal)
        let more = NSTextField(labelWithString: detail)
        more.font = .monospacedDigitSystemFont(ofSize: s(10.5), weight: .regular)
        more.textColor = Theme.dimText
        more.lineBreakMode = .byTruncatingTail
        more.alignment = .right
        more.toolTip = detail
        more.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cell = NSView()
        for view in [name, more] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: s(12)),
            name.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -s(4)),
            more.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: s(8)),
            more.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -s(12)),
            more.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
        ])
        cell.setAccessibilityElement(true)
        cell.setAccessibilityRole(.staticText)
        cell.setAccessibilityLabel(detail.isEmpty ? title : "\(title), \(detail)")
        return cell
    }

    private static func textCell(_ text: String, color: NSColor, wraps: Bool) -> NSView {
        let label = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: s(11))
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        let cell = NSView()
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: s(12)),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -s(12)),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

/// A changed file's row: its status letter, its path (cut in the middle, whole in the tooltip) and its
/// lines.
final class ChangedFileCell: NSView {
    let letter = NSTextField(labelWithString: "")
    let path = NSTextField(labelWithString: "")
    let counts = NSTextField(labelWithString: "")

    init(_ file: GitChangedFile) {
        super.init(frame: .zero)
        letter.stringValue = file.status.letter
        letter.font = .monospacedSystemFont(ofSize: s(11.5), weight: .medium)
        letter.textColor = Self.letterColor(file.status)
        letter.alignment = .center
        path.stringValue = DiffText.display(file.path)
        path.font = .monospacedSystemFont(ofSize: s(11.5), weight: .regular)
        path.textColor = Theme.foreground
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        path.setContentHuggingPriority(.defaultLow, for: .horizontal)
        if let title = Self.counts(file) { counts.attributedStringValue = title }
        counts.setContentCompressionResistancePriority(.required, for: .horizontal)
        counts.setContentHuggingPriority(.required, for: .horizontal)
        for view in [letter, path, counts] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            letter.leadingAnchor.constraint(equalTo: leadingAnchor, constant: s(10)),
            letter.widthAnchor.constraint(equalToConstant: s(14)),
            letter.centerYAnchor.constraint(equalTo: centerYAnchor),
            path.leadingAnchor.constraint(equalTo: letter.trailingAnchor, constant: s(6)),
            path.centerYAnchor.constraint(equalTo: centerYAnchor),
            counts.leadingAnchor.constraint(greaterThanOrEqualTo: path.trailingAnchor, constant: s(8)),
            counts.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -s(12)),
            counts.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = Self.tooltip(file)
        // A file Clotho can't ask for is listed, but dim: there is no diff behind it.
        if !file.diffable { alphaValue = 0.55 }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(Self.spoken(file))
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The letter differs per status, so the colour is never the only sign.
    static func letterColor(_ status: GitChangedFile.Status) -> NSColor {
        switch status {
        case .modified: return Theme.caution
        case .added, .untracked: return Theme.success
        case .deleted, .conflicted: return Theme.danger
        case .renamed: return Theme.accent
        }
    }

    /// "+12 −2" in green and red; "bin" for a binary file; nothing when the lines weren't counted.
    static func counts(_ file: GitChangedFile) -> NSAttributedString? {
        let font = NSFont.monospacedDigitSystemFont(ofSize: s(10.5), weight: .regular)
        if file.binary { return NSAttributedString(string: "bin", attributes: [.font: font, .foregroundColor: Theme.dimText]) }
        guard let added = file.added, let removed = file.removed else { return nil }
        let title = NSMutableAttributedString()
        if added > 0 || removed == 0 {
            title.append(NSAttributedString(string: "+\(added)", attributes: [.font: font, .foregroundColor: Theme.success]))
        }
        if removed > 0 {
            title.append(NSAttributedString(string: "\(title.length > 0 ? " " : "")\u{2212}\(removed)", attributes: [.font: font, .foregroundColor: Theme.danger]))
        }
        return title
    }

    /// The whole path; a renamed file's old one first.
    static func tooltip(_ file: GitChangedFile) -> String {
        let path = DiffText.display(file.path)
        return file.oldPath.map { "\(DiffText.display($0)) → \(path)" } ?? path
    }

    /// "Modified, src/login.rs, 12 lines added, 2 removed".
    static func spoken(_ file: GitChangedFile) -> String {
        var parts = [file.status.word.prefix(1).uppercased() + file.status.word.dropFirst(), DiffText.display(file.path)]
        if let old = file.oldPath { parts.append("renamed from \(DiffText.display(old))") }
        if file.binary {
            parts.append("binary")
        } else if let added = file.added, let removed = file.removed {
            parts.append("\(added) \(added == 1 ? "line" : "lines") added, \(removed) removed")
        }
        if !file.diffable { parts.append("no diff available") }
        return parts.joined(separator: ", ")
    }
}

/// A centred line of words where a list or a diff would be, with a spinner while something is read.
final class ChangesMessageView: NSView {
    let label = NSTextField(wrappingLabelWithString: "")
    let spinner = NSProgressIndicator()

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: s(12))
        label.textColor = Theme.dimText
        label.alignment = .center
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = s(8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: s(14)),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -s(14)),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -s(28)),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: s(8)),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String, busy: Bool) {
        label.stringValue = text
        setAccessibilityLabel(text)
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        spinner.isHidden = !busy
        isHidden = false
    }
}

/// One file's diff, or the words for why there is none: in the inspector (unified) and in the centre
/// (side by side).
final class DiffAreaView: NSView {
    let table: DiffTableView
    let message = ChangesMessageView()

    init(mode: DiffTableView.Mode) {
        table = DiffTableView(mode: mode)
        super.init(frame: .zero)
        for view in [table, message] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
        message.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    static let binaryWords = "Binary file: no text diff."
    static let undiffableWords = "Clotho can't show this file's diff: its name has characters it can't send."
    static let readingWords = "Reading the diff…"

    /// The words in place of a diff, and whether something is still being read. Nil: there are lines to show.
    static func words(for state: ChangesModel.DiffState) -> (text: String, busy: Bool)? {
        switch state {
        case .none: return ("", false)
        case .loading: return (readingWords, true)
        case .undiffable: return (undiffableWords, false)
        case let .failed(text): return (text, false)
        case let .loaded(diff):
            if diff.binary { return (binaryWords, false) }
            guard diff.hunks.isEmpty else { return nil }
            if diff.status == .renamed, let old = diff.oldPath { return ("Renamed from \(DiffText.display(old)). No content changes.", false) }
            return ("No content changes.", false)
        }
    }

    func show(_ state: ChangesModel.DiffState) {
        if let words = Self.words(for: state) {
            table.isHidden = true
            table.show(nil)
            message.show(words.text, busy: words.busy)
        } else if case let .loaded(diff) = state {
            message.isHidden = true
            table.isHidden = false
            table.show(diff)
        }
    }
}

/// The list over the selected file's diff. With the diff hidden there is one part and no divider. A plain
/// NSSplitView keeps its divider on screen where it last was, a line across the list that outlives
/// `needsDisplay`; one whose `drawDivider` is overridden draws its dividers through it, and this draws
/// none while a part is hidden (not at the bottom edge either).
final class ChangesSplitView: NSSplitView {
    override func drawDivider(in rect: NSRect) {
        if arrangedSubviews.contains(where: \.isHidden) { return }
        super.drawDivider(in: rect)
    }
}

/// The inspector's Changes view.
final class ChangesView: NSView, NSSplitViewDelegate {
    let model: ChangesModel
    let summary = NSTextField(labelWithString: "")
    let counts = NSTextField(labelWithString: "")
    let followButton = NSButton()
    private(set) var refreshButton: QuietButton!
    let list = ChangesListView()
    let diffTitle = NSTextField(labelWithString: "")
    private(set) var openButton: QuietButton!
    let diffArea = DiffAreaView(mode: .unified)
    let message = ChangesMessageView()
    private let split = ChangesSplitView()
    private let diffBox = NSView()
    /// What the diff box shows. The box itself is the split view's: hidden, it is collapsed to no size at
    /// all, and insets pinned to a box of no size can't hold ("Conflicting constraints detected", once
    /// per layout). So the insets are pinned to this view, which is exactly the box whenever the box has
    /// room and never smaller than `diffContentLeast` when it has none.
    let diffContent = NSView()
    static var diffContentLeast: NSSize { NSSize(width: s(120), height: s(72)) }
    private let followRow = NSView()
    private var bodyTop: NSLayoutConstraint!
    private var placedDivider = false
    /// Return or a double-click on a file: its full diff, in the centre.
    var onOpenFull: ((GitChangedFile, GitChangeGroup) -> Void)?
    /// Esc in the list.
    var onLeave: (() -> Void)?

    static let splitKey = "InspectorChangesSplit"
    static var headerHeight: CGFloat { s(30) }
    static var followHeight: CGFloat { s(26) }

    init(model: ChangesModel) {
        self.model = model
        super.init(frame: .zero)
        setAccessibilityLabel("Changes")

        summary.font = .systemFont(ofSize: s(11.5))
        summary.textColor = Theme.secondaryText
        summary.lineBreakMode = .byTruncatingTail
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        counts.setContentCompressionResistancePriority(.required, for: .horizontal)
        counts.setContentHuggingPriority(.required, for: .horizontal)
        refreshButton = QuietButton(symbol: "arrow.clockwise", label: "Refresh changes", pointSize: s(11)) { [weak self] in self?.model.refresh() }
        refreshButton.toolTip = "Refresh changes"

        followButton.title = "↩ Follow Pane"
        followButton.bezelStyle = .inline
        followButton.controlSize = .small
        followButton.font = NSFont.systemFont(ofSize: s(11), weight: .medium)
        followButton.toolTip = "Go back to the focused pane's changes, and follow it again"
        followButton.target = self
        followButton.action = #selector(followAgain)
        followButton.translatesAutoresizingMaskIntoConstraints = false
        followRow.addSubview(followButton)
        followRow.isHidden = true

        list.onSelect = { [weak self] file, group in self?.model.select(file, group: group) }
        list.onOpen = { [weak self] file, group in
            self?.model.select(file, group: group)
            self?.onOpenFull?(file, group)
        }
        list.onLeave = { [weak self] in self?.onLeave?() }

        diffTitle.font = .monospacedSystemFont(ofSize: s(10.5), weight: .regular)
        diffTitle.textColor = Theme.dimText
        diffTitle.lineBreakMode = .byTruncatingHead
        diffTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        openButton = QuietButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Open the full diff", pointSize: s(10)) { [weak self] in
            self?.list.openSelected()
        }
        openButton.toolTip = "Open the full diff, side by side (↩)"
        let rule = NSBox()
        rule.boxType = .custom
        rule.borderWidth = 0
        rule.fillColor = Theme.divider
        diffContent.translatesAutoresizingMaskIntoConstraints = false
        diffBox.addSubview(diffContent)
        // The box's size whenever it can be (999), and its least size when the box is collapsed.
        let fills = [diffContent.widthAnchor.constraint(equalTo: diffBox.widthAnchor),
                     diffContent.heightAnchor.constraint(equalTo: diffBox.heightAnchor)]
        fills.forEach { $0.priority = NSLayoutConstraint.Priority(999) }
        NSLayoutConstraint.activate(fills + [
            diffContent.leadingAnchor.constraint(equalTo: diffBox.leadingAnchor),
            diffContent.topAnchor.constraint(equalTo: diffBox.topAnchor),
            diffContent.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.diffContentLeast.width),
            diffContent.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.diffContentLeast.height),
        ])
        for view in [diffTitle, openButton!, diffArea, rule] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            diffContent.addSubview(view)
        }
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: diffContent.topAnchor),
            rule.leadingAnchor.constraint(equalTo: diffContent.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: diffContent.trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            diffTitle.leadingAnchor.constraint(equalTo: diffContent.leadingAnchor, constant: s(10)),
            diffTitle.centerYAnchor.constraint(equalTo: diffContent.topAnchor, constant: s(12)),
            openButton.leadingAnchor.constraint(greaterThanOrEqualTo: diffTitle.trailingAnchor, constant: s(6)),
            openButton.trailingAnchor.constraint(equalTo: diffContent.trailingAnchor, constant: -s(8)),
            openButton.centerYAnchor.constraint(equalTo: diffTitle.centerYAnchor),
            openButton.widthAnchor.constraint(equalToConstant: s(18)),
            openButton.heightAnchor.constraint(equalToConstant: s(18)),
            diffArea.topAnchor.constraint(equalTo: diffContent.topAnchor, constant: s(24)),
            diffArea.leadingAnchor.constraint(equalTo: diffContent.leadingAnchor, constant: 1),
            diffArea.trailingAnchor.constraint(equalTo: diffContent.trailingAnchor),
            diffArea.bottomAnchor.constraint(equalTo: diffContent.bottomAnchor),
        ])

        split.isVertical = false
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(list)
        split.addArrangedSubview(diffBox)
        diffBox.isHidden = true

        for view in [summary, counts, refreshButton!, followRow, split, message] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        bodyTop = split.topAnchor.constraint(equalTo: topAnchor, constant: Self.headerHeight)
        NSLayoutConstraint.activate([
            summary.leadingAnchor.constraint(equalTo: leadingAnchor, constant: s(12)),
            summary.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.headerHeight / 2),
            counts.leadingAnchor.constraint(greaterThanOrEqualTo: summary.trailingAnchor, constant: s(8)),
            counts.centerYAnchor.constraint(equalTo: summary.centerYAnchor),
            refreshButton.leadingAnchor.constraint(equalTo: counts.trailingAnchor, constant: s(6)),
            refreshButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -s(8)),
            refreshButton.centerYAnchor.constraint(equalTo: summary.centerYAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: s(18)),
            refreshButton.heightAnchor.constraint(equalToConstant: s(18)),
            followRow.topAnchor.constraint(equalTo: topAnchor, constant: Self.headerHeight),
            followRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            followRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            followRow.heightAnchor.constraint(equalToConstant: Self.followHeight),
            followButton.leadingAnchor.constraint(equalTo: followRow.leadingAnchor, constant: s(10)),
            followButton.topAnchor.constraint(equalTo: followRow.topAnchor),
            bodyTop,
            split.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),
            message.topAnchor.constraint(equalTo: split.topAnchor),
            message.bottomAnchor.constraint(equalTo: bottomAnchor),
            message.leadingAnchor.constraint(equalTo: leadingAnchor),
            message.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        model.observe { [weak self] in self?.update() }
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func followAgain() { model.followAgain() }

    /// The words where the list would be, and whether something is being read. Nil: there is a list.
    static func words(for state: ChangesModel.ListState, target: ChangesModel.Target?) -> (text: String, busy: Bool)? {
        switch state {
        case .none:
            guard let target else { return ("No pane is focused.", false) }
            return target.featureOn ? ("", false) : ("Changes need clothod 0.1.32 or newer on \(target.machineName).", false)
        case .notARepo: return ("This pane isn't in a git repository.", false)
        case let .unknown(text, pending): return (text, pending)
        case .empty: return ("No changes", false)
        case .loading: return (GitText.readingChanges, true)
        case let .failed(text): return (text, false)
        case .loaded: return nil
        }
    }

    /// "+128" in green and "−32" in red, or nil when the lines weren't counted.
    static func countsTitle(added: Int?, removed: Int?) -> NSAttributedString? {
        guard let added, let removed else { return nil }
        let font = NSFont.monospacedDigitSystemFont(ofSize: s(11), weight: .regular)
        let title = NSMutableAttributedString(string: "+\(added)", attributes: [.font: font, .foregroundColor: Theme.success])
        title.append(NSAttributedString(string: " \u{2212}\(removed)", attributes: [.font: font, .foregroundColor: Theme.danger]))
        return title
    }

    func update() {
        let changes = model.target?.git?.changes
        // The summary is the pane's own (the strip shows the same numbers); the list is under it.
        var showsSummary = false
        switch model.list {
        case .loaded, .loading: showsSummary = changes?.isEmpty == false
        default: break
        }
        if showsSummary, let changes {
            summary.stringValue = ChangesModel.summary(changes)
            let total = changes.total
            counts.attributedStringValue = Self.countsTitle(added: total.added, removed: total.removed) ?? NSAttributedString()
            let breakdown = ChangesModel.breakdown(changes)
            summary.toolTip = breakdown
            counts.toolTip = breakdown
            summary.setAccessibilityLabel("\(summary.stringValue). \(breakdown)")
        } else {
            summary.stringValue = model.target?.git.map { DiffText.display($0.summary) } ?? ""
            summary.toolTip = nil
            summary.setAccessibilityLabel(summary.stringValue)
            counts.attributedStringValue = NSAttributedString()
        }
        refreshButton.isHidden = model.target?.git == nil || model.target?.featureOn != true

        let pinned = !model.following && model.target != nil
        followRow.isHidden = !pinned
        bodyTop.constant = Self.headerHeight + (pinned ? Self.followHeight : 0)

        if let words = Self.words(for: model.list, target: model.target) {
            split.isHidden = true
            message.show(words.text, busy: words.busy)
            list.show(nil, selection: nil)
        } else if case let .loaded(listed) = model.list {
            message.isHidden = true
            split.isHidden = false
            list.show(listed, selection: model.selection)
        }

        let showsDiff = model.selection != nil && !split.isHidden
        if let file = model.selectedFile {
            diffTitle.stringValue = DiffText.display(file.name)
            diffTitle.toolTip = ChangedFileCell.tooltip(file)
        }
        diffArea.show(showsDiff ? model.diff : .none)
        if diffBox.isHidden == showsDiff {
            diffBox.isHidden = !showsDiff
            split.adjustSubviews()
            split.needsDisplay = true
            placedDivider = false
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        placeDivider()
    }

    /// Where the divider was left (a share of the height), the first time the diff shows in this size.
    private func placeDivider() {
        guard !placedDivider, !diffBox.isHidden, split.bounds.height > s(120) else { return }
        placedDivider = true
        let saved = UserDefaults.standard.double(forKey: Self.splitKey)
        let share = saved > 0.15 && saved < 0.85 ? saved : 0.45
        split.setPosition((split.bounds.height * share).rounded(), ofDividerAt: 0)
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        s(72)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(s(72), splitView.bounds.height - s(72))
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // Only a drag is remembered, not the sidebar or the window changing size.
        guard placedDivider, !diffBox.isHidden, split.bounds.height > s(120), NSApp.currentEvent?.type == .leftMouseDragged else { return }
        UserDefaults.standard.set(Double(list.frame.height / split.bounds.height), forKey: Self.splitKey)
    }
}
