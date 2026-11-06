import Foundation
import Observation
import UserNotifications

@MainActor @Observable
final class AgendaStore {
    static let shared = AgendaStore()
    private(set) var snapshot = AgendaSnapshot()
    private(set) var isRefreshing = false
    private(set) var isSaving = false
    var error: String?
    var notificationStatus = ""
    var lastSyncedAt: Date?
    var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "agenda.notifications.enabled") }
    }

    private let cacheURL: URL

    init(cacheURL: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.cacheURL = cacheURL ?? base.appendingPathComponent("agenda-cache.json")
        notificationsEnabled = UserDefaults.standard.bool(forKey: "agenda.notifications.enabled")
        if let data = try? Data(contentsOf: self.cacheURL),
           let cached = try? Self.decoder().decode(AgendaSnapshot.self, from: data) {
            snapshot = cached
        }
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    func refresh() async {
        guard !isRefreshing, !isSaving else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let value = try await request(path: "", command: nil)
            try accept(value)
            error = nil
            await reconcileNotifications()
        } catch {
            self.error = error.localizedDescription
        }
    }

    @discardableResult
    func save(_ item: AgendaItem, delete: Bool = false) async -> Bool {
        guard !isSaving, !isRefreshing else {
            error = "Agenda is syncing. Try again in a moment."
            return false
        }
        isSaving = true
        defer { isSaving = false }
        let creating = item.version == 0
        let command = AgendaCommand(action: delete ? "delete" : creating ? "create" : "update",
                                    id: creating ? nil : item.id,
                                    version: creating ? nil : item.version,
                                    item: delete ? nil : item.fields)
        do {
            let value = try await request(path: "/commands", command: command)
            try accept(value)
            error = nil
            await reconcileNotifications()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func request(path: String, command: AgendaCommand?) async throws -> AgendaSnapshot {
        guard let url = URL(string: "https://\(AppConfig.shared.apiHost)/v1/agenda\(path)") else {
            throw AgendaError.message("Invalid gateway address.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(AppConfig.shared.apiKey)", forHTTPHeaderField: "Authorization")
        if let command {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.encoder().encode(command)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw AgendaError.message("No response from the gateway.")
        }
        guard response.statusCode == 200 else {
            switch response.statusCode {
            case 404: throw AgendaError.message("Agenda unavailable or item removed. Refresh; the gateway may need an update.")
            case 409: throw AgendaError.message("The item changed on the server. Refresh before editing again.")
            case 401: throw AgendaError.message("The gateway rejected the connection credentials.")
            default: throw AgendaError.message("Could not save or load the agenda (\(response.statusCode)).")
            }
        }
        return try Self.decoder().decode(AgendaSnapshot.self, from: data)
    }

    private func accept(_ value: AgendaSnapshot) throws {
        // Schedule only after a successful cache write; offline relaunches need the same snapshot.
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder().encode(value).write(to: cacheURL, options: .atomic)
        snapshot = value
        lastSyncedAt = .now
    }

    func setNotificationsEnabled(_ enabled: Bool) async {
        notificationsEnabled = enabled
        if enabled {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                if !granted {
                    notificationStatus = "Notifications are blocked. Allow them in iPhone Settings."
                }
            } catch { notificationStatus = error.localizedDescription }
        }
        await reconcileNotifications()
    }

    func reconcileNotifications() async {
        do {
            notificationStatus = try await AgendaNotifications.synchronize(snapshot.reminders, enabled: notificationsEnabled)
        } catch {
            notificationStatus = "Could not schedule reminders: \(error.localizedDescription)"
        }
    }

    func dueReminders(now: Date = .now) -> [AgendaReminder] {
        snapshot.reminders.filter { $0.fireAt <= now }
    }
}

private enum AgendaError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): text }
    }
}
