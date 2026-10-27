import ClothoKit
@testable import Clotho
import CryptoKit
import NIOCore
import NIOPosix
import XCTest

/// Key import (OpenSSH private keys) and the setup check's error messages.
final class OnboardingTests: XCTestCase {
    /// An OpenSSH private key file as ssh-keygen writes it, built here so no key lives in the repo.
    private func openSSHFile(type: String = "ssh-ed25519", cipher: String = "none", key: Curve25519.Signing.PrivateKey,
                             comment: String = "me@laptop") -> String {
        func string(_ data: Data) -> Data {
            var count = UInt32(data.count).bigEndian
            return Data(bytes: &count, count: 4) + data
        }
        func string(_ text: String) -> Data { string(Data(text.utf8)) }
        let pub = key.publicKey.rawRepresentation
        let publicBlob = string(type) + string(pub)
        var section = Data([1, 2, 3, 4, 1, 2, 3, 4])
        section += string(type) + string(pub) + string(key.rawRepresentation + pub) + string(comment)
        var pad: UInt8 = 1
        while section.count % 8 != 0 { section.append(pad); pad += 1 }
        var blob = Data("openssh-key-v1\0".utf8)
        blob += string(cipher) + string(cipher == "none" ? "none" : "bcrypt") + string(Data())
        blob += Data([0, 0, 0, 1]) + string(publicBlob) + string(section)
        let base64 = blob.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(base64)\n-----END OPENSSH PRIVATE KEY-----\n"
    }

    func testImportsAnEd25519Key() throws {
        let key = Curve25519.Signing.PrivateKey()
        let imported = try KeyImport.parse(openSSHFile(key: key))
        XCTAssertEqual(imported.kind, .ed25519)
        XCTAssertEqual(imported.secret, key.rawRepresentation)
        XCTAssertEqual(imported.name, "me@laptop")
        XCTAssertEqual(try KeyImport.parse("  " + openSSHFile(key: key) + "\n\n", name: "work").name, "work")
        XCTAssertTrue(try imported.openSSHPublicKey().hasPrefix("ssh-ed25519 "))
    }

    func testImportExplainsWhatItCantUse() {
        let key = Curve25519.Signing.PrivateKey()
        func failure(_ text: String) -> KeyImport.Failure? {
            do { _ = try KeyImport.parse(text); return nil } catch { return error as? KeyImport.Failure }
        }
        XCTAssertEqual(failure(""), .empty)
        XCTAssertEqual(failure("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl me"), .publicKey)
        XCTAssertEqual(failure(openSSHFile(cipher: "aes256-ctr", key: key)), .encrypted)
        XCTAssertEqual(failure(openSSHFile(type: "ssh-rsa", key: key)), .unsupported("an RSA key"))
        XCTAssertEqual(failure("-----BEGIN RSA PRIVATE KEY-----\nMIIE\n-----END RSA PRIVATE KEY-----"), .unsupported("an RSA key"))
        XCTAssertEqual(failure("hello"), .notOpenSSH)
        var damaged = openSSHFile(key: key).split(separator: "\n").map(String.init)
        damaged.remove(at: 2)
        XCTAssertEqual(failure(damaged.joined(separator: "\n")), .malformed)
        XCTAssertTrue(KeyImport.Failure.encrypted.localizedDescription.contains("ssh-keygen -p"))
    }

    func testInstallCommandAddsTheKeyOnce() {
        let command = PublicKeyCard.installCommand("ssh-ed25519 AAAA me")
        XCTAssertTrue(command.contains("echo 'ssh-ed25519 AAAA me' >> ~/.ssh/authorized_keys"))
        XCTAssertTrue(command.contains("chmod 600 ~/.ssh/authorized_keys"))
    }

    /// Real failures from NIO, described for a person.
    func testConnectionErrorsAreReadable() async throws {
        var machine = Machine(name: "", host: "127.0.0.1", port: 1, user: "me")
        do {
            _ = try await ConnectionCheck.hostKey(of: machine)
            XCTFail("port 1 answered")
        } catch {
            let text = ConnectionCheck.describe(error, machine: machine)
            XCTAssertTrue(text.contains("refused the connection on port 1"), text)
        }
        machine.host = "no-such-host.invalid"
        do {
            _ = try await ConnectionCheck.hostKey(of: machine)
            XCTFail("found an .invalid host")
        } catch {
            let text = ConnectionCheck.describe(error, machine: machine)
            XCTAssertTrue(text.contains("Couldn't find no-such-host.invalid"), text)
        }
        XCTAssertTrue(ConnectionCheck.describe(SSHError.keyRejected, machine: machine).contains("authorized_keys"))
        XCTAssertTrue(ConnectionCheck.describe(ChannelError.connectTimeout(.seconds(10)), machine: machine).contains("didn't answer"))
    }

    /// The probe reads the host key without trusting it (needs scripts/ssh-test-server.sh).
    func testHostKeyProbeDoesntTrust() async throws {
        guard let pub = try? String(contentsOfFile: "/tmp/clotho-ios-sshtest/host_ed25519.pub", encoding: .utf8) else {
            throw XCTSkip("no SSH test server")
        }
        let machine = Machine(name: "", host: "127.0.0.1", port: 2222, user: "nobody")
        let presented = try await ConnectionCheck.hostKey(of: machine)
        XCTAssertEqual(presented.split(separator: " ").prefix(2), pub.split(separator: " ").prefix(2))
        XCTAssertNil(TrustedHostKeys.shared.key(for: machine.id))
    }
}

/// The iPad's layouts hand the place over when the width class changes, and quick open's ranking.
@MainActor
final class NavigationTests: XCTestCase {
    func testLayoutChangeKeepsThePlace() {
        let machine = UUID()
        let navigator = Navigator()
        navigator.open(.pane(machine, 4, 9))
        XCTAssertEqual(navigator.path, [.pane(machine, 4, 9)])
        navigator.switchLayout(regular: true)
        XCTAssertEqual(navigator.selection, .tab(machine, 4))
        XCTAssertEqual(navigator.initialPane, 9)
        navigator.open(.machine(machine))
        XCTAssertEqual(navigator.selection, .machine(machine))
        navigator.switchLayout(regular: false)
        XCTAssertEqual(navigator.path, [.machine(machine)])
    }

    func testQuickOpenRanking() {
        let id = UUID()
        func entry(_ kind: QuickOpenItem.Kind, _ title: String, _ subtitle: String = "") -> QuickOpenEntry {
            QuickOpenEntry(item: QuickOpenItem(kind: kind, title: title, subtitle: subtitle, id: title), symbol: "", route: .machine(id))
        }
        let entries = [entry(.tab, "cargo test", "devbox › clotho"), entry(.tab, "zsh", "devbox › clotho"),
                       entry(.workspace, "clotho", "devbox"), entry(.machine, "devbox")]
        XCTAssertEqual(QuickOpenEntry.ranked(entries, query: "clotho").first?.entry.item.title, "clotho")
        XCTAssertEqual(QuickOpenEntry.ranked(entries, query: "bigzsh").first?.entry.item.title, "zsh", "the subtitle matches too")
        XCTAssertTrue(QuickOpenEntry.ranked(entries, query: "qqq").isEmpty)
        XCTAssertEqual(QuickOpenEntry.ranked(entries, query: "").map(\.entry.item.title), entries.map(\.item.title),
                       "an empty query keeps the given order")
        let top = QuickOpenEntry.ranked(entries, query: "ct").first
        XCTAssertEqual(top?.entry.item.title, "cargo test")
        XCTAssertEqual(top?.indices, [0, 6])
    }

}

final class MachineInputTests: XCTestCase {
    func testHostsAndUsersThatArentOneAreRefused() {
        XCTAssertNil(Machine.problem(host: "devbox", user: "ahmad"))
        XCTAssertNil(Machine.problem(host: "fe80::1", user: "a.b-c_d"))
        XCTAssertNotNil(Machine.problem(host: "-oProxyCommand=touch /tmp/x", user: "ahmad"))
        XCTAssertNotNil(Machine.problem(host: "big boy", user: "ahmad"))
        XCTAssertNotNil(Machine.problem(host: "devbox\u{07}", user: "ahmad"))
        XCTAssertNotNil(Machine.problem(host: "devbox", user: "-l"))
        XCTAssertNotNil(Machine.problem(host: "ahmad@devbox", user: "ahmad"))
    }
}

final class PaneSearchTests: XCTestCase {
    func testDaemonLinesMapToBufferRows() {
        // 24 rows on screen under 76 lines of scrollback.
        let geometry = BufferGeometry(lineCount: 100, rows: 24, cols: 80)
        XCTAssertEqual(geometry.row(forLine: 0), 76, "the top screen row")
        XCTAssertEqual(geometry.row(forLine: 23), 99)
        XCTAssertEqual(geometry.row(forLine: -76), 0, "the oldest line held here")
        XCTAssertNil(geometry.row(forLine: -77), "older than this device's history")
        XCTAssertEqual(BufferGeometry(lineCount: 10, rows: 24, cols: 80).row(forLine: 3), 3, "a screen not yet full")
    }

    func testHistoryRowsRead() {
        let waiting = AgentHistoryEntry(at: 0, event: "state", kind: "claude", state: "waiting", from: "running", message: "Allow?")
        XCTAssertEqual(AgentHistoryRow.headline(waiting), "Claude: Running → Waiting")
        XCTAssertEqual(AgentHistoryRow.headline(AgentHistoryEntry(at: 0, event: "attention", attention: false)), "Resolved")
        XCTAssertEqual(AgentHistoryRow.headline(AgentHistoryEntry(at: 0, event: "gone", kind: "codex")), "Codex exited")
        XCTAssertEqual(AgentHistoryRow.detail(AgentHistoryEntry(at: 0, event: "state", pid: 42, guess: true)), "detected from output · pid 42")
    }
}
