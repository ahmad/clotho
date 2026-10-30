import AppKit

// The pieces Settings is built from, in System Settings' style: a small bold heading over an inset,
// rounded group of rows, each row a label (with an optional one-line caption) on the left and its
// control on the right, with hairline separators between rows.

enum SettingsStyle {
    static let width: CGFloat = 560
    static let margin: CGFloat = 20
    static let rowHeight: CGFloat = 44
    static let titleFont = NSFont.systemFont(ofSize: 13)
    static let captionFont = NSFont.systemFont(ofSize: 11)
    static let headingFont = NSFont.systemFont(ofSize: 13, weight: .semibold)

    /// The groups' fill: a lighter card on the window's grey in light mode, a faint lift in dark.
    static let groupFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.05) : NSColor.white.withAlphaComponent(0.7)
    }
    static let groupBorder = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.08)
    }

    static func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = headingFont
        label.textColor = .labelColor
        return label
    }

    static func caption(_ text: String, color: NSColor = .secondaryLabelColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = captionFont
        label.textColor = color
        label.isSelectable = false
        return label
    }

    static func toggle(on: Bool, label: String, changed: @escaping (Bool) -> Void) -> (NSSwitch, ClosureTarget) {
        let target = ClosureTarget { sender in changed((sender as? NSSwitch)?.state == .on) }
        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.state = on ? .on : .off
        toggle.target = target
        toggle.action = #selector(ClosureTarget.fire(_:))
        toggle.setAccessibilityLabel(label)
        return (toggle, target)
    }
}

/// One row: title and caption on the left, the control on the right, vertically centred.
final class FormRow: NSView {
    let titleLabel: NSTextField
    let captionLabel: NSTextField?
    let control: NSView?

    init(_ title: String, caption: String? = nil, captionColor: NSColor = .secondaryLabelColor, control: NSView?) {
        titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = SettingsStyle.titleFont
        titleLabel.lineBreakMode = .byTruncatingTail
        captionLabel = caption.map { SettingsStyle.caption($0, color: captionColor) }
        self.control = control
        super.init(frame: .zero)
        let text = NSStackView(views: [titleLabel] + (captionLabel.map { [$0] } ?? []))
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        var constraints = [
            heightAnchor.constraint(greaterThanOrEqualToConstant: SettingsStyle.rowHeight),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
        ]
        if let control {
            control.translatesAutoresizingMaskIntoConstraints = false
            addSubview(control)
            constraints += [
                control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                control.centerYAnchor.constraint(equalTo: centerYAnchor),
                text.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -16),
            ]
        } else {
            constraints.append(text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12))
        }
        NSLayoutConstraint.activate(constraints)
        captionLabel?.preferredMaxLayoutWidth = SettingsStyle.width - 2 * SettingsStyle.margin - 220
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// An inset, rounded group of views (usually FormRows) with hairlines between them.
final class FormGroup: NSView {
    let stack = NSStackView()

    init(_ rows: [NSView]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let line = Hairline()
                stack.addArrangedSubview(line)
                line.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 12).isActive = true
                line.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // Dynamic colours resolve for the current appearance here, so light and dark both follow.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = SettingsStyle.groupFill.cgColor
            layer?.borderColor = SettingsStyle.groupBorder.cgColor
        }
    }
}

/// A one-pixel separator in the system's separator colour.
final class Hairline: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
    }
}

/// A heading, its group and an optional footnote, stacked the way System Settings spaces them.
func formSection(_ heading: String?, _ group: NSView, footnote: String? = nil) -> NSStackView {
    var views: [NSView] = []
    if let heading { views.append(SettingsStyle.heading(heading)) }
    views.append(group)
    if let footnote { views.append(SettingsStyle.caption(footnote)) }
    let section = NSStackView(views: views)
    section.orientation = .vertical
    section.alignment = .leading
    section.spacing = 6
    group.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
    if let footnote = views.last as? NSTextField, footnote !== views.first {
        footnote.preferredMaxLayoutWidth = SettingsStyle.width - 2 * SettingsStyle.margin
    }
    return section
}
