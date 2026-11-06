import Foundation
import OpenAI

/// The exact request is persisted before sending, making reconnects idempotent.
struct PendingResponse: Codable, Equatable {
    let turnID: String
    let chatID: String
    let messageID: String
    let host: String
    let request: Data
    let startedAt: Date
    let estimatedDuration: TimeInterval
    var submitted: Bool = false

    var reminderDate: Date { startedAt.addingTimeInterval(estimatedDuration) }
    var hasExpired: Bool { Date().timeIntervalSince(startedAt) >= 86400 }
}

@MainActor
enum ResponseRecovery {
    private static let cancellationsKey = "makima.pendingResponseCancellations"

    /// The SDK encodes EasyInputMessage but its InputItem decoder rejects that schema.
    /// Decode our messages explicitly, preserving every other request field unchanged.
    static func replayQuery(from data: Data) throws -> CreateModelResponseQuery {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = object["input"] as? [[String: Any]] else {
            throw URLError(.cannotDecodeContentData)
        }
        let decoder = JSONDecoder()
        let items = try messages.map { message in
            InputItem.inputMessage(try decoder.decode(EasyInputMessage.self, from: JSONSerialization.data(withJSONObject: message)))
        }
        object["input"] = ""
        let original = try decoder.decode(CreateModelResponseQuery.self, from: JSONSerialization.data(withJSONObject: object))
        return CreateModelResponseQuery(
            input: .inputItemList(items), model: original.model, include: original.include,
            background: original.background, instructions: original.instructions,
            maxOutputTokens: original.maxOutputTokens, metadata: original.metadata,
            parallelToolCalls: original.parallelToolCalls, previousResponseId: original.previousResponseId,
            prompt: original.prompt, reasoning: original.reasoning, serviceTier: original.serviceTier,
            store: original.store, stream: original.stream, temperature: original.temperature,
            text: original.text, toolChoice: original.toolChoice, tools: original.tools,
            topP: original.topP, truncation: original.truncation, user: original.user)
    }

    static func start(_ pending: PendingResponse) async throws {
        guard pending.host == AppConfig.shared.apiHost else {
            throw NSError(domain: "MakimaRecovery", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Reconnect to the original gateway to recover this response."])
        }
        var request = URLRequest(url: URL(string: "https://\(pending.host)/v1/response-turns")!)
        request.httpMethod = "POST"
        request.httpBody = pending.request
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(AppConfig.shared.apiKey)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard response.statusCode == 202 else {
            throw OpenAIError.statusError(response: response, statusCode: response.statusCode)
        }
    }

    /// Record locally before stopping the transport; retry DELETE after connectivity returns.
    static func cancel(_ pending: PendingResponse) {
        var saved = cancellations
        if !saved.contains(where: { $0.turnID == pending.turnID }) { saved.append(pending) }
        saveCancellations(saved)
        Task { await retryCancellations() }
    }

    static var cancellations: [PendingResponse] {
        guard let data = UserDefaults.standard.data(forKey: cancellationsKey) else { return [] }
        return (try? JSONDecoder().decode([PendingResponse].self, from: data)) ?? []
    }

    private static func saveCancellations(_ values: [PendingResponse]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(values), forKey: cancellationsKey)
    }

    static func retryCancellations() async {
        for pending in cancellations where pending.host == AppConfig.shared.apiHost {
            var request = URLRequest(url: URL(string: "https://\(pending.host)/v1/responses/\(pending.turnID)")!)
            request.httpMethod = "DELETE"
            request.timeoutInterval = 15
            request.setValue("Bearer \(AppConfig.shared.apiKey)", forHTTPHeaderField: "Authorization")
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 204 {
                saveCancellations(cancellations.filter { $0.turnID != pending.turnID })
            }
        }
    }

    static func estimatedDuration(for model: String) -> TimeInterval {
        let value = UserDefaults.standard.double(forKey: "makima.responseDuration.\(model)")
        return value > 0 ? value : 90
    }

    static func recordDuration(_ pending: PendingResponse, model: String) {
        let elapsed = min(600, max(30, Date().timeIntervalSince(pending.startedAt)))
        let previous = estimatedDuration(for: model)
        UserDefaults.standard.set(previous * 0.7 + elapsed * 0.3, forKey: "makima.responseDuration.\(model)")
    }
}
