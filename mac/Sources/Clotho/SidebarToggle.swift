import AppKit

// The sidebar's show/hide button in the title row (sidebar.left, quiet like the sidebar's bottom-bar
// icons). With the sidebar shown it sits at the sidebar's right edge, just left of the first tab; with it
// hidden it stays, right after the window buttons, and the tabs start after it. Two constraints place it:
// a strong one keeps it 8 pt inside the sidebar's trailing edge, and a required one keeps it clear of the
// window buttons, so it slides with the sidebar's animation and stops beside the buttons. It's a button,
// so it takes clicks; the empty title row around it still drags the window.

extension AppDelegate {
    static var sidebarToggleSize: CGFloat { s(26) }

    /// Where the tab bar starts with the sidebar hidden: after the window buttons and the toggle.
    static var hiddenTabBarInset: CGFloat { WindowButtons.width + s(4) + sidebarToggleSize + s(8) }

    static func makeSidebarToggle(action: @escaping () -> Void) -> QuietButton {
        let button = QuietButton(symbol: "sidebar.left", label: "Show/Hide Sidebar", pointSize: s(13), action: action)
        button.toolTip = "Show/Hide Sidebar (⌘/)"
        button.setAccessibilityLabel("Show/Hide Sidebar")
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    /// Places the toggle in the title row: centred on the window buttons' row, at the sidebar's trailing
    /// edge, never over the window buttons.
    static func sidebarToggleConstraints(_ button: NSView, corner: NSView, sidebar: NSView) -> [NSLayoutConstraint] {
        let follow = button.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -s(8))
        follow.priority = .defaultHigh
        return [
            button.widthAnchor.constraint(equalToConstant: sidebarToggleSize),
            button.heightAnchor.constraint(equalToConstant: sidebarToggleSize),
            button.centerYAnchor.constraint(equalTo: corner.centerYAnchor),
            button.leadingAnchor.constraint(greaterThanOrEqualTo: corner.trailingAnchor, constant: s(4)),
            follow,
        ]
    }
}

// The sidebar's Agents panel, on or off (Settings › General › Sidebar, View ▸ Show Agents Panel).
extension AppDelegate {
    static let showAgentsPanelKey = "ShowAgentsPanel"

    /// On unless switched off.
    var showsAgentsPanel: Bool {
        UserDefaults.standard.object(forKey: Self.showAgentsPanelKey) as? Bool ?? true
    }

    func setShowsAgentsPanel(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.showAgentsPanelKey)
        log("sidebar: agents panel \(on ? "shown" : "hidden")")
        applyAgentsPanelSetting()
        settingsWindow?.reload()
    }

    @objc func toggleAgentsPanel(_ sender: Any?) { setShowsAgentsPanel(!showsAgentsPanel) }

    /// The sidebar and the View menu's checkmark follow the setting.
    func applyAgentsPanelSetting() {
        sidebar?.showsAgents = showsAgentsPanel
        let items = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items) ?? []
        items.first { $0.action == #selector(toggleAgentsPanel(_:)) }?.state = showsAgentsPanel ? .on : .off
    }
}
