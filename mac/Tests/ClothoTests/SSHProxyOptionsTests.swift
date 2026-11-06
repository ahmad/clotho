@testable import Clotho
import XCTest

/// The dev build's SSH proxy hook (SSHProxyCommand, SSHProxyUseFdpass): never in the user's app.
final class SSHProxyOptionsTests: XCTestCase {
    func testNoCommandNoOptions() {
        XCTAssertEqual(AppDelegate.proxyOptions(command: nil, fdpass: true, dev: true), [])
        XCTAssertEqual(AppDelegate.proxyOptions(command: "", fdpass: true, dev: true), [])
    }

    func testOnlyInDevBuilds() {
        XCTAssertEqual(AppDelegate.proxyOptions(command: "relay %h %p", fdpass: true, dev: false), [])
    }

    func testCommandAlone() {
        XCTAssertEqual(AppDelegate.proxyOptions(command: "relay %h %p", fdpass: false, dev: true), ["-o", "ProxyCommand=relay %h %p"])
    }

    func testCommandWithFdpass() {
        let command = "'/Applications/Clotho Dev.app/Contents/MacOS/clotho-tailnet-proxy' --socket '/tmp/x/proxy.sock' %h %p"
        XCTAssertEqual(AppDelegate.proxyOptions(command: command, fdpass: true, dev: true),
                       ["-o", "ProxyCommand=\(command)", "-o", "ProxyUseFdpass=yes"])
    }
}
