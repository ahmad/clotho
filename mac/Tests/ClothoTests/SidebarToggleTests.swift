import AppKit
import XCTest
@testable import Clotho

/// The sidebar's show/hide button in the title row: at the sidebar's right edge when it's shown, right
/// after the window buttons when it's hidden (where the tabs make room for it), in line with the buttons,
/// and it toggles.
@MainActor
final class SidebarToggleTests: XCTestCase {
    func testTheToggleStaysVisibleAndInLineEitherWay() throws {
        _ = NSApplication.shared
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        let corner = WindowButtons(target: self, close: #selector(NSObject.description), minimize: #selector(NSObject.description),
                                   fullScreen: #selector(NSObject.description))
        let sidebar = NSView()
        var toggled = 0
        let toggle = AppDelegate.makeSidebarToggle { toggled += 1 }
        for view in [sidebar, corner] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        container.addSubview(toggle)
        let width = sidebar.widthAnchor.constraint(equalToConstant: 240)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: container.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            width,
            corner.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            corner.topAnchor.constraint(equalTo: container.topAnchor),
            corner.widthAnchor.constraint(equalToConstant: WindowButtons.width),
            corner.heightAnchor.constraint(equalToConstant: TabBarView.height),
        ] + AppDelegate.sidebarToggleConstraints(toggle, corner: corner, sidebar: sidebar))

        // Shown: at the sidebar's right edge, clear of the window buttons, centred on their row.
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(toggle.frame.maxX, 240 - s(8), accuracy: 0.5)
        XCTAssertGreaterThan(toggle.frame.minX, corner.frame.maxX)
        XCTAssertEqual(toggle.frame.midY, corner.frame.midY, accuracy: 0.5)
        XCTAssertFalse(toggle.isHidden)
        XCTAssertEqual(toggle.toolTip, "Show/Hide Sidebar (⌘/)")

        // Hidden: still there, right after the window buttons, and left of where the tabs now start.
        width.constant = 0
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(toggle.frame.minX, corner.frame.maxX + s(4), accuracy: 0.5)
        XCTAssertLessThanOrEqual(toggle.frame.maxX, AppDelegate.hiddenTabBarInset - s(4), "the tabs make room for it")
        XCTAssertEqual(toggle.frame.midY, corner.frame.midY, accuracy: 0.5)
        XCTAssertGreaterThan(toggle.frame.width, 0)

        toggle.performClick(nil)
        XCTAssertEqual(toggled, 1, "it toggles")
    }

    /// Settings › General › Show Agents in the sidebar, and View ▸ Show Agents Panel: off removes the
    /// panel and its divider, and the workspaces take the full height; it's saved.
    func testAgentsPanelCanBeHidden() throws {
        _ = NSApplication.shared
        let saved = UserDefaults.standard.object(forKey: AppDelegate.showAgentsPanelKey)
        defer { UserDefaults.standard.set(saved, forKey: AppDelegate.showAgentsPanelKey) }
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 240, height: 700))
        sidebar.layoutSubtreeIfNeeded()
        XCTAssertTrue(sidebar.agentsViews.allSatisfy { !$0.isHidden }, "on by default")
        let footerTop = sidebar.footer.frame.maxY
        XCTAssertGreaterThan(sidebar.workspacesScroll.frame.minY, footerTop + 80, "the Agents panel sits between")

        sidebar.showsAgents = false
        sidebar.layoutSubtreeIfNeeded()
        XCTAssertTrue(sidebar.agentsViews.allSatisfy(\.isHidden))
        XCTAssertEqual(sidebar.workspacesScroll.frame.minY, footerTop, accuracy: 0.5, "the workspaces reach the footer")

        sidebar.showsAgents = true
        sidebar.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(sidebar.workspacesScroll.frame.minY, footerTop + 80, "and back")

        // The app's setting: saved, and the View menu's checkmark follows it.
        let app = AppDelegate()
        NSApp.mainMenu = AppDelegate.makeMainMenu()
        app.setShowsAgentsPanel(false)
        XCTAssertFalse(app.showsAgentsPanel)
        XCTAssertEqual(UserDefaults.standard.object(forKey: AppDelegate.showAgentsPanelKey) as? Bool, false)
        let item = try XCTUnwrap(NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first { $0.title == "Show Agents Panel" })
        XCTAssertEqual(item.state, .off)
        app.toggleAgentsPanel(nil)
        XCTAssertTrue(app.showsAgentsPanel)
        XCTAssertEqual(item.state, .on)
    }
}
