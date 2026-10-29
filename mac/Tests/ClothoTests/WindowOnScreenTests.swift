import AppKit
import XCTest
@testable import Clotho

/// The borderless main window keeps itself on a screen: after a display is unplugged or added, its top
/// (tab bar, window buttons, drag strip) is never left under the menu bar or off every screen.
@MainActor
final class WindowOnScreenTests: XCTestCase {
    /// A 1512×982 laptop screen with a 33 pt menu bar, and a 2560×1440 display to its right.
    private let laptop = FramelessWindow.ScreenArea(frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
                                                    visible: NSRect(x: 0, y: 0, width: 1512, height: 949))
    private let external = FramelessWindow.ScreenArea(frame: NSRect(x: 1512, y: 0, width: 2560, height: 1440),
                                                      visible: NSRect(x: 1512, y: 0, width: 2560, height: 1415))

    override func setUp() { _ = NSApplication.shared }

    private func window(_ frame: NSRect, screens: [FramelessWindow.ScreenArea]) -> FramelessWindow {
        let window = FramelessWindow(contentRect: frame, styleMask: [.borderless, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.screenAreas = { screens }
        window.mouseIsDown = { false }
        window.setFrame(frame, display: false)
        return window
    }

    /// The reported bug: the external display goes, and the window is left with its top under the laptop's
    /// menu bar. A screen change brings the top back down, keeping the size.
    func testAScreenChangeBringsTheTopBelowTheMenuBar() {
        let stuck = NSRect(x: 100, y: 200, width: 1200, height: 760)  // top at 960, above 949
        let window = window(stuck, screens: [laptop])
        window.startKeepingOnScreen()
        XCTAssertEqual(window.frame.maxY, 949, "at launch too")
        window.setFrame(stuck, display: false)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        XCTAssertEqual(window.frame.maxY, 949, "the top edge is just below the menu bar")
        XCTAssertEqual(window.frame.size, stuck.size, "the size is kept when it fits")
        XCTAssertEqual(window.frame.minX, 100)
        window.close()
    }

    /// While a button is down (a drag), it waits, then fits once the button is up.
    func testWaitsWhileTheMouseIsDown() {
        let stuck = NSRect(x: 100, y: 200, width: 1200, height: 760)
        let window = window(stuck, screens: [laptop])
        var down = true
        window.mouseIsDown = { down }
        window.keepOnScreen()
        XCTAssertEqual(window.frame, stuck, "not during a drag")
        down = false
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        XCTAssertEqual(window.frame.maxY, 949, "once the button is up")
        window.close()
    }

    func testTooTallShrinksToFit() {
        let fitted = FramelessWindow.fitted(NSRect(x: 0, y: -100, width: 1400, height: 1300), to: [laptop])
        XCTAssertEqual(fitted, NSRect(x: 0, y: 0, width: 1400, height: 949))
    }

    /// A window left on the display that went away comes to the middle of the main screen.
    func testMostlyOffEveryScreenMovesToTheMainOne() {
        let fitted = FramelessWindow.fitted(NSRect(x: 2000, y: 300, width: 1600, height: 900), to: [laptop])
        XCTAssertEqual(fitted.size, NSSize(width: 1512, height: 900))
        XCTAssertTrue(laptop.visible.contains(fitted))
        XCTAssertEqual(fitted.midY, laptop.visible.midY, accuracy: 1)
    }

    /// On the larger display it stays there, untouched when already within it.
    func testAWindowWithinAScreenIsLeftAlone() {
        let frame = NSRect(x: 1700, y: 200, width: 1600, height: 1000)
        XCTAssertEqual(FramelessWindow.fitted(frame, to: [laptop, external]), frame)
        let above = NSRect(x: 1700, y: 600, width: 1600, height: 1000)  // top at 1600, above 1415
        let fitted = FramelessWindow.fitted(above, to: [laptop, external])
        XCTAssertEqual(fitted.maxY, 1415)
        XCTAssertEqual(fitted.minX, 1700, "it stays on the display it's on")
    }

    /// Zoom always gets an off-screen window back first, then fills the visible area and toggles back.
    func testZoomIsAnEscapeHatch() {
        let stuck = NSRect(x: 100, y: 200, width: 1200, height: 760)
        let window = window(stuck, screens: [laptop])
        window.toggleZoom()
        XCTAssertEqual(window.frame.maxY, 949, "first back below the menu bar")
        let before = window.frame
        window.toggleZoom()
        XCTAssertEqual(window.frame, laptop.visible)
        window.toggleZoom()
        XCTAssertEqual(window.frame, before, "and back")
        window.close()
    }

    /// Clotho's own full screen isn't fought: a screen change asks it to fill its screen again instead.
    func testFullScreenIsLeftToItsOwnHandler() {
        let window = window(laptop.frame, screens: [laptop])
        window.fillsScreen = true
        var refilled = 0
        window.onScreensChangedWhileFilling = { refilled += 1 }
        window.keepOnScreen()
        XCTAssertEqual(window.frame, laptop.frame, "covers the menu bar, as full screen does")
        XCTAssertEqual(refilled, 1)
        window.close()
    }
}
