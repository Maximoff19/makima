import Foundation
import UserNotifications

extension Notification.Name {
    static let agendaReminderOpened = Notification.Name("makima.agenda.reminder.opened")
    static let responseReminderOpened = Notification.Name("makima.response.reminder.opened")
}

enum AgendaNotifications {
    static let prefix = "makima.agenda."

    static func synchronize(_ reminders: [AgendaReminder], enabled: Bool, now: Date = .now) async throws -> String {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let owned = pending.filter { $0.identifier.hasPrefix(prefix) }
        let settings = await center.notificationSettings()
        let permitted = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
        let upcoming = enabled && permitted ? Array(reminders.filter { $0.fireAt > now }.prefix(60)) : []
        let wanted = Set(upcoming.map { prefix + $0.id })
        center.removePendingNotificationRequests(withIdentifiers: owned.map(\.identifier).filter { !wanted.contains($0) })
        let delivered = await center.deliveredNotifications()
        let active = Set(reminders.map { prefix + $0.id })
        center.removeDeliveredNotifications(withIdentifiers: delivered.map(\.request.identifier).filter {
            $0.hasPrefix(prefix) && (!enabled || !active.contains($0))
        })
        guard enabled else { return "Reminder notifications are off. Check-ins still appear when you open the app." }
        guard permitted else { return "Notifications are blocked. Allow them in iPhone Settings." }
        let existing = Dictionary(uniqueKeysWithValues: owned.map { ($0.identifier, $0.content) })
        for reminder in upcoming {
            if let old = existing[prefix + reminder.id],
               old.body == reminder.message, old.title == "Makima · \(reminder.title)" { continue }
            let content = UNMutableNotificationContent()
            content.title = "Makima · \(reminder.title)"
            content.body = reminder.message
            content.sound = .default
            content.userInfo = ["agenda_reminder_id": reminder.id]
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.fireAt)
            components.timeZone = calendar.timeZone
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            try await center.add(UNNotificationRequest(identifier: prefix + reminder.id, content: content, trigger: trigger))
        }
        return "\(upcoming.count) upcoming reminders scheduled on this iPhone."
    }
}

/// Retained by the app; tapping a reminder brings its original chat into view.
final class AgendaNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AgendaNotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // In-app check-ins are visible in chat; avoid a duplicate banner while foregrounded.
        notification.request.identifier.hasPrefix(AgendaNotifications.prefix) ? [.sound] : [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        if let chatID = response.notification.request.content.userInfo["response_chat_id"] as? String {
            await MainActor.run {
                UserDefaults.standard.set(chatID, forKey: "makima.openResponseChatID")
                NotificationCenter.default.post(name: .responseReminderOpened, object: nil)
            }
            return
        }
        guard let id = response.notification.request.content.userInfo["agenda_reminder_id"] as? String else { return }
        await MainActor.run {
            UserDefaults.standard.set(id, forKey: "agenda.openReminderID")
            NotificationCenter.default.post(name: .agendaReminderOpened, object: nil)
        }
    }
}
