import AppKit
import ClothoKit

// A pane in a git work tree (clothod's `git`) gets a thin strip at its bottom: "repo · branch · worktree",
// then its pull request, "PR #42 open", which opens in the browser. The strip's height is kept for every
// pane in a repo, so moving focus never resizes a shell; only the focused pane fills it in. Outside a repo,
// or against a daemon without `git`, there's no strip at all.

final class GitStrip: NSView {
    static var height: CGFloat { s(20) }

    let icon = NSImageView()
    let summary = NSTextField(labelWithString: "")
    let pullRequest = NSButton()
    private(set) var url: URL?

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
        for view in [icon, summary, pullRequest] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: s(10)),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            summary.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: s(5)),
            summary.centerYAnchor.constraint(equalTo: centerYAnchor),
            pullRequest.leadingAnchor.constraint(equalTo: summary.trailingAnchor, constant: s(10)),
            pullRequest.centerYAnchor.constraint(equalTo: centerYAnchor),
            pullRequest.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -s(10)),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

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
        super.layout()
        needsDisplay = true
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

    @objc private func openPullRequest() {
        guard let url else { return }
        open(url)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
        if !pullRequest.isHidden, url != nil { addCursorRect(pullRequest.frame, cursor: .pointingHand) }
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
            let strip = GitStrip()
            addSubview(strip)
            gitStrip = strip
            return strip
        }()
        strip.show(git)
        strip.isHidden = !isFocusedPane
        needsLayout = true
    }

    /// Room the strip takes at the bottom.
    var gitStripHeight: CGFloat { git == nil ? 0 : GitStrip.height }
}
