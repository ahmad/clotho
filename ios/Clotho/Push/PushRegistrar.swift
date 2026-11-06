import ClothoKit
import CryptoKit
import Foundation
import UIKit

/// Agent alerts while the app is closed (docs/push.md). Gets an APNs token, trades it at the relay for a
/// push handle, and registers the handle and the phone's push key with every machine whose clothod
/// supports `push`. Machines then send alerts through the relay; the extension decrypts them.
@MainActor
final class PushRegistrar: ObservableObject {
    static let shared = PushRegistrar()

    /// The relay's address: the Cloudflare Worker in ios/relay, built in from the CLOTHO_RELAY_URL build setting
    /// (Info.plist `ClothoRelayURL`; scripts/clotho-build passes it from the dev box's private settings). Nil
    /// when the build had none: push alerts are then off. `-PushRelay <url>` (a launch argument or default)
    /// overrides it, for example with the local dev relay (relay/dev.js) at http://127.0.0.1:8787.
    static let deployedRelay: URL? = builtInRelay(Bundle.main.object(forInfoDictionaryKey: "ClothoRelayURL") as? String)

    /// The relay URL an Info.plist value names: nil when it is missing, empty, an unexpanded `$(...)`, or not an
    /// http(s) URL with a host.
    nonisolated static func builtInRelay(_ value: String?) -> URL? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty, !value.hasPrefix("$("),
              let url = URL(string: value), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// The handle the relay gave for this launch's token; nil until registered, or if there's no relay.
    @Published private(set) var handle: String?
    @Published private(set) var lastError: String?

    /// Identifies this phone to machines, so registering again replaces the old entry.
    let device: String = {
        if let id = UserDefaults.standard.string(forKey: "PushDevice") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "PushDevice")
        return id
    }()

    var relay: URL? {
        if let override = UserDefaults.standard.string(forKey: "PushRelay") { return URL(string: override) }
        return Self.deployedRelay
    }

    /// Debug builds are signed for APNs's sandbox, TestFlight and App Store builds for production.
    var environment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    func start() {
        guard let relay else {
            return log("push: no relay URL in this build (CLOTHO_RELAY_URL unset at build time) and no -PushRelay; push alerts are off")
        }
        log("push: registering for remote notifications (relay \(relay.absoluteString))")
        UIApplication.shared.registerForRemoteNotifications()
    }

    func didRegister(token: Data) {
        Task { await register(token: token.map { String(format: "%02x", $0) }.joined()) }
    }

    func didFailToRegister(_ error: Error) {
        #if DEBUG && targetEnvironment(simulator)
        // A simulator build without the push entitlement gets no token; the dev relay delivers with
        // `simctl push`, which ignores it, so any well-formed token will do.
        log("push: no APNs token (\(error.localizedDescription)); using a placeholder for the dev relay")
        Task { await register(token: String(repeating: "0", count: 64)) }
        #else
        lastError = error.localizedDescription
        log("push: registering for remote notifications failed: \(error)")
        #endif
    }

    private func register(token: String) async {
        guard let relay else { return }
        do {
            var request = URLRequest(url: relay.appendingPathComponent("v1/register"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["token": token, "env": environment])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let handle = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["handle"] as? String else {
                throw URLError(.badServerResponse)
            }
            self.handle = handle
            lastError = nil
            NotificationCenter.default.post(name: .pushHandleChanged, object: nil)
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "PushSelfTest") { await selfTest() }
            #endif
        } catch {
            lastError = "Couldn't reach the alert relay: \(error.localizedDescription)"
            log("push: relay registration failed: \(error)")
        }
    }

    #if DEBUG
    /// `-PushSelfTest YES`: does what a machine does, encrypting an alert to this phone's key and sending it
    /// through the relay, so the relay, the extension and the shared Keychain can be checked without clothod.
    private func selfTest() async {
        guard let handle, let relay, let key = PushKey.privateKey(create: true) else { return }
        let label = PushLabel.make(machine: UUID(), name: "Self test")
        let collapse = PushLabel.collapseID(label: label, pane: 1)
        do {
            let alert = PushAlert(v: 1, m: label, p: 1, k: "claude", s: "waiting", msg: "Allow push self test?", t: Date().timeIntervalSince1970)
            var request = URLRequest(url: relay.appendingPathComponent("v1/push"))
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "handle": handle, "ciphertext": try PushAlert.seal(alert, collapseID: collapse, to: key.publicKey), "collapse_id": collapse,
            ])
            let (_, response) = try await URLSession.shared.data(for: request)
            log("push: self test sent, relay answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        } catch {
            log("push: self test failed: \(error)")
        }
    }
    #endif

    /// What a machine needs to send this phone alerts, labelled with the machine's id and name in the app.
    func registration(for machine: Machine) -> PushRegistration? {
        guard let handle, let relay, let key = PushKey.privateKey(create: true) else { return nil }
        return PushRegistration(device: device, handle: handle, key: key.publicKey.rawRepresentation.base64EncodedString(),
                                label: PushLabel.make(machine: machine.id, name: machine.displayName),
                                relay: relay.absoluteString, env: environment)
    }
}

extension Notification.Name {
    static let pushHandleChanged = Notification.Name("ClothoPushHandleChanged")
}

/// Receives the APNs token, which only arrives through an app delegate.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MainActor.assumeIsolated { PushRegistrar.shared.start() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated { PushRegistrar.shared.didRegister(token: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        MainActor.assumeIsolated { PushRegistrar.shared.didFailToRegister(error) }
    }
}
