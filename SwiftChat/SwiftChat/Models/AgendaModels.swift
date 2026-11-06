import Foundation

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case chat, calendar, todo
    var id: String { rawValue }
    var title: String {
        switch self {
        case .chat: "Chat"
        case .calendar: "Calendar"
        case .todo: "To-do"
        }
    }
    var symbol: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .calendar: "calendar"
        case .todo: "checkmark.circle"
        }
    }
}

enum AgendaKind: String, Codable, CaseIterable, Identifiable {
    case event, task, reminder
    var id: String { rawValue }
    var title: String {
        switch self {
        case .event: "Event"
        case .task: "Task"
        case .reminder: "Check-in"
        }
    }
    var symbol: String {
        switch self {
        case .event: "calendar"
        case .task: "checkmark.circle"
        case .reminder: "bell"
        }
    }
}

enum AgendaRepeat: String, Codable, CaseIterable, Identifiable {
    case none, daily, weekly
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct AgendaFields: Codable, Equatable {
    var kind: AgendaKind
    var title = ""
    var notes = ""
    var startAt: Date?
    var endAt: Date?
    var dueAt: Date?
    var reminderAt: Date?
    var `repeat`: AgendaRepeat = .none
    var timezone = TimeZone.current.identifier
    var message = ""
    var completed = false

    enum CodingKeys: String, CodingKey {
        case kind, title, notes, timezone, message, completed, `repeat`
        case startAt = "start_at", endAt = "end_at", dueAt = "due_at", reminderAt = "reminder_at"
    }
}

/// The wire format is flat; the editable fields are grouped on the client only.
struct AgendaItem: Identifiable, Codable, Equatable {
    let id: String
    let version: Int
    let chatID: String?
    var fields: AgendaFields

    init(id: String = UUID().uuidString, version: Int = 0, chatID: String? = nil, fields: AgendaFields) {
        self.id = id
        self.version = version
        self.chatID = chatID
        self.fields = fields
    }

    enum CodingKeys: String, CodingKey { case id, version; case chatID = "chat_id" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        version = try container.decode(Int.self, forKey: .version)
        chatID = try container.decodeIfPresent(String.self, forKey: .chatID)
        fields = try AgendaFields(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(chatID, forKey: .chatID)
        try fields.encode(to: encoder)
    }

    var displayDate: Date? { fields.startAt ?? fields.dueAt ?? fields.reminderAt }

    func occurs(on date: Date, calendar: Calendar = .current) -> Bool {
        guard fields.kind == .event, let start = fields.startAt, let end = fields.endAt,
              let day = calendar.dateInterval(of: .day, for: date) else { return false }
        return start < day.end && end > day.start
    }

    static func draft(_ kind: AgendaKind, date: Date = .now) -> AgendaItem {
        var fields = AgendaFields(kind: kind)
        if kind == .event {
            fields.startAt = date
            fields.endAt = date.addingTimeInterval(3600)
            fields.reminderAt = date
        } else if kind == .reminder {
            fields.reminderAt = date.addingTimeInterval(3600)
        } else {
            fields.reminderAt = date.addingTimeInterval(3600)
        }
        return AgendaItem(fields: fields)
    }
}

struct AgendaReminder: Identifiable, Codable, Equatable {
    let id: String
    let itemID: String
    let chatID: String?
    let title: String
    let fireAt: Date
    let message: String

    enum CodingKeys: String, CodingKey {
        case id, title, message
        case itemID = "item_id", chatID = "chat_id", fireAt = "fire_at"
    }
}

struct AgendaSnapshot: Codable {
    var items: [AgendaItem] = []
    var reminders: [AgendaReminder] = []
    var serverNow: Date = .now
    var coverageUntil: Date = .now

    enum CodingKeys: String, CodingKey {
        case items, reminders
        case serverNow = "server_now", coverageUntil = "coverage_until"
    }
}

struct AgendaCommand: Encodable {
    let action: String
    let id: String?
    let version: Int?
    let item: AgendaFields?
}
