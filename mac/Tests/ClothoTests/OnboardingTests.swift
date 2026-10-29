import AppKit
@testable import Clotho
import XCTest

final class SSHDiagnosisTests: XCTestCase {
    func testAuthWithAndWithoutKeys() {
        let denied = "macbook@imac: Permission denied (publickey,password,keyboard-interactive)."
        XCTAssertEqual(SSHDiagnosis.classify(denied, hasKeys: true), .authRejected)
        XCTAssertEqual(SSHDiagnosis.classify(denied, hasKeys: false), .noKey)
    }

    func testHostKeys() {
        XCTAssertEqual(SSHDiagnosis.classify("Host key verification failed.", hasKeys: true), .hostKeyUnknown)
        let changed = """
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        Host key verification failed.
        """
        XCTAssertEqual(SSHDiagnosis.classify(changed, hasKeys: true), .hostKeyChanged)
    }

    func testNetwork() {
        XCTAssertEqual(SSHDiagnosis.classify("ssh: Could not resolve hostname nowhere: nodename nor servname provided, or not known", hasKeys: true), .unknownHost)
        XCTAssertEqual(SSHDiagnosis.classify("ssh: connect to host 10.0.0.9 port 22: Connection refused", hasKeys: true), .refused)
        XCTAssertEqual(SSHDiagnosis.classify("ssh: connect to host 10.0.0.9 port 22: Operation timed out", hasKeys: true), .timedOut)
        XCTAssertEqual(SSHDiagnosis.classify("ssh: connect to host 10.0.0.9 port 22: No route to host", hasKeys: true), .timedOut)
    }

    func testOtherKeepsLastLine() {
        XCTAssertEqual(SSHDiagnosis.classify("debug\nkex_exchange_identification: read: Connection reset by peer\n", hasKeys: true),
                       .other("kex_exchange_identification: read: Connection reset by peer"))
        XCTAssertEqual(SSHDiagnosis.classify("", hasKeys: true), .other("ssh failed without saying why."))
    }

    func testAdviceNamesTheTarget() {
        XCTAssertTrue(SSHDiagnosis.authRejected.advice(target: "me@box").contains("ssh-copy-id me@box"))
        XCTAssertTrue(SSHDiagnosis.hostKeyChanged.advice(target: "me@box").contains("ssh-keygen -R box"))
        XCTAssertTrue(SSHDiagnosis.noKey.advice(target: "me@box").contains("ssh-keygen -t ed25519"))
    }

    func testFirstRun() {
        let suite = "clotho-onboarding-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(OnboardingController.isFirstRun(defaults))
        defaults.set("local", forKey: "FocusedMachine")
        XCTAssertFalse(OnboardingController.isFirstRun(defaults))
        defaults.removeObject(forKey: "FocusedMachine")
        defaults.set([["id": "x", "label": "iMac", "target": "a@b"]], forKey: "Machines")
        XCTAssertFalse(OnboardingController.isFirstRun(defaults))
        defaults.removeObject(forKey: "Machines")
        defaults.set(true, forKey: OnboardingController.doneKey)
        XCTAssertFalse(OnboardingController.isFirstRun(defaults))
    }
}

/// The welcome window: one idea per page, and ← / → move between pages unless a field has text to move
/// through.
@MainActor
final class OnboardingWindowTests: XCTestCase {
    private var controller: OnboardingController!

    override func setUp() {
        _ = NSApplication.shared
        controller = OnboardingController(app: nil)
    }

    override func tearDown() {
        controller.window?.delegate = nil
        controller.window?.orderOut(nil)
        controller = nil
    }

    private func arrow(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        let window = controller.window!
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                                     context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        return controller.handleArrow(event)
    }

    private let left: UInt16 = 123, right: UInt16 = 124

    func testArrowsMoveBetweenPages() {
        XCTAssertEqual(controller.step, .welcome)
        XCTAssertTrue(arrow(left), "taken on the first page, but goes nowhere")
        XCTAssertEqual(controller.step, .welcome)
        XCTAssertTrue(arrow(right))
        XCTAssertEqual(controller.step, .thisMac)
        XCTAssertTrue(arrow(right))
        XCTAssertEqual(controller.step, .remote)
        XCTAssertTrue(arrow(left))
        XCTAssertEqual(controller.step, .thisMac)
        XCTAssertFalse(arrow(right, modifiers: .command), "⌘→ isn't ours")
        XCTAssertEqual(controller.step, .thisMac)
        controller.show(.done)
        XCTAssertTrue(arrow(right), "the last page stays; Return finishes")
        XCTAssertEqual(controller.step, .done)
        XCTAssertFalse(arrow(36), "other keys pass")
    }

    /// In the SSH target field, arrows move the cursor once there's text; an empty field lets them through.
    func testArrowsLeaveTextFieldsAlone() throws {
        controller.show(.remote)
        let window = try XCTUnwrap(controller.window)
        let field = try XCTUnwrap(allViews(window.contentView!).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertTrue(arrow(right), "empty: the page moves")
        XCTAssertEqual(controller.step, .agents)
        controller.show(.remote)
        let again = try XCTUnwrap(allViews(window.contentView!).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        XCTAssertTrue(window.makeFirstResponder(again))
        (window.firstResponder as? NSTextView)?.insertText("me@box", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(arrow(left), "the field gets it")
        XCTAssertEqual(controller.step, .remote)
    }

    /// The user's ask: less text. Every page stays a glance: a title, a line and its controls.
    func testPagesAreShort() {
        for step in OnboardingController.Step.allCases {
            controller.show(step)
            let words = allViews(controller.window!.contentView!).compactMap { $0 as? NSTextField }
                .filter { !$0.isEditable && !$0.isHiddenOrHasHiddenAncestor }
                .flatMap { $0.stringValue.split(whereSeparator: \.isWhitespace) }
            XCTAssertLessThanOrEqual(words.count, 40, "\(step): \(words.joined(separator: " "))")
        }
    }

    private func allViews(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + allViews($0) } }
}
