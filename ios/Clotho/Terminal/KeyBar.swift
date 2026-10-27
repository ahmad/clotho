import SwiftTerm
import UIKit

/// The row above the software keyboard: esc, a sticky ctrl, tab, arrows, | ~ / -, a newline and paste. Keys go through
/// the terminal's own send path, so they reach the pane like typed keys and respect cursor-key mode.
final class KeyBar: UIInputView {
    static let height: CGFloat = 44
    /// Keys in dark, and the Mac's light hover grey (#E1E3E1) with the light terminal's text in light.
    static let keyBackground = UIColor { $0.userInterfaceStyle == .light ? UIColor(hex: 0xE1E3E1) : UIColor(white: 0.32, alpha: 1) }
    static let keyForeground = UIColor { $0.userInterfaceStyle == .light ? UIColor(hex: 0x2B3035) : .white }

    weak var terminal: TerminalView? {
        didSet { observeControlReset() }
    }

    private let stack = UIStackView()
    private var ctrlButton: UIButton!
    private var resetObserver: NSObjectProtocol?

    private enum Key {
        case esc, ctrl, tab, up, down, left, right, text(String), newline, paste, hideKeyboard
    }

    override init(frame: CGRect, inputViewStyle: UIInputView.Style) {
        super.init(frame: frame, inputViewStyle: inputViewStyle)
        setup()
    }

    convenience init(frame: CGRect) {
        self.init(frame: frame, inputViewStyle: .keyboard)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let resetObserver { NotificationCenter.default.removeObserver(resetObserver) }
    }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: Self.height) }

    private func setup() {
        autoresizingMask = [.flexibleWidth]
        allowsSelfSizing = true
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        stack.axis = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -5),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -10),
        ])

        let keys: [(String, Key)] = [
            ("esc", .esc), ("ctrl", .ctrl), ("tab", .tab),
            ("arrow.left", .left), ("arrow.down", .down), ("arrow.up", .up), ("arrow.right", .right),
            ("|", .text("|")), ("~", .text("~")), ("/", .text("/")), ("-", .text("-")),
            ("return", .newline), ("doc.on.clipboard", .paste), ("keyboard.chevron.compact.down", .hideKeyboard),
        ]
        for (label, key) in keys {
            let button = makeButton(label, key)
            if case .ctrl = key { ctrlButton = button }
            stack.addArrangedSubview(button)
        }
    }

    private func makeButton(_ label: String, _ key: Key) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = Self.keyBackground
        config.baseForegroundColor = Self.keyForeground
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
        let isSymbol = label.contains(".") && UIImage(systemName: label) != nil
        if isSymbol {
            config.image = UIImage(systemName: label, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        } else {
            var title = AttributedString(label)
            title.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
            config.attributedTitle = title
        }
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.press(key) })
        button.isPointerInteractionEnabled = true
        button.accessibilityLabel = switch key {
        case .newline: "Newline"
        case .paste: "Paste"
        default: label
        }
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        return button
    }

    private func press(_ key: Key) {
        guard let terminal else { return }
        UIDevice.current.playInputClick()
        switch key {
        case .esc: terminal.send([0x1b])
        case .tab: terminal.send([0x09])
        case .up: terminal.sendKeyUp()
        case .down: terminal.sendKeyDown()
        case .left: terminal.sendKeyLeft()
        case .right: terminal.sendKeyRight()
        case .text(let text): terminal.send(txt: text)
        case .ctrl:
            // Sticky: applies to the next key typed on the software keyboard, then resets itself.
            terminal.controlModifier.toggle()
            updateCtrl()
        case .newline:
            // A newline in an agent's prompt, as Shift-Return sends it; Return submits.
            terminal.send(EditingKeys.newline(kitty: (terminal as? PaneTerminalView)?.kittyKeyboard ?? false))
        case .paste:
            terminal.paste(nil)
        case .hideKeyboard:
            _ = terminal.resignFirstResponder()
        }
    }

    private func updateCtrl() {
        let on = terminal?.controlModifier ?? false
        ctrlButton.configuration?.baseBackgroundColor = on ? Theme.accent : Self.keyBackground
        ctrlButton.configuration?.baseForegroundColor = on ? .white : Self.keyForeground
    }

    private func observeControlReset() {
        if let resetObserver { NotificationCenter.default.removeObserver(resetObserver) }
        resetObserver = NotificationCenter.default.addObserver(forName: .terminalViewControlModifierReset, object: terminal,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCtrl() }
        }
    }
}

extension KeyBar: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}
