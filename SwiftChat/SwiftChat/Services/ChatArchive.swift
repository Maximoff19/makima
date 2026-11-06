import Foundation

/// Local-first chat archive.
///
/// Chats used to live only in RAM, so a relaunch lost everything. This writes them
/// to Application Support as JSON and mirrors them to the VPS so Makima can build
/// durable memory from past conversations.
final class ChatArchive {
    static let shared = ChatArchive()

    private init() {}

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("chat-archive.json")
    }

    // MARK: - Local cache

    static func loadSync() -> [Chat] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return ((try? makeDecoder().decode([Chat].self, from: data)) ?? []).filter { !deletedChatIDs.contains($0.id) }
    }

    static func save(_ chats: [Chat]) {
        guard let data = try? makeEncoder().encode(chats) else { return }
        // Atomic write: a crash mid-save must not corrupt the whole archive.
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - VPS mirror

    /// Push one chat to the gateway. Failures are non-fatal by design: the local
    /// copy already exists and will be retried on the next message.
    static func sync(chat: Chat) async {
        guard !deletedChatIDs.contains(chat.id) else { return }
        let transcript = chat.messages
            .filter { $0.role == .user && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "User: \($0.content)" }
            + chat.messages
            .filter { $0.role == .assistant && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "Makima: \($0.content)" }

        guard !transcript.isEmpty else { return }

        let payload = ChatUpload(
            id: chat.id,
            title: chat.title == Chat.placeholderTitle ? "Conversación" : chat.title,
            updatedAt: chat.createdAt,
            transcript: transcript
        )

        var request = URLRequest(url: URL(string: "https://\(AppConfig.shared.apiHost)/v1/history")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(AppConfig.shared.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? makeEncoder().encode(payload)

        _ = try? await URLSession.shared.data(for: request)
    }

    /// Restore the archive from the VPS when the device has nothing cached.
    @MainActor
    static func fetchAll() async -> [Chat] {
        await retryDeletions()
        var request = URLRequest(url: URL(string: "https://\(AppConfig.shared.apiHost)/v1/history")!)
        request.setValue("Bearer \(AppConfig.shared.apiKey)", forHTTPHeaderField: "Authorization")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let uploads = try? makeDecoder().decode([ChatUpload].self, from: data),
              !uploads.isEmpty
        else { return [] }

        // The VPS keeps the transcript, not the full UI model, so rebuild a minimal
        // Chat per upload. Enough to browse history and to restore context.
        return uploads.filter { !deletedChatIDs.contains($0.id) }.map { upload in
            let restored = upload.transcript.map { line -> Message in
                let isUser = line.hasPrefix("User: ")
                let body = line.hasPrefix("Makima: ") ? String(line.dropFirst(8)) : String(line.dropFirst(8))
                return Message(role: isUser ? .user : .assistant, content: body)
            }
            return Chat.create(
                id: upload.id,
                title: upload.title,
                messages: restored,
                createdAt: upload.updatedAt,
                modelType: AppConfig.shared.availableModels.first
            )
        }
    }

    private static var deletedChatIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "archive.deletedChatIDs") ?? [])
    }

    static func delete(chatID: String) {
        var deleted = deletedChatIDs
        deleted.insert(chatID)
        UserDefaults.standard.set(Array(deleted), forKey: "archive.deletedChatIDs")
        var pending = Set(UserDefaults.standard.stringArray(forKey: "archive.pendingDeletionIDs") ?? [])
        pending.insert(chatID)
        UserDefaults.standard.set(Array(pending), forKey: "archive.pendingDeletionIDs")
        Task { await retryDeletions() }
    }

    static func retryDeletions() async {
        let pending = UserDefaults.standard.stringArray(forKey: "archive.pendingDeletionIDs") ?? []
        for id in pending {
            guard let url = URL(string: "https://\(AppConfig.shared.apiHost)/v1/history/\(id)") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.timeoutInterval = 15
            request.setValue("Bearer \(AppConfig.shared.apiKey)", forHTTPHeaderField: "Authorization")
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 204 {
                var remaining = Set(UserDefaults.standard.stringArray(forKey: "archive.pendingDeletionIDs") ?? [])
                remaining.remove(id)
                UserDefaults.standard.set(Array(remaining), forKey: "archive.pendingDeletionIDs")
            }
        }
    }
}

struct ChatUpload: Codable {
    let id: String
    let title: String
    let updatedAt: Date
    let transcript: [String]
}
