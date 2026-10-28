import UserNotifications
import WidgetKit

/// Decrypts an agent alert (docs/push.md) and fills in its text. If anything fails, iOS shows the
/// generic text the relay sent, which reveals nothing.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var original: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        // The alert's actions (Allow, Deny, Reply) only show once their categories are registered, and the app
        // registers them when it launches. After an update the first alerts can arrive before it has run, so the
        // extension registers the same set too (it replaces the app's with an identical one).
        UNUserNotificationCenter.current().setNotificationCategories(AlertActions.categories)
        // Decrypting is quick and synchronous; the expiry handler only covers a slow Keychain read.
        self.contentHandler = contentHandler
        original = request.content
        let key = PushKey.privateKey(create: false)
        let content = PushAlert.decrypt(request.content, key: key) ?? request.content
        // The widget learns about this agent now, while the app may be closed.
        if let ciphertext = request.content.userInfo["e"] as? String, let key,
           let alert = try? PushAlert.open(ciphertext, collapseID: request.content.threadIdentifier, key: key),
           let target = PushLabel.parse(alert.m), ["waiting", "done", "error"].contains(alert.s) {
            let now = Date().timeIntervalSince1970
            let agent = AgentsSummary.Agent(machine: target.machine, machineName: target.name, pane: alert.p, workspace: alert.w,
                                            kind: alert.k, state: alert.s, since: alert.t ?? now)
            if AgentsSummary.load().adding(agent, now: now).save() { WidgetCenter.shared.reloadAllTimelines() }
        }
        self.contentHandler = nil
        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let original { contentHandler?(original) }
    }
}
