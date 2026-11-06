import Foundation
import Testing
@testable import SwiftChat

@MainActor
struct AgendaTests {
    private let payload = #"{"items":[{"id":"report","version":1,"chat_id":"chat-1","kind":"task","title":"Finish report","notes":"","start_at":null,"end_at":null,"due_at":"2026-10-02T09:00:00Z","reminder_at":"2026-10-01T18:00:00Z","repeat":"daily","timezone":"America/Lima","message":"Need help?","completed":false}],"reminders":[{"id":"report_1","item_id":"report","chat_id":"chat-1","title":"Finish report","fire_at":"2026-10-01T18:00:00Z","message":"Need help?"}],"server_now":"2026-10-01T17:00:00Z","coverage_until":"2026-10-31T17:00:00Z"}"#

    @Test func gatewaySnapshotDecodesFlatFieldsAndRoundTripsCache() throws {
        let snapshot = try AgendaStore.decoder().decode(AgendaSnapshot.self, from: Data(payload.utf8))
        let item = try #require(snapshot.items.first)
        #expect(item.fields.kind == .task)
        #expect(item.fields.repeat == .daily)
        #expect(item.chatID == "chat-1")
        let cached = try AgendaStore.decoder().decode(AgendaSnapshot.self, from: AgendaStore.encoder().encode(snapshot))
        #expect(cached.items == snapshot.items)
        #expect(cached.reminders == snapshot.reminders)
    }

    @Test func commandsSendOnlyEditableFieldsAndDoNotRenameSnakeCaseDates() throws {
        let snapshot = try AgendaStore.decoder().decode(AgendaSnapshot.self, from: Data(payload.utf8))
        let item = try #require(snapshot.items.first)
        let command = AgendaCommand(action: "update", id: item.id, version: item.version, item: item.fields)
        let object = try #require(JSONSerialization.jsonObject(with: AgendaStore.encoder().encode(command)) as? [String: Any])
        let fields = try #require(object["item"] as? [String: Any])
        #expect(fields["due_at"] as? String == "2026-10-02T09:00:00Z")
        #expect(fields["chat_id"] == nil)
        #expect(fields["id"] == nil)
        #expect(object["version"] as? Int == 1)
    }

    @Test func eventsSpanningMidnightAppearOnBothDaysButNotOnEndBoundary() throws {
        let formatter = ISO8601DateFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var item = AgendaItem.draft(.event)
        item.fields.startAt = formatter.date(from: "2026-10-01T23:00:00Z")
        item.fields.endAt = formatter.date(from: "2026-10-03T00:00:00Z")
        #expect(item.occurs(on: try #require(formatter.date(from: "2026-10-01T12:00:00Z")), calendar: calendar))
        #expect(item.occurs(on: try #require(formatter.date(from: "2026-10-02T12:00:00Z")), calendar: calendar))
        #expect(!item.occurs(on: try #require(formatter.date(from: "2026-10-03T12:00:00Z")), calendar: calendar))
    }

    @Test func draftsHaveStableIDsAndCorrectRequiredDates() {
        let date = Date(timeIntervalSince1970: 1000)
        let event = AgendaItem.draft(.event, date: date)
        #expect(event.fields.endAt == date.addingTimeInterval(3600))
        #expect(event.version == 0)
        #expect(event.fields.reminderAt == date)
        #expect(event.id == event.id)
        let reminder = AgendaItem.draft(.reminder, date: date)
        #expect(reminder.fields.reminderAt == date.addingTimeInterval(3600))
        #expect(AgendaItem.draft(.task).fields.dueAt == nil)
        #expect(AgendaItem.draft(.task, date: date).fields.reminderAt == date.addingTimeInterval(3600))
    }
}
