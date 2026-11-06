import Foundation
import OpenAI
import Testing
import UserNotifications
@testable import SwiftChat

@MainActor
struct ResponseRecoveryTests {
    private func pending(startedAt: Date = Date(timeIntervalSince1970: 1000)) -> PendingResponse {
        PendingResponse(turnID: "turn_" + String(repeating: "a", count: 32), chatID: "chat-1",
                        messageID: "assistant-1", host: "test.invalid", request: Data("{}".utf8),
                        startedAt: startedAt, estimatedDuration: 90, submitted: true)
    }

    @Test func archiveRestoresPendingResponseAndStableAssistantIdentity() throws {
        let model = ModelType(id: "makima", displayName: "Makima", fullName: "Makima", iconName: "waveform", isMultimodal: true)
        var chat = Chat(id: "chat-1", messages: [Message(id: "assistant-1", role: .assistant, content: "Partial")], modelType: model)
        chat.pendingResponse = pending()
        chat.hasActiveStream = true
        let restored = try JSONDecoder().decode(Chat.self, from: JSONEncoder().encode(chat))
        #expect(restored.hasActiveStream)
        #expect(restored.pendingResponse == chat.pendingResponse)
        #expect(restored.messages.count == 1)
        #expect(restored.messages.first?.id == restored.pendingResponse?.messageID)
        #expect(restored.messages.first?.content == "Partial")
    }

    @Test func oldArchivesDecodeWithoutMarkingStreamActive() throws {
        let model = ModelType(id: "makima", displayName: "Makima", fullName: "Makima", iconName: "waveform", isMultimodal: true)
        let chat = Chat(modelType: model)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(chat)) as? [String: Any])
        object.removeValue(forKey: "pendingResponse")
        let restored = try JSONDecoder().decode(Chat.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored.pendingResponse == nil)
        #expect(!restored.hasActiveStream)
    }

    @Test func replayRequestPreservesModelInputAndTurnIDExactly() throws {
        let turn = pending().turnID
        let query = ChatQueryBuilder.buildQuery(modelId: "makima-fast", systemPrompt: "", rules: "",
                                               conversationMessages: [Message(role: .user, content: "Hello")],
                                               maxMessages: 20, chatId: "chat-1", turnId: turn)
        let bytes = try JSONEncoder().encode(query)
        let restored = try ResponseRecovery.replayQuery(from: bytes)
        let first = try JSONSerialization.jsonObject(with: bytes) as? NSDictionary
        let second = try JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? NSDictionary
        #expect(first == second)
        let metadata = try #require(first?["metadata"] as? [String: String])
        #expect(metadata["turn_id"] == turn)
        #expect(metadata["chat_id"] == "chat-1")
        #expect(restored.model == "makima-fast")
    }

    @Test func replayPreservesImagePayloadsAndAssistantHistory() throws {
        let query = CreateModelResponseQuery(input: .inputItemList([
            .inputMessage(EasyInputMessage(role: .assistant, content: .textInput("Previous answer"))),
            .inputMessage(EasyInputMessage(role: .user, content: .inputItemContentList([
                .inputText(Components.Schemas.InputTextContent(_type: .inputText, text: "Describe this")),
                .inputImage(InputImage(_type: .inputImage, imageUrl: "data:image/png;base64,test", detail: .auto))
            ])))
        ]), model: "makima", stream: true)
        let original = try JSONEncoder().encode(query)
        let replayed = try JSONEncoder().encode(ResponseRecovery.replayQuery(from: original))
        #expect((try JSONSerialization.jsonObject(with: original) as? NSDictionary)
                == (try JSONSerialization.jsonObject(with: replayed) as? NSDictionary))
    }

    @Test func reminderIsHonestStableAndOpensOriginalChat() throws {
        let request = NotificationService.reminderRequest(for: pending(), now: Date(timeIntervalSince1970: 1010))
        #expect(request.content.title == "Makima · Check your response")
        #expect(request.content.body.contains("may be ready"))
        #expect(!request.content.body.contains("finished"))
        #expect(request.content.userInfo["response_chat_id"] as? String == "chat-1")
        let trigger = try #require(request.trigger as? UNTimeIntervalNotificationTrigger)
        #expect(trigger.timeInterval == 80)
        #expect(!trigger.repeats)
        let overdue = NotificationService.reminderRequest(for: pending(), now: Date(timeIntervalSince1970: 2000))
        #expect((overdue.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval == 10)
        #expect(overdue.identifier == request.identifier)
    }

    @Test func expiredResponsesCannotTriggerAnotherInferenceOnRelaunch() {
        #expect(pending().hasExpired)
        #expect(!pending(startedAt: Date()).hasExpired)
    }
}
