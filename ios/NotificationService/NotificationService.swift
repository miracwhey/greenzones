import UserNotifications

/// Stub der Notification-Service-Extension.
///
/// W1 baut nur das Target (Signing, Entitlements, Einbettung) — die Logik
/// (CloudKit-Nachlese, Ereignis-Rangfolge, Snap-Texte) kommt in W4 als Port von
/// `client/ios/App/NotificationService/NotificationService.swift`. Bis dahin
/// reicht der Inhalt der Push-Nutzlast unveraendert durch: keine stille
/// Unterdrueckung, kein erfundener Text.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        bestAttempt = request.content.mutableCopy() as? UNMutableNotificationContent
        contentHandler(bestAttempt ?? request.content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let bestAttempt {
            contentHandler(bestAttempt)
        }
    }
}
