import Foundation
import UIKit
import UserNotifications

/// Posts a local notification when Makima finishes answering.
///
/// The user usually leaves the app while a response streams, so without this the
/// only way to know it is done is to switch back and look. The notification is
/// skipped while the app is in the foreground, where the answer is already visible.
enum NotificationService {
    private static let finishedIdentifier = "makima.response.finished"
    static let reminderPrefix = "makima.response.reminder."

    /// Ask once at launch. iOS only shows the prompt on the first request, so
    /// calling it repeatedly is harmless and keeps the flow simple.
    @MainActor
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            registerCategories()
        }
    }

    private static func registerCategories() {
        // No actions are registered; the category only makes the intent explicit
        // so a future "open chat" action has somewhere to live.
        let open = UNNotificationAction(identifier: "makima.open", title: "Open chat", options: .foreground)
        let category = UNNotificationCategory(
            identifier: "makima.response",
            actions: [open],
            intentIdentifiers: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// This is a timed reminder, NOT confirmation from the server that generation ended.
    static func reminderRequest(for pending: PendingResponse, now: Date = .now) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Makima · Check your response"
        content.body = "Your response may be ready. Open Makima to check its progress."
        content.sound = .default
        content.categoryIdentifier = "makima.response"
        content.userInfo = ["response_chat_id": pending.chatID, "response_turn_id": pending.turnID]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(10, pending.reminderDate.timeIntervalSince(now)), repeats: false)
        return UNNotificationRequest(identifier: reminderPrefix + pending.turnID, content: content, trigger: trigger)
    }

    @MainActor
    static func scheduleReminder(for pending: PendingResponse) {
        guard pending.submitted else { return }
        // No asynchronous settings lookup: submit while iOS still grants background runtime.
        UNUserNotificationCenter.current().add(reminderRequest(for: pending))
    }

    static func clearReminder(turnID: String) {
        let center = UNUserNotificationCenter.current()
        let identifier = reminderPrefix + turnID
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    /// Called when a stream finishes. No-ops in the foreground — the answer is
    /// already on screen — and when the user has not granted permission.
    @MainActor
    static func notifyResponseFinished(preview: String?, chatID: String? = nil) {
        guard UIApplication.shared.applicationState != .active else { return }

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }

            let trimmed = preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let content = UNMutableNotificationContent()
            content.title = "Makima terminó"
            content.body = trimmed.isEmpty ? "Tu respuesta está lista." : String(trimmed.prefix(120))
            content.sound = .default
            content.categoryIdentifier = "makima.response"
            if let chatID { content.userInfo = ["response_chat_id": chatID] }

            let request = UNNotificationRequest(
                identifier: finishedIdentifier,
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }
}
