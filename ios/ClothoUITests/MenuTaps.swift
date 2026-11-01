import XCTest

extension XCUIElement {
    /// Taps a menu item once its menu has finished opening. Since iOS 27 a tap on an item that is still
    /// animating in is lost, so this waits for the item to exist and its frame to hold still first.
    func tapWhenSettled(timeout: TimeInterval = 5) {
        guard waitForExistence(timeout: timeout) else { return tap() }  // tap() fails the test with the usual message
        var last = frame
        let deadline = Date().addingTimeInterval(3)
        repeat {
            Thread.sleep(forTimeInterval: 0.15)
            let now = frame
            if now == last && isHittable { break }
            last = now
        } while Date() < deadline
        tap()
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
