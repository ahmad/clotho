import AppKit
import ClothoKit

// A pane clothod brought back after a restart (`restored`) shows a quiet note at its top right, over the
// terminal (taking no rows, so the shell's size never changes): "Restored after restart", plus
// "· resumed Claude session" when it resumed one. × dismisses it on the daemon, for every device; the
// daemon also drops it on the first typing in the pane. The find bar takes its place while open.

final class RestoredNote: NSView {
    let label = NSTextField(labelWithString: "")
    let closeButton = NSButton()
    var onDismiss: (() -> Void)?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let background = Tile(fill: Theme.pill.withAlphaComponent(0.94), radius: 6)
        addSubview(background)
        let icon = NSImageView(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 10.5, weight: .medium)
        icon.contentTintColor = Theme.secondaryText
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = Theme.secondaryText
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.contentTintColor = Theme.faintText
        closeButton.target = self
        closeButton.action = #selector(dismissTapped)
        closeButton.setAccessibilityLabel("Dismiss")
        closeButton.toolTip = "Dismiss"
        for view in [icon, label, closeButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 22),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func dismissTapped() { onDismiss?() }

    // Clicks on the note stay on it, not the terminal under it.
    override func mouseDown(with event: NSEvent) {}
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

extension PaneHostView {
    /// Shows, updates or removes the note for `restored`. Hidden while the find bar is open.
    func showRestored(_ restored: PaneRestore?) {
        guard let restored, search == nil else {
            restoredNote?.removeFromSuperview()
            restoredNote = nil
            return
        }
        let note = restoredNote ?? {
            let note = RestoredNote()
            addSubview(note)
            NSLayoutConstraint.activate([
                note.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding + 2),
                note.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(Self.padding + 14)),
                note.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.8),
            ])
            restoredNote = note
            return note
        }()
        note.label.stringValue = restored.note
        let id = paneID
        note.onDismiss = { [weak self] in
            guard let self else { return }
            // Gone at once here; the daemon's pane update clears it everywhere else.
            dismissedRestore = true
            showRestored(nil)
            Task { [backend = store.backend] in
                do { try await backend.dismissRestored(id) } catch { log("dismiss restored pane \(id) failed: \(error)") }
            }
        }
    }
}
