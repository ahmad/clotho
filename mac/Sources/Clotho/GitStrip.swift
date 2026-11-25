import AppKit
import ClothoKit

// A pane in a git work tree (clothod's `git`) gets a thin strip at its bottom: "repo · branch · worktree",
// then its pull request, "PR #42 open", which opens in the browser. The strip's height is kept for every
// pane in a repo, so moving focus never resizes a shell; only the focused pane fills it in. Outside a repo,
// or against a daemon without `git`, there's no strip at all.
//
// At its trailing edge, how much changed there (the daemon's `git.changes`, clothod 0.1.32): "+128 −32 ·
// 6 files", or only the files when the lines weren't counted. A click opens the inspector on Changes. In
// a narrow pane it drops the files, then goes: it never covers the branch or the pull request.

final class GitStrip: NSView {
    static var height: CGFloat { s(20) }

    let icon = NSImageView()
    let summary = NSTextField(labelWithString: "")
    let pullRequest = NSButton()
    /// The change count at the trailing edge; hidden when nothing changed or nothing is known.
    let changeCount = NSButton()
    /// A click on the count: the inspector opens on Changes.
    var onShowChanges: (() -> Void)?
    private(set) var url: URL?
    /// The work tree's counts, as last shown.
    private var changes: PaneGit.Changes?
    /// How much of the count the strip has room for.
    enum CountForm { case full, linesOnly, hidden }
    private(set) var countForm = CountForm.hidden
    // Which of these hold depends on what shows: a hidden PR or count takes no room and no gap, so the
    // branch is tied to whatever is next at its trailing side.
    private var pullRequestAfterSummary: NSLayoutConstraint!
    private var pullRequestToEdge: NSLayoutConstraint!
    private var pullRequestToCount: NSLayoutConstraint!
    private var summaryToEdge: NSLayoutConstraint!
    private var summaryToCount: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        icon.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Branch")
        icon.symbolConfiguration = .init(pointSize: s(9.5), weight: .medium)
        icon.contentTintColor = Theme.faintText
        summary.font = .systemFont(ofSize: s(11))
        summary.textColor = Theme.secondaryText
        summary.lineBreakMode = .byTruncatingMiddle
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pullRequest.isBordered = false
        pullRequest.bezelStyle = .inline
        pullRequest.target = self
        pullRequest.action = #selector(openPullRequest)
        pullRequest.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        changeCount.isBordered = false
        changeCount.bezelStyle = .inline
        changeCount.target = self
        changeCount.action = #selector(showChanges)
        changeCount.isHidden = true
        changeCount.setContentCompressionResistancePriority(.required, for: .horizontal)
        changeCount.setContentHuggingPriority(.required, for: .horizontal)
        changeCount.setAccessibilityRole(.button)
        for view in [icon, summary, pullRequest, changeCount] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        pullRequestToEdge = pullRequest.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -s(10))
        pullRequestToCount = pullRequest.trailingAnchor.constraint(lessThanOrEqualTo: changeCount.leadingAnchor, constant: -s(10))
        pullRequestAfterSummary = pullRequest.leadingAnchor.constraint(equalTo: summary.trailingAnchor, constant: s(10))
        summaryToEdge = summary.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -s(10))
        summaryToCount = summary.trailingAnchor.constraint(lessThanOrEqualTo: changeCount.leadingAnchor, constant: -s(10))
        pullRequest.isHidden = true
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: s(10)),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            summary.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: s(5)),
            summary.centerYAnchor.constraint(equalTo: centerYAnchor),
            pullRequest.centerYAnchor.constraint(equalTo: centerYAnchor),
            changeCount.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -s(10)),
            changeCount.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        tieTrailingSides()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Ties the branch, the PR and the count together for what shows now. A hidden PR is out of the
    /// layout: left in, its width and gap would come out of the branch's room.
    private func tieTrailingSides() {
        let pr = !pullRequest.isHidden, count = !changeCount.isHidden
        let wanted: [(NSLayoutConstraint, Bool)] = [
            (pullRequestAfterSummary, pr), (pullRequestToEdge, pr && !count), (pullRequestToCount, pr && count),
            (summaryToEdge, !pr && !count), (summaryToCount, !pr && count),
        ]
        NSLayoutConstraint.deactivate(wanted.filter { !$0.1 && $0.0.isActive }.map(\.0))
        NSLayoutConstraint.activate(wanted.filter { $0.1 && !$0.0.isActive }.map(\.0))
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.sidebar.cgColor
            layer?.borderColor = Theme.divider.cgColor
        }
        // Only the top edge: a 1 pt line drawn by a sublayer, so the other edges stay clean.
        topLine.frame = CGRect(x: 0, y: isFlipped ? 0 : bounds.height - 1, width: bounds.width, height: 1)
        effectiveAppearance.performAsCurrentDrawingAppearance { topLine.backgroundColor = Theme.divider.cgColor }
        if topLine.superlayer == nil { layer?.addSublayer(topLine) }
    }

    override func layout() {
        fitChangeCount()
        super.layout()
        needsDisplay = true
    }

    /// The count's text: "+128" in green, "−32" in red, then " · 6 files" dim; only the files when the
    /// lines weren't counted. Nil when nothing changed.
    static func countTitle(_ changes: PaneGit.Changes?, form: CountForm) -> NSAttributedString? {
        guard form != .hidden, let total = changes?.total, total.files > 0 else { return nil }
        let font = NSFont.monospacedDigitSystemFont(ofSize: s(11), weight: .regular)
        let files = ChangeCountText.files(total.files)
        guard let added = total.added, let removed = total.removed else {
            return NSAttributedString(string: files, attributes: [.font: font, .foregroundColor: Theme.secondaryText])
        }
        let title = NSMutableAttributedString(string: "+\(added)", attributes: [.font: font, .foregroundColor: Theme.success])
        title.append(NSAttributedString(string: " \u{2212}\(removed)", attributes: [.font: font, .foregroundColor: Theme.danger]))
        if form == .full {
            title.append(NSAttributedString(string: " · \(files)", attributes: [.font: font, .foregroundColor: Theme.secondaryText]))
        }
        return title
    }

    /// Picks the longest form of the count that leaves the branch some room, and shows it.
    private func fitChangeCount() {
        // What stays for the icon, a few letters of the branch and the gaps, and for the PR with its gap
        // when there is one: the PR resists being squeezed, so the count would otherwise take the branch's room.
        var room = bounds.width - s(10) * 3 - s(14) - s(5) - s(44)
        if !pullRequest.isHidden { room -= ceil(pullRequest.intrinsicContentSize.width) + s(10) }
        var form = CountForm.hidden
        for candidate in [CountForm.full, .linesOnly] {
            guard let title = Self.countTitle(changes, form: candidate) else { break }
            if ceil(title.size().width) + s(4) <= room {
                form = candidate
                break
            }
        }
        let title = Self.countTitle(changes, form: form)
        if form != countForm || title != changeCount.attributedTitle {
            countForm = form
            if let title { changeCount.attributedTitle = title }
        }
        let hidden = form == .hidden
        if changeCount.isHidden != hidden {
            changeCount.isHidden = hidden
            window?.invalidateCursorRects(for: self)
        }
        tieTrailingSides()
    }

    private let topLine = CALayer()

    /// The state's word and colour, as GitHub shows them.
    static func describe(_ state: PaneGit.PullRequest.State?) -> (String, NSColor) {
        switch state {
        case .open: return ("open", .systemGreen)
        case .draft: return ("draft", Theme.dimText)
        case .merged: return ("merged", .systemPurple)
        case .closed: return ("closed", .systemRed)
        case nil: return ("", Theme.dimText)
        }
    }

    func show(_ git: PaneGit) {
        summary.stringValue = git.summary
        toolTip = git.root
        changes = git.changes
        let spoken = ChangeCountText.spoken(git.changes)
        changeCount.toolTip = spoken.map { "\($0). Show changes" }
        changeCount.setAccessibilityLabel(spoken.map { "\($0). Show changes" })
        needsLayout = true
        // The count is fitted last: the room it has depends on the PR.
        defer { fitChangeCount() }
        guard let pr = git.pr else {
            pullRequest.isHidden = true
            url = nil
            return
        }
        let (word, color) = Self.describe(pr.state)
        let title = NSMutableAttributedString(string: "PR #\(pr.number)", attributes: [
            .font: NSFont.systemFont(ofSize: s(11), weight: .medium), .foregroundColor: Theme.accent,
        ])
        if !word.isEmpty {
            title.append(NSAttributedString(string: "  \(word)", attributes: [.font: NSFont.systemFont(ofSize: s(11)), .foregroundColor: color]))
        }
        pullRequest.attributedTitle = title
        pullRequest.toolTip = [pr.title, pr.url].compactMap { $0 }.joined(separator: "\n")
        // Only GitHub pull request pages open (the daemon only sends those).
        url = pr.url.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" && $0.host == "github.com" ? $0 : nil }
        pullRequest.isEnabled = url != nil
        pullRequest.isHidden = false
    }

    /// Where the PR click goes; tests replace it.
    var open: (URL) -> Void = { NSWorkspace.shared.open($0) }

    @objc private func showChanges() { onShowChanges?() }

    @objc private func openPullRequest() {
        guard let url else { return }
        open(url)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
        if !pullRequest.isHidden, url != nil { addCursorRect(pullRequest.frame, cursor: .pointingHand) }
        if !changeCount.isHidden { addCursorRect(changeCount.frame, cursor: .pointingHand) }
    }

    // Clicks on the strip (outside the PR) stay here, not the terminal under the pane.
    override func mouseDown(with event: NSEvent) {}
}

extension PaneHostView {
    /// Shows the strip's text for the focused pane; its room is kept whenever the pane is in a repo.
    func updateGitStrip() {
        guard let git else {
            gitStrip?.removeFromSuperview()
            gitStrip = nil
            return
        }
        let strip = gitStrip ?? {
            // With the frame the host's layout gives it (and room for its insets before the host has a
            // size): a strip made with no frame can't hold them until the next layout pass, which logged
            // "Conflicting constraints detected" for every pane in a repository.
            let strip = GitStrip(frame: Self.gitStripFrame(in: bounds))
            addSubview(strip)
            gitStrip = strip
            return strip
        }()
        strip.onShowChanges = { [weak self] in self?.onShowChanges?() }
        strip.show(git)
        strip.isHidden = !isFocusedPane
        needsLayout = true
    }

    /// Where the strip sits: along the pane's bottom. Before the pane has a size, a strip's width of room.
    static func gitStripFrame(in bounds: NSRect) -> NSRect {
        NSRect(x: 0, y: max(0, bounds.height - GitStrip.height), width: max(bounds.width, s(240)), height: GitStrip.height)
    }

    /// Room the strip takes at the bottom.
    var gitStripHeight: CGFloat { git == nil ? 0 : GitStrip.height }
}
