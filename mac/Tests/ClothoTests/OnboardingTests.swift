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
