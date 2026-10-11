import AppKit
import UserNotifications

/// Notifications: a card was recognised, an import finished, a clip is waiting.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Set by the model: what to do when a button on a notification is pressed.
    var onAction: ((_ action: String, _ info: [String: String]) -> Void)?

    private static let cardCategory = "rushes.card"
    private static let doneCategory = "rushes.done"

    func setUp() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let review = UNNotificationAction(identifier: "review", title: String(localized: "Review"), options: [.foreground])
        let copy = UNNotificationAction(identifier: "copyAll", title: String(localized: "Copy everything"), options: [.foreground])
        let card = UNNotificationCategory(identifier: Self.cardCategory, actions: [review, copy], intentIdentifiers: [])
        let reveal = UNNotificationAction(identifier: "reveal", title: String(localized: "Show in Finder"), options: [.foreground])
        let eject = UNNotificationAction(identifier: "eject", title: String(localized: "Eject card"), options: [])
        let done = UNNotificationCategory(identifier: Self.doneCategory, actions: [reveal, eject], intentIdentifiers: [])
        center.setNotificationCategories([card, done])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func cardRecognised(name: String, summary: String, uuid: String) {
        post(id: "card.\(uuid)", title: String(localized: "\(name) and your disk are in"), body: summary,
             category: Self.cardCategory, info: ["card": uuid])
    }

    func importFinished(title: String, body: String, folder: String, card: String) {
        post(id: "done.\(folder)", title: title, body: body, category: Self.doneCategory, info: ["folder": folder, "card": card], sound: true)
    }

    func post(id: String, title: String, body: String, category: String? = nil, info: [String: String] = [:], sound: Bool = false) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let category { content.categoryIdentifier = category }
        content.userInfo = info
        if sound { content.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func remove(id: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo as? [String: String] ?? [:]
        let action = response.actionIdentifier == UNNotificationDefaultActionIdentifier ? "open" : response.actionIdentifier
        await MainActor.run { onAction?(action, info) }
    }
}
