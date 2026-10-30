import AppKit
import XCTest
@testable import Clotho

final class UIScaleTests: XCTestCase {
    func testClampAndSteps() {
        XCTAssertEqual(UIScale.clamp(1), 1)
        XCTAssertEqual(UIScale.clamp(1.04), 1)
        XCTAssertEqual(UIScale.clamp(1.06), 1.1)
        XCTAssertEqual(UIScale.clamp(0.1), 0.8, "never below 80%")
        XCTAssertEqual(UIScale.clamp(9), 1.6, "never above 160%")
        XCTAssertEqual(UIScale.next(1, steps: 1), 1.1)
        XCTAssertEqual(UIScale.next(1, steps: -2), 0.8)
        XCTAssertEqual(UIScale.next(1.6, steps: 1), 1.6)
        XCTAssertEqual(UIScale.next(0.8, steps: -1), 0.8)
        // Repeated steps don't drift off the 0.1 grid.
        var f: CGFloat = 0.8
        for _ in 0..<8 { f = UIScale.next(f, steps: 1) }
        XCTAssertEqual(f, 1.6)
        for _ in 0..<6 { f = UIScale.next(f, steps: -1) }
        XCTAssertEqual(f, 1.0, accuracy: 0.0001)
    }

    func testPersistence() throws {
        let suite = TestDefaults.name("uiscale")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { TestDefaults.remove(suite) }
        XCTAssertEqual(UIScale.load(defaults), 1, "100% until set")
        UIScale.save(1.3, defaults)
        XCTAssertEqual(UIScale.load(defaults), 1.3, accuracy: 0.0001)
        defaults.set(7.0, forKey: UIScale.defaultsKey)
        XCTAssertEqual(UIScale.load(defaults), 1.6, "an out-of-range saved value is clamped")
    }

    @MainActor
    func testChromeSizesFollowTheFactor() {
        let saved = UIScale.factor
        defer { UIScale.factor = saved }
        UIScale.factor = 1
        XCTAssertEqual(TabBarView.height, 40)
        XCTAssertEqual(SidebarView.rowHeight, 28)
        XCTAssertEqual(s(13), 13)
        UIScale.factor = 1.4
        XCTAssertEqual(TabBarView.height, 56, accuracy: 0.001)
        XCTAssertEqual(SidebarView.rowHeight, 39.2, accuracy: 0.001)
        XCTAssertEqual(MachineHeader.nameInset, 42, accuracy: 0.001)
        UIScale.factor = 0.8
        XCTAssertEqual(DisclosureChevron.size, 11.2, accuracy: 0.001)
    }
}
