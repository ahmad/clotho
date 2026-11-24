import AppKit
import ClothoKit

// One file's diff as rows, read-only: unified (the inspector) or side by side (the centre view: the old
// file on the left, the new one on the right, a row per pair of lines).
//
// A diff's text is the file's own content and is not trusted: it reaches the screen only as a label's
// plain `stringValue`, after `DiffText.display` made escape sequences and invisible characters visible.
// No markup, no links, no attributed text from it.
//
// Long lines wrap by character, so nothing is cut off and the two sides stay level row by row. The
// unified rows have one number column (the new file's line, or the old file's for a removed line): the
// inspector is narrow, and the sign beside the number says which file it counts in. Added
// and removed lines are tinted with the palette's green and red at the agent chips' alpha; the +/− sign
// and the row's spoken label carry the meaning without colour. A long diff is drawn a few thousand rows
// at a time ("Show more lines").

final class DiffTableView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    enum Mode { case unified, sideBySide }

    enum Item: Equatable {
        /// A hunk's header line: "@@ −10,3 +10,4 @@ fn login() {".
        case hunk(String)
        case line(GitDiff.Line)
        case pair(GitDiff.Row)
        /// "No newline at end of file", or that the diff was cut.
        case note(String)
        /// What isn't drawn yet.
        case more(Int)
    }

    static let truncatedNote = "This diff is long: this is its first part."
    static let noNewlineNote = "No newline at end of file"
    static let cutTip = "This line is longer than 2,000 characters"
    /// Rows drawn at first, and added by each "Show more lines".
    static let page = 3000

    let mode: Mode
    let table = NSTableView()
    let scroll = NSScrollView()
    private var all: [Item] = []
    private var limit = DiffTableView.page
    /// The rows as drawn.
    private(set) var items: [Item] = []
    private var numberWidth: CGFloat = 0
    /// The width the rows were last built for: their text wraps to it.
    private var builtWidth: CGFloat = 0
    var font: NSFont { NSFont.monospacedSystemFont(ofSize: mode == .unified ? s(10.5) : s(11), weight: .regular) }

    init(mode: Mode) {
        self.mode = mode
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: .init("diff"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.usesAutomaticRowHeights = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.backgroundColor = Theme.background
        table.allowsEmptySelection = true
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel(mode == .unified ? "Diff" : "Diff, side by side")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.background
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

    /// The rows of a diff: per hunk its header, then its lines (or pairs of lines).
    static func items(for diff: GitDiff, mode: Mode) -> [Item] {
        var items: [Item] = []
        for hunk in diff.hunks {
            items.append(.hunk(header(hunk)))
            switch mode {
            case .unified:
                for line in hunk.lines {
                    items.append(.line(line))
                    if line.noNewline { items.append(.note(noNewlineNote)) }
                }
            case .sideBySide:
                for row in hunk.sideBySideRows() {
                    items.append(.pair(row))
                    if row.old?.noNewline == true || row.new?.noNewline == true { items.append(.note(noNewlineNote)) }
                }
            }
        }
        if diff.truncated { items.append(.note(truncatedNote)) }
        return items
    }

    /// "@@ −10,3 +10,4 @@" and what git printed after it. The daemon's header is often empty, so the
    /// ranges always show.
    static func header(_ hunk: GitDiff.Hunk) -> String {
        let ranges = "@@ \u{2212}\(hunk.oldStart),\(hunk.oldLines) +\(hunk.newStart),\(hunk.newLines) @@"
        let rest = DiffText.display(hunk.header.trimmingCharacters(in: .whitespaces))
        return rest.isEmpty ? ranges : "\(ranges) \(rest)"
    }

    /// A line's text as drawn: made safe, with " …" after one the daemon cut.
    static func display(_ line: GitDiff.Line) -> String {
        DiffText.display(line.text) + (line.cut ? " …" : "")
    }

    /// What VoiceOver says for a line: "added, line 11: let user = user?;".
    static func spoken(_ line: GitDiff.Line) -> String {
        let kind = switch line.kind {
        case .added: "added"
        case .removed: "removed"
        case .context: "unchanged"
        }
        let number = line.new ?? line.old
        return "\(kind)\(number.map { ", line \($0)" } ?? ""): \(display(line))"
    }

    /// The tint behind an added or removed line in one appearance: the palette's green or red, and how
    /// much of it shows over the background.
    nonisolated static func tint(_ kind: GitDiff.Line.Kind, for appearance: ClothoPalette.Appearance) -> (hex: UInt32, alpha: CGFloat)? {
        let palette = appearance == .dark ? ClothoPalette.dark : ClothoPalette.light
        switch kind {
        case .added: return (palette.ansi[2], AgentMark.tintAlpha(for: appearance))
        case .removed: return (palette.ansi[1], AgentMark.tintAlpha(for: appearance))
        case .context: return nil
        }
    }

    static func tintColor(_ kind: GitDiff.Line.Kind) -> NSColor? {
        guard kind != .context else { return nil }
        return NSColor(name: nil) { appearance in
            guard let found = DiffTableView.tint(kind, for: appearance.isDark ? .dark : .light) else { return .clear }
            return NSColor(hex: found.hex).withAlphaComponent(found.alpha)
        }
    }

    /// Shows a diff (nil: nothing), from its top.
    func show(_ diff: GitDiff?) {
        let new = diff.map { Self.items(for: $0, mode: mode) } ?? []
        guard new != all else { return }
        // The same file read again (the poll): the place in it is kept.
        let sameFile = !all.isEmpty && !new.isEmpty && shownPath == diff?.path
        shownPath = diff?.path
        all = new
        if !sameFile { limit = Self.page }
        let top = scroll.contentView.bounds.origin
        apply()
        if sameFile { scroll.contentView.scroll(to: top) } else { table.scrollRowToVisible(0) }
    }

    private var shownPath: String?

    private func apply() {
        let numbers = all.flatMap { item -> [Int] in
            switch item {
            case let .line(line): return [line.old ?? 0, line.new ?? 0]
            case let .pair(row): return [row.old?.old ?? 0, row.new?.new ?? 0]
            default: return []
            }
        }
        let digits = max(3, String(numbers.max() ?? 0).count)
        numberWidth = ceil(("0" as NSString).size(withAttributes: [.font: font]).width * CGFloat(digits)) + s(6)
        items = all.count > limit ? Array(all.prefix(limit)) + [.more(all.count - limit)] : all
        table.rowHeight = ceil(font.ascender - font.descender + font.leading) + 3
        builtWidth = scroll.contentSize.width
        table.reloadData()
    }

    private func showMore() {
        limit += Self.page
        apply()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        table.backgroundColor = Theme.background
        scroll.backgroundColor = Theme.background
    }

    override func layout() {
        super.layout()
        // The rows wrap to the width they were built for: another width, and they are built again.
        let width = scroll.contentSize.width
        guard abs(width - builtWidth) > 0.5, !items.isEmpty else { return }
        builtWidth = width
        table.reloadData()
    }

    /// The room a line's text has in a row `width` wide: what the numbers, the sign and the gaps leave.
    private func textWidth(in width: CGFloat) -> CGFloat {
        let side = mode == .unified ? width : ((width - 1) / 2).rounded(.down)
        return max(s(40), side - DiffRowView.textInset(numberWidth: numberWidth) - DiffRowView.trailingInset)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        return rowView(for: items[row])
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    /// The view of one row (tests draw rows through this too).
    func rowView(for item: Item) -> DiffRowView {
        let width = scroll.contentSize.width
        let wrapWidth = width > 0 ? textWidth(in: width) : nil
        switch item {
        case let .hunk(text): return DiffRowView(banner: text, font: font, fill: Theme.hover)
        case let .note(text): return DiffRowView(banner: text, font: font, fill: nil)
        case let .more(count):
            return DiffRowView(more: count) { [weak self] in self?.showMore() }
        case let .line(line): return DiffRowView(line: line, font: font, numberWidth: numberWidth, textWidth: wrapWidth)
        case let .pair(row): return DiffRowView(pair: row, font: font, numberWidth: numberWidth, textWidth: wrapWidth)
        }
    }
}

/// One row of a diff. Every string from the file goes into a plain label.
final class DiffRowView: NSView {
    /// The labels' text, leading to trailing (tests).
    private(set) var texts: [String] = []
    private var fills: [(view: NSView, color: NSColor)] = []

    private static func label(_ text: String, font: NSFont, color: NSColor, wraps: Bool = false) -> NSTextField {
        let label = wraps ? NSTextField(wrappingLabelWithString: "") : NSTextField(labelWithString: "")
        // Plain text only. An empty line keeps its height.
        label.stringValue = text.isEmpty ? " " : text
        label.font = font
        label.textColor = color
        label.isSelectable = false
        label.allowsEditingTextAttributes = false
        label.translatesAutoresizingMaskIntoConstraints = false
        if wraps {
            label.lineBreakMode = .byCharWrapping
            label.maximumNumberOfLines = 0
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        return label
    }

    /// Where a line's text starts in its row (or its half): after the number and the sign.
    static func textInset(numberWidth: CGFloat) -> CGFloat { s(4) + numberWidth + s(6) + s(9) + s(3) }
    static var trailingInset: CGFloat { s(6) }

    private func fill(_ view: NSView, _ color: NSColor?) {
        guard let color else { return }
        view.wantsLayer = true
        fills.append((view, color))
    }

    /// A hunk's header, or a note: one dim line across the row.
    init(banner text: String, font: NSFont, fill color: NSColor?) {
        super.init(frame: .zero)
        let label = Self.label(text, font: font, color: Theme.dimText, wraps: true)
        texts = [text]
        addSubview(label)
        fill(self, color)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: s(10)),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -s(10)),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
    }

    /// "Show 3,000 more lines".
    init(more count: Int, action: @escaping () -> Void) {
        super.init(frame: .zero)
        let next = min(count, DiffTableView.page)
        let title = "Show \(next.formatted()) more \(next == 1 ? "line" : "lines")"
        let button = ClosureButton(title: title, action: action)
        button.bezelStyle = .inline
        button.controlSize = .small
        button.translatesAutoresizingMaskIntoConstraints = false
        texts = [title]
        addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.topAnchor.constraint(equalTo: topAnchor, constant: s(6)),
            button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -s(6)),
        ])
    }

    /// A unified row: the line's number (in the new file, or in the old one for a removed line), the
    /// sign, the text.
    init(line: GitDiff.Line, font: NSFont, numberWidth: CGFloat, textWidth: CGFloat? = nil) {
        super.init(frame: .zero)
        let number = Self.label((line.new ?? line.old).map(String.init) ?? "", font: font, color: Theme.faintText)
        let sign = Self.label(line.kind == .added ? "+" : line.kind == .removed ? "\u{2212}" : "", font: font, color: Theme.secondaryText)
        let text = Self.label(DiffTableView.display(line), font: font, color: Theme.foreground, wraps: true)
        number.alignment = .right
        if let textWidth { text.preferredMaxLayoutWidth = textWidth }
        if line.cut { text.toolTip = DiffTableView.cutTip }
        texts = [number, sign, text].map(\.stringValue)
        for view in [number, sign, text] { addSubview(view) }
        fill(self, DiffTableView.tintColor(line.kind))
        NSLayoutConstraint.activate([
            number.leadingAnchor.constraint(equalTo: leadingAnchor, constant: s(4)),
            number.widthAnchor.constraint(equalToConstant: numberWidth),
            sign.leadingAnchor.constraint(equalTo: number.trailingAnchor, constant: s(6)),
            sign.widthAnchor.constraint(equalToConstant: s(9)),
            text.leadingAnchor.constraint(equalTo: sign.trailingAnchor, constant: s(3)),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailingInset),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            number.topAnchor.constraint(equalTo: text.topAnchor),
            sign.topAnchor.constraint(equalTo: text.topAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(DiffTableView.spoken(line))
    }

    /// A side-by-side row: the old file's line in the left half, the new file's in the right.
    init(pair: GitDiff.Row, font: NSFont, numberWidth: CGFloat, textWidth: CGFloat? = nil) {
        super.init(frame: .zero)
        let left = half(pair.old, number: pair.old?.old, changed: pair.old?.kind == .removed ? .removed : .context, font: font,
                        numberWidth: numberWidth, textWidth: textWidth)
        let right = half(pair.new, number: pair.new?.new, changed: pair.new?.kind == .added ? .added : .context, font: font,
                         numberWidth: numberWidth, textWidth: textWidth)
        let divider = NSView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)
        fill(divider, Theme.divider)
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: leadingAnchor),
            left.topAnchor.constraint(equalTo: topAnchor),
            left.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: left.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            right.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor),
            right.topAnchor.constraint(equalTo: topAnchor),
            right.bottomAnchor.constraint(equalTo: bottomAnchor),
            left.widthAnchor.constraint(equalTo: right.widthAnchor),
        ])
        let spoken: [String]
        if let old = pair.old, let new = pair.new, old.kind == .context, new.kind == .context {
            spoken = [DiffTableView.spoken(new)]
        } else {
            spoken = [pair.old, pair.new].compactMap { $0 }.map(DiffTableView.spoken)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(spoken.joined(separator: "; "))
    }

    private func half(_ line: GitDiff.Line?, number: Int?, changed: GitDiff.Line.Kind, font: NSFont, numberWidth: CGFloat,
                      textWidth: CGFloat?) -> NSView {
        let half = NSView()
        half.translatesAutoresizingMaskIntoConstraints = false
        addSubview(half)
        let numberLabel = Self.label(number.map(String.init) ?? "", font: font, color: Theme.faintText)
        numberLabel.alignment = .right
        let sign = Self.label(changed == .added ? "+" : changed == .removed ? "\u{2212}" : "", font: font, color: Theme.secondaryText)
        let text = Self.label(line.map(DiffTableView.display) ?? "", font: font, color: Theme.foreground, wraps: true)
        if line?.cut == true { text.toolTip = DiffTableView.cutTip }
        if let textWidth { text.preferredMaxLayoutWidth = textWidth }
        texts += [numberLabel, sign, text].map(\.stringValue)
        for view in [numberLabel, sign, text] { half.addSubview(view) }
        // A side with no line is quiet, so the eye finds where the other side grew.
        fill(half, line == nil ? Theme.hover : DiffTableView.tintColor(changed))
        let snug = half.bottomAnchor.constraint(equalTo: text.bottomAnchor, constant: 2)
        snug.priority = .defaultLow
        NSLayoutConstraint.activate([
            numberLabel.leadingAnchor.constraint(equalTo: half.leadingAnchor, constant: s(4)),
            numberLabel.widthAnchor.constraint(equalToConstant: numberWidth),
            sign.leadingAnchor.constraint(equalTo: numberLabel.trailingAnchor, constant: s(6)),
            sign.widthAnchor.constraint(equalToConstant: s(9)),
            text.leadingAnchor.constraint(equalTo: sign.trailingAnchor, constant: s(3)),
            text.trailingAnchor.constraint(equalTo: half.trailingAnchor, constant: -Self.trailingInset),
            text.topAnchor.constraint(equalTo: half.topAnchor, constant: 1),
            half.bottomAnchor.constraint(greaterThanOrEqualTo: text.bottomAnchor, constant: 2),
            snug,
            numberLabel.topAnchor.constraint(equalTo: text.topAnchor),
            sign.topAnchor.constraint(equalTo: text.topAnchor),
        ])
        return half
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { !fills.isEmpty }

    override func updateLayer() { applyFills() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFills()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyFills()
    }

    private func applyFills() {
        withAppearance { for (view, color) in fills { view.layer?.backgroundColor = color.cgColor } }
    }
}
