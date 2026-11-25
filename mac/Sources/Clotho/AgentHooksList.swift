import AppKit
import ClothoKit

// A machine's agents and their status hooks, one row each: the kind's symbol and name, whether its hooks
// are installed, and its own Install (or Update) and Remove. The same list is in Settings > Machines and
// in the "Agent Status…" sheet. The rows are whatever `clothod hooks status` printed, in its order: four
// agents on clothod 0.1.33 (Claude Code, Codex, Gemini CLI, GitHub Copilot CLI), two on an older one, and
// any a later one adds. Every button leads to a confirmation that shows what will change
// (AgentHooks.swift); nothing happens on the first click alone.

/// One agent's row.
final class AgentHookRow: NSView {
    let agent: String
    let icon = NSImageView()
    let titleLabel: NSTextField
    let captionLabel: NSTextField
    /// Under the caption: what the user should know before installing (the Copilot note).
    private(set) var noteLabel: NSTextField?
    /// Install or Update; nil while the status isn't known.
    private(set) var installButton: ClosureButton?
    private(set) var removeButton: ClosureButton?
    let spinner = NSProgressIndicator()

    /// The words under the Copilot row: its hook format has not met a running Copilot CLI yet.
    static let copilotNote = "The GitHub Copilot CLI hook format was checked against GitHub\u{2019}s documentation, not yet against a running Copilot CLI."
    static let checking = "Checking\u{2026}"
    static let unanswered = "clothod on this machine couldn\u{2019}t say"
    /// The room a row's words may take before they wrap, beside the icon and two buttons.
    static let textWidth: CGFloat = 300

    /// `showsNote`: the Copilot note under its row (the sheet). Settings leaves it to the tooltip and to the
    /// Install confirmation, which always says it.
    /// `unknown`: what the caption says while there is no line ("Checking…", or that clothod couldn't say).
    init(agent: String, line: HookLine?, unknown: String = AgentHookRow.checking, busy: Bool, showsNote: Bool = true,
         onInstall: @escaping () -> Void, onRemove: @escaping () -> Void) {
        self.agent = agent
        let kind = AgentKind.of(agent)
        titleLabel = NSTextField(labelWithString: kind.name)
        captionLabel = SettingsStyle.caption(line?.caption ?? unknown)
        super.init(frame: .zero)

        // The symbol is one of the table's literals, chosen by a known kind; never made from the name.
        icon.image = (NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: AgentKind.genericSymbol, accessibilityDescription: nil))?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        icon.contentTintColor = .secondaryLabelColor
        icon.setAccessibilityElement(false)
        icon.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = SettingsStyle.titleFont
        titleLabel.lineBreakMode = .byTruncatingTail
        var texts: [NSView] = [titleLabel, captionLabel]
        if agent == "copilot" { toolTip = Self.copilotNote }
        if agent == "copilot", showsNote {
            let note = SettingsStyle.caption(Self.copilotNote)
            note.preferredMaxLayoutWidth = Self.textWidth
            noteLabel = note
            texts.append(note)
        }
        let text = NSStackView(views: texts)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false

        var controls: [NSView] = []
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel("Working on \(kind.name)")
        if busy { spinner.startAnimation(nil) }
        controls.append(spinner)
        if let line {
            let verb = line.state == .outdated ? "Update" : "Install"
            if line.state != .installed {
                let button = ClosureButton(title: verb, action: onInstall)
                button.setAccessibilityLabel("\(verb) status hooks for \(kind.name)")
                installButton = button
                controls.append(button)
            }
            if line.state != .notInstalled {
                let button = ClosureButton(title: "Remove", action: onRemove)
                button.setAccessibilityLabel("Remove status hooks for \(kind.name)")
                removeButton = button
                controls.append(button)
            }
        }
        for button in [installButton, removeButton].compactMap({ $0 }) {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.isEnabled = !busy
        }
        let buttons = NSStackView(views: controls)
        buttons.orientation = .horizontal
        buttons.spacing = 6
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.setContentCompressionResistancePriority(.required, for: .horizontal)
        buttons.setContentHuggingPriority(.required, for: .horizontal)

        for view in [icon, text, buttons] as [NSView] { addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: SettingsStyle.rowHeight),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
            text.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -12),
        ])
        // The row reads as one group: "Gemini CLI, Not installed", then its buttons.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel([kind.name, captionLabel.stringValue, noteLabel?.stringValue].compactMap { $0 }.joined(separator: ", "))
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// The list. It follows the app's `agentHooks` on its own (a status that arrives, a command that runs),
/// so whatever holds it never has to rebuild for it.
final class AgentHooksListView: NSView {
    private weak var app: AppDelegate?
    let key: MachineKey
    private(set) var rows: [AgentHookRow] = []
    private var group: NSView?
    private var observer: NSObjectProtocol?

    private let showsNotes: Bool

    init(app: AppDelegate, key: MachineKey, showsNotes: Bool = true) {
        self.app = app
        self.key = key
        self.showsNotes = showsNotes
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        observer = NotificationCenter.default.addObserver(forName: AgentHooksState.changed, object: nil, queue: nil) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, note.object as? MachineKey == self.key else { return }
                self.rebuild()
            }
        }
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func rebuild() {
        guard let app else { return }
        group?.removeFromSuperview()
        rows = app.hookRows(key).map { agent, line in
            AgentHookRow(agent: agent, line: line, unknown: app.agentHooks.unanswered.contains(key) ? AgentHookRow.unanswered : AgentHookRow.checking, busy: app.agentHooks.busy.contains("\(key)/\(agent)"), showsNote: showsNotes,
                         onInstall: { [weak self] in self?.act(agent, install: true) },
                         onRemove: { [weak self] in self?.act(agent, install: false) })
        }
        let group = FormGroup(rows)
        group.translatesAutoresizingMaskIntoConstraints = false
        addSubview(group)
        NSLayoutConstraint.activate([
            group.topAnchor.constraint(equalTo: topAnchor),
            group.bottomAnchor.constraint(equalTo: bottomAnchor),
            group.leadingAnchor.constraint(equalTo: leadingAnchor),
            group.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        self.group = group
    }

    /// A button: the confirmation is a sheet on the window the list is in.
    private func act(_ agent: String, install: Bool) {
        guard let app, let window else { return }
        if install { app.installHooks(agent: agent, on: key, in: window) } else { app.removeHooks(agent: agent, on: key, in: window) }
    }
}

/// The "Agent Status…" sheet: what hooks are, the machine's list, and Done (Return or Esc).
final class AgentHooksSheet: NSWindow {
    let list: AgentHooksListView
    let heading: NSTextField
    let intro: NSTextField
    let doneButton: NSButton

    static let intro = "Status hooks let an agent tell Clotho exactly when it starts, waits for you, finishes or fails. "
        + "Each agent has its own, in its own settings. Clotho shows every change before making it, and an agent picks its hooks up the next time it starts."

    init(app: AppDelegate, key: MachineKey, machineName: String) {
        list = AgentHooksListView(app: app, key: key)
        heading = SettingsStyle.heading("Agent status on \(machineName)")
        intro = SettingsStyle.caption(Self.intro)
        doneButton = NSButton(title: "Done", target: nil, action: nil)
        let width = SettingsStyle.width - 2 * SettingsStyle.margin
        super.init(contentRect: NSRect(x: 0, y: 0, width: width + 2 * SettingsStyle.margin, height: 320),
                   styleMask: [.titled], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        title = "Agent status on \(machineName)"
        intro.preferredMaxLayoutWidth = width
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.target = self
        doneButton.action = #selector(done)

        let footer = NSStackView(views: [NSView(), doneButton])
        footer.orientation = .horizontal
        let stack = NSStackView(views: [heading, intro, list, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(14, after: intro)
        stack.setCustomSpacing(16, after: list)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: SettingsStyle.margin),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -SettingsStyle.margin),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: SettingsStyle.margin),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -SettingsStyle.margin),
            stack.widthAnchor.constraint(equalToConstant: width),
            list.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        contentView = content
        // Return is Done.
        defaultButtonCell = doneButton.cell as? NSButtonCell
        initialFirstResponder = doneButton
        content.layoutSubtreeIfNeeded()
        setContentSize(content.fittingSize)
    }

    @objc private func done() {
        // Not while one of its own confirmations is up.
        guard attachedSheet == nil else { return }
        if let sheetParent { sheetParent.endSheet(self) } else { close() }
    }

    /// Esc closes it, as Done does.
    override func cancelOperation(_ sender: Any?) { done() }
}
