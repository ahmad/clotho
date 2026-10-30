import AppKit

// What the window shows where panes go when there are none: a workspace without tabs ("New Tab"), or a
// machine without workspaces ("New Workspace"). Centred: a quiet icon, the name, one line, and the action
// as a prominent accent button with its shortcut inside it: [ New Tab (⌘T) ], the "(⌘T)" dimmer.

final class EmptyStateView: NSView {
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let line = NSTextField(labelWithString: "")
    let button = NSButton(title: "", target: nil, action: nil)
    /// The shortcut shown in the button (tests).
    private(set) var shortcut = ""
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
        let stack = NSStackView(views: [icon, title, line, button])
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
        button.attributedTitle = Self.title(action, shortcut: shortcut)
        buttonWidth.constant = ceil(button.attributedTitle.size().width) + 36
        updateColors()
        button.setAccessibilityLabel("\(action) (\(shortcut))")
        self.shortcut = shortcut
        self.onAction = onAction
        isHidden = false
    }

    /// "New Tab (⌘T)": the label in the button's weight, then a space and the shortcut in parentheses, in
    /// the same text at 60%.
    static func title(_ action: String, shortcut: String) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let title = NSMutableAttributedString(string: action, attributes: [.font: font, .foregroundColor: NSColor.white])
        guard !shortcut.isEmpty else { return title }
        title.append(NSAttributedString(string: " ", attributes: [.font: font]))
        title.append(NSAttributedString(string: "(\(shortcut))", attributes: [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.6)]))
        return title
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
