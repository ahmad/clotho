import ClothoKit
import UIKit
import UserNotifications

/// Carries out a notification action (Allow, Deny, Reply) on its machine. iOS wakes the app in the background
/// for it and gives it a short time: connect over SSH, send the answer, and close again. If the machine can't
/// be reached in time, a notification says so, so an answer never fails silently.
@MainActor
enum AlertActionRunner {
    /// How long to wait for the machine before giving up (iOS allows about 30 s for the whole action).
    static let connectTimeout: TimeInterval = 20

    static func run(_ action: AlertAction, machines: MachineList, connections: Connections) async {
        guard let machine = machines.machine(action.machine) else { return }
        let app = UIApplication.shared
        var task = UIBackgroundTaskIdentifier.invalid
        task = app.beginBackgroundTask(withName: "Clotho alert action") {
            app.endBackgroundTask(task)
            task = .invalid
        }
        defer { if task != .invalid { app.endBackgroundTask(task) } }

        let connection = connections.connection(for: machine)
        connection.answeringActions += 1
        defer { connection.answeringActions -= 1 }
        connection.connect()
        let deadline = Date().addingTimeInterval(connectTimeout)
        while !connection.store.isConnected || connection.store.isSaved, Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        defer { if app.applicationState != .active { connection.suspend() } }
        guard connection.store.isConnected, !connection.store.isSaved else {
            return report(machine.displayName, "Clotho couldn't reach it in time. Open Clotho to answer.")
        }

        switch action.kind {
        case .allow, .deny:
            guard let request = action.request else { return }
            guard connection.canDecide else {
                return report(machine.displayName, "Its clothod can't take answers from the phone yet. Open Clotho to answer.")
            }
            let decision: PermissionDecision
            let reason: String?
            if case .deny(let text) = action.kind {
                decision = .deny
                reason = text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            } else {
                decision = .allow
                reason = nil
            }
            switch await connection.decide(action.pane, request: request, decision: decision, message: reason) {
            case .done, .alreadyAnswered:
                break
            case .failed(let message):
                // The machine may have applied it before the connection dropped: say so, and check there.
                report(machine.displayName, "Clotho couldn't confirm the answer (\(message)). Open Clotho to check.")
            }
        case .reply(let text):
            let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else { return }
            guard connection.canReply else {
                return report(machine.displayName, "Its clothod can't take replies from the phone yet. Open Clotho to reply.")
            }
            do {
                try await connection.store.backend.sendKeys(action.pane, text: message, keys: ["enter"])
            } catch {
                report(machine.displayName, "The reply didn't go through (\(error.localizedDescription)). Open Clotho to reply.")
            }
        }
    }

    /// A plain local notification about an action that couldn't be done.
    private static func report(_ machine: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = "Couldn't answer on \(machine)"
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
