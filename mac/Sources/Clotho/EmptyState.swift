import AppKit

// What the window shows where panes go when there are none: a workspace without tabs ("New Tab"), or a
// machine without workspaces ("New Workspace"). Centred: a quiet icon, the name, one line, and the action
// as a prominent button with its shortcut beside it.

final class EmptyStateView: NSView {
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let line = NSTextField(labelWithString: "")
    let button = NSButton(title: "", target: nil, action: nil)
    let shortcut = NSTextField(labelWithString: "")
    private var onAction: (() -> Void)?
    private var buttonWidth: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.contentTintColor = Theme.faintText
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = Theme.foreground
        title.alignment = .center
        title.lineBreakMode = .byTruncatingTail
        line.font = .systemFont(ofSize: 13)
        line.textColor = Theme.dimText
        line.alignment = .center
        // An accent pill, prominent whether or not the window is key (a system accent button greys out).
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        buttonWidth = button.widthAnchor.constraint(equalToConstant: 100)
        buttonWidth.isActive = true
        button.target = self
        button.action = #selector(tapped)
        shortcut.font = .systemFont(ofSize: 12, weight: .medium)
        shortcut.textColor = Theme.dimText

        let action = NSStackView(views: [button, shortcut])
        action.orientation = .horizontal
        action.spacing = 10
        let stack = NSStackView(views: [icon, title, line, action])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(14, after: icon)
        stack.setCustomSpacing(20, after: line)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            // A little above the middle, where the eye lands.
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -24),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Fills it in; `symbol` is an SF Symbol name.
    func show(symbol: String, title: String, line: String, action: String, shortcut: String, then onAction: @escaping () -> Void) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 34, weight: .light))
        self.title.stringValue = title
        self.line.stringValue = line
        button.attributedTitle = NSAttributedString(string: action, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        buttonWidth.constant = ceil(button.attributedTitle.size().width) + 36
        updateColors()
        button.setAccessibilityLabel("\(action) (\(shortcut))")
        self.shortcut.stringValue = shortcut
        self.onAction = onAction
        isHidden = false
    }

    @objc private func tapped() { onAction?() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        withAppearance { button.layer?.backgroundColor = Theme.accent.cgColor }
    }
}
