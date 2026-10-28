import UserNotifications

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
        let content = PushAlert.decrypt(request.content, key: PushKey.privateKey(create: false)) ?? request.content
        self.contentHandler = nil
        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let original { contentHandler?(original) }
    }
}
