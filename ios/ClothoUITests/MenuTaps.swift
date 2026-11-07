import XCTest

extension XCUIElement {
    /// Taps a menu item once its menu has finished opening. Since iOS 27 a tap on an item that is still
    /// animating in is lost, so this waits for the item to exist and for the screen under it to hold still
    /// (two matching screenshots of its frame, at least 0.2 s apart), capped at 3 s.
    ///
    /// It watches pixels because nothing in the accessibility tree moves: an item's `frame` reports its final
    /// place from the first sample, while the menu may still be opening. And it never asks `isHittable`. A
    /// menu item can be scrolled out of view inside its menu (on iPhone with the keyboard up, the Pane actions
    /// menu's Close items always are). For those `isHittable` stays false, or XCTest records "Activation point
    /// invalid" and fails the test. `tap()` scrolls such an item into view itself.
    func tapWhenSettled(timeout: TimeInterval = 5) {
        guard waitForExistence(timeout: timeout) else { return tap() }  // tap() fails the test with the usual message
        var last = pixelsUnder()
        let deadline = Date().addingTimeInterval(3)
        repeat {
            Thread.sleep(forTimeInterval: 0.2)
            let now = pixelsUnder()
            if now == last { break }
            last = now
        } while Date() < deadline
        tap()
    }

    /// A screenshot of the item's frame, or empty when the frame isn't wholly inside the app's window (there is
    /// nothing on screen to watch, and `tap()` scrolls it in).
    private func pixelsUnder() -> Data {
        let rect = frame
        guard !rect.isEmpty, XCUIApplication().windows.firstMatch.frame.contains(rect) else { return Data() }
        return screenshot().pngRepresentation
    }
}

extension XCUIApplication {
    /// Shows one of the iPhone's tabs (Agents, Machines, Settings).
    func showTab(_ name: String) {
        let tab = tabBars.buttons[name]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "no \(name) tab")
        tab.tap()
    }
}
