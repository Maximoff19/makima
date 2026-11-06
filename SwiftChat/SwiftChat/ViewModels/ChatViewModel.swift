//
//  ChatViewModel.swift
//  SwiftChat
//
//  Created on 03/25/26.
//  Copyright © 2026 Sacha Servan-Schreiber. All rights reserved.
//

import Foundation
import Combine
import SwiftUI
import OpenAI
@_spi(Generated) import OpenAPIRuntime

@MainActor
class ChatViewModel: ObservableObject {
    private static let citationMarkerRegex = try? NSRegularExpression(pattern: "【(\\d+)[^】]*】", options: [])

    // Published properties for UI updates
    @Published var chats: [Chat] = []
    @Published var currentChat: Chat?
    @Published var isLoading: Bool = false
    @Published private(set) var lastGenerationCancelled: Bool = false
    @Published var thinkingSummary: String = ""
    @Published var webSearchSummary: String = ""
    @Published var scrollTargetMessageId: String? = nil
    @Published var scrollTargetOffset: CGFloat = 0
    @Published var shouldFocusInput: Bool = false
    @Published var isScrollInteractionActive: Bool = false
    @Published var isAtBottom: Bool = true
    @Published var scrollToBottomTrigger: UUID = UUID()
    @Published var isWebSearchEnabled: Bool = false
    @Published var imageViewerImages: [Attachment] = []
    @Published var imageViewerIndex: Int = 0
    @Published var showImageViewer: Bool = false
    @Published var editRequestedForMessageIndex: Int? = nil

    // Model properties
    @Published var currentModel: ModelType

    // Attachment properties
    @Published var pendingAttachments: [Attachment] = []
    @Published var isProcessingAttachment: Bool = false
    @Published var attachmentError: String? = nil
    @Published var pendingImageThumbnails: [String: String] = [:]

    var messages: [Message] {
        currentChat?.messages ?? []
    }

    // Private properties
    private var client: OpenAI?
    private var currentTask: Task<Void, Error>?
    private var responseAttemptID: UUID?
    private var isApplicationBackgrounded = false
    private var recoveryRetryTask: Task<Void, Never>?
    private var recoveryRetryCount = 0
    private var streamUpdateTimer: Timer?
    private var pendingStreamUpdate: Chat?
    private var networkStatusCancellable: AnyCancellable?

    init() {
        guard let model = AppConfig.shared.currentModel ?? AppConfig.shared.availableModels.first else {
            fatalError("ChatViewModel cannot be initialized without available models.")
        }
        self.currentModel = model
        self.isWebSearchEnabled = false

        // Restore the archive first so a relaunch never loses the history.
        let cached = ChatArchive.loadSync()
        if let first = cached.first {
            currentChat = first
            chats = cached
        } else {
            let newChat = Chat.create(modelType: currentModel)
            currentChat = newChat
            chats = [newChat]
        }

        setupClient()
        isLoading = currentChat?.pendingResponse != nil
        setupNetworkStatusObserver()
        restoreFromServerIfNeeded()
    }

    /// Persist locally and mirror to the VPS whenever the list changes.
    private func persistChats() {
        ChatArchive.save(chats)
    }

    /// If this device has no cached chats, pull the archive back from the server.
    private func restoreFromServerIfNeeded() {
        guard chats.count <= 1, chats.first?.messages.isEmpty != false else { return }
        Task {
            let remote = await ChatArchive.fetchAll()
            guard !remote.isEmpty else { return }
            await MainActor.run {
                self.chats = remote
                self.currentChat = remote[0]
            }
        }
    }

    deinit {
        streamUpdateTimer?.invalidate()
        networkStatusCancellable?.cancel()
    }

    // MARK: - Client Setup

    private func setupClient() {
        client = AppConfig.shared.apiHost.isEmpty || AppConfig.shared.apiKey.isEmpty ? nil : AppConfig.shared.makeClient()
    }

    func reconfigureClient() { setupClient() }

    func retryClientSetup() {
        guard client == nil else { return }
        guard !isLoading else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.retryClientSetup()
            }
            return
        }
        setupClient()
    }

    private func setupNetworkStatusObserver() {
        networkStatusCancellable = AppConfig.shared.networkMonitor.$isConnected
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] isConnected in
                guard let self = self, isConnected else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.retryClientSetup()
                    self?.resumePendingResponse()
                }
            }
    }

    // MARK: - Chat Management

    func createNewChat(language: String? = nil, modelType: ModelType? = nil, focusInput: Bool = true) {
        // Check if we already have a blank chat. Temporary chats are excluded: reusing one here
        // would silently turn a normal new chat into a throwaway session.
        if let existing = chats.first(where: { $0.isBlankChat && !$0.isTemporary }) {
            selectChat(existing)
            shouldFocusInput = focusInput
            return
        }

        let newChat = Chat.create(modelType: modelType ?? currentModel, language: language)
        chats.insert(newChat, at: 0)
        selectChat(newChat)
        shouldFocusInput = focusInput
        persistChats()
    }

    /// Chats that belong in the chat list. Temporary chats are session-scoped and never listed.
    var savedChats: [Chat] {
        chats.filter { !$0.isTemporary }
    }

    /// The temporary chat currently open, if any.
    var temporaryChat: Chat? {
        chats.first(where: { $0.isTemporary })
    }

    /// Starts a temporary chat: it is kept out of the chat list and discarded when closed.
    func createTemporaryChat(language: String? = nil) {
        if let existing = temporaryChat {
            selectChat(existing)
            shouldFocusInput = true
            return
        }

        // A blank chat is still kept in the list, so a temporary one cannot reuse that shortcut.
        let chat = Chat.create(
            title: "Temporary",
            modelType: currentModel,
            language: language,
            isTemporary: true
        )
        chats.insert(chat, at: 0)
        currentChat = chat
        shouldFocusInput = true
    }

    /// Discards the temporary chat and returns to the most recent saved chat.
    func closeTemporaryChat() {
        guard let temporary = temporaryChat else { return }
        if isLoading { cancelGeneration() }
        chats.removeAll { $0.id == temporary.id }
        if let first = savedChats.first {
            currentChat = first
        } else {
            createNewChat()
        }
        shouldFocusInput = true
    }
    func selectChat(_ chat: Chat) {
        // Leaving a temporary chat for a saved one discards the temporary conversation.
        if !chat.isTemporary,
           let temporary = temporaryChat,
           temporary.id != chat.id,
           !temporary.hasActiveStream {
            chats.removeAll { $0.id == temporary.id }
        }

        if let index = chats.firstIndex(where: { $0.id == chat.id }) {
            currentChat = chats[index]
        } else {
            currentChat = chat
            chats.append(chat)
        }

        isLoading = currentChat?.hasActiveStream ?? false

        if currentModel != chat.modelType {
            changeModel(to: chat.modelType, shouldUpdateChat: false)
        }
    }

    func deleteChat(_ id: String) {
        if let pending = chats.first(where: { $0.id == id })?.pendingResponse {
            ResponseRecovery.cancel(pending)
            NotificationService.clearReminder(turnID: pending.turnID)
            detachResponseTransport()
        }
        ChatArchive.delete(chatID: id)
        if let index = chats.firstIndex(where: { $0.id == id }) {
            chats.remove(at: index)
        }
        persistChats()

        if currentChat?.id == id {
            if let first = chats.first {
                currentChat = first
            } else {
                createNewChat()
            }
        }
    }

    func updateChatTitle(_ id: String, newTitle: String) {
        guard let index = chats.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            chats[index].title = Chat.placeholderTitle
            chats[index].titleState = .placeholder
        } else {
            chats[index].title = trimmed
            chats[index].titleState = .manual
        }
        if currentChat?.id == id {
            currentChat = chats[index]
        }
    }

    // MARK: - Message Sending

    /// Check-ins are assistant messages, not user turns or implementation checklist entries.
    func receiveAgendaReminders(_ reminders: [AgendaReminder], openReminderID: String? = nil) {
        guard !chats.contains(where: { $0.hasActiveStream }) else { return }
        var delivered = Set(UserDefaults.standard.stringArray(forKey: "agenda.deliveredReminderIDs") ?? [])
        var changed = false
        var chatToOpen: String?
        for reminder in reminders {
            let messageID = "agenda-\(reminder.id)"
            let existing = chats.first { $0.messages.contains(where: { $0.id == messageID }) }
            if reminder.id == openReminderID, let existing { chatToOpen = existing.id }
            guard !delivered.contains(reminder.id), existing == nil else { continue }
            let targetID = reminder.chatID.flatMap { id in
                chats.first(where: { $0.id == id && !$0.isTemporary })?.id
            } ?? "makima-personal-agenda"
            if !chats.contains(where: { $0.id == targetID }) {
                chats.insert(Chat.create(id: targetID, title: "Makima check-ins", titleState: .manual), at: 0)
            }
            guard let index = chats.firstIndex(where: { $0.id == targetID }) else { continue }
            chats[index].messages.append(Message(id: messageID, role: .assistant,
                                                content: reminder.message, timestamp: reminder.fireAt))
            if currentChat?.id == targetID { currentChat = chats[index] }
            if reminder.id == openReminderID { chatToOpen = targetID }
            delivered.insert(reminder.id)
            changed = true
        }
        if changed {
            persistChats()
            UserDefaults.standard.set(Array(delivered).sorted(), forKey: "agenda.deliveredReminderIDs")
        }
        if let chatToOpen, let chat = chats.first(where: { $0.id == chatToOpen }) {
            selectChat(chat)
            scrollToBottomTrigger = UUID()
        }
    }

    func sendMessage(text: String) {
        guard !chats.contains(where: { $0.hasActiveStream }) else { return }
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachments = !pendingAttachments.isEmpty
        guard hasText || hasAttachments else { return }

        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)

        isLoading = true

        let messageAttachments = pendingAttachments
        clearPendingAttachments()

        let userMessage = Message(role: .user, content: text, attachments: messageAttachments)
        addMessage(userMessage)

        if let chat = currentChat {
            persistChats()
            Task { await ChatArchive.sync(chat: chat) }
        }

        generateResponse()
    }

    // MARK: - Attachment Management

    func addImageAttachment(data: Data, fileName: String) {
        isProcessingAttachment = true
        attachmentError = nil

        let attachmentId = UUID().uuidString.lowercased()
        var attachment = Attachment(
            id: attachmentId,
            type: .image,
            fileName: fileName,
            fileSize: Int64(data.count),
            processingState: .processing
        )
        pendingAttachments.append(attachment)

        Task {
            // Simple image processing — resize and compress
            guard let uiImage = UIImage(data: data) else {
                attachment.processingState = .failed
                if let index = pendingAttachments.firstIndex(where: { $0.id == attachmentId }) {
                    pendingAttachments[index] = attachment
                }
                attachmentError = "Failed to load image"
                isProcessingAttachment = false
                return
            }

            let maxDim = Constants.Attachments.maxImageDimension
            let scale = min(maxDim / max(uiImage.size.width, uiImage.size.height), 1.0)
            let newSize = CGSize(width: uiImage.size.width * scale, height: uiImage.size.height * scale)

            UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
            uiImage.draw(in: CGRect(origin: .zero, size: newSize))
            let resized = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()

            guard let compressed = resized?.jpegData(compressionQuality: Constants.Attachments.imageCompressionQuality) else {
                attachment.processingState = .failed
                if let index = pendingAttachments.firstIndex(where: { $0.id == attachmentId }) {
                    pendingAttachments[index] = attachment
                }
                attachmentError = "Failed to compress image"
                isProcessingAttachment = false
                return
            }

            attachment.mimeType = Constants.Attachments.defaultImageMimeType
            attachment.base64 = compressed.base64EncodedString()
            attachment.fileSize = Int64(compressed.count)
            attachment.processingState = .completed

            let sizeKB = compressed.count / 1024
            attachment.description = "\(fileName) — \(Int(newSize.width))x\(Int(newSize.height)) JPEG, \(sizeKB) KB"

            // Generate thumbnail
            let thumbMax = Constants.Attachments.thumbnailMaxDimension
            let thumbScale = min(thumbMax / max(newSize.width, newSize.height), 1.0)
            let thumbSize = CGSize(width: newSize.width * thumbScale, height: newSize.height * thumbScale)
            UIGraphicsBeginImageContextWithOptions(thumbSize, false, 1.0)
            resized?.draw(in: CGRect(origin: .zero, size: thumbSize))
            let thumb = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()
            attachment.thumbnailBase64 = thumb?.jpegData(compressionQuality: 0.6)?.base64EncodedString()

            if let index = pendingAttachments.firstIndex(where: { $0.id == attachmentId }) {
                pendingAttachments[index] = attachment
            }
            if let tb = attachment.thumbnailBase64 {
                pendingImageThumbnails[attachmentId] = tb
            }
            isProcessingAttachment = false
        }
    }

    func addDocumentAttachment(url: URL, fileName: String) {
        isProcessingAttachment = true
        attachmentError = nil

        let attachmentId = UUID().uuidString.lowercased()
        var attachment = Attachment(
            id: attachmentId,
            type: .document,
            fileName: fileName,
            processingState: .processing
        )
        pendingAttachments.append(attachment)

        Task {
            // defer, not a trailing statement: if this task is cancelled the trailing line is
            // skipped and isProcessingAttachment stays true, which disables the + menu for good.
            defer { isProcessingAttachment = false }
            do {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }

                let text = try String(contentsOf: url, encoding: .utf8)
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

                attachment.textContent = text
                attachment.fileSize = fileSize
                attachment.processingState = .completed

                if let index = pendingAttachments.firstIndex(where: { $0.id == attachmentId }) {
                    pendingAttachments[index] = attachment
                }
            } catch {
                attachment.processingState = .failed
                if let index = pendingAttachments.firstIndex(where: { $0.id == attachmentId }) {
                    pendingAttachments[index] = attachment
                }
                attachmentError = error.localizedDescription
            }
        }
    }

    func removePendingAttachment(id: String) {
        pendingAttachments.removeAll { $0.id == id }
        pendingImageThumbnails.removeValue(forKey: id)
        if pendingAttachments.isEmpty { attachmentError = nil }
    }

    func clearPendingAttachments() {
        pendingAttachments.removeAll()
        pendingImageThumbnails.removeAll()
        attachmentError = nil
        isProcessingAttachment = false
    }

    // MARK: - Response Generation

    private func generateResponse(resuming pending: PendingResponse? = nil) {
        lastGenerationCancelled = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        isLoading = true
        VoicePlaybackService.shared.beginStreaming()

        let assistantMessage: Message
        if let pending,
           let chat = chats.first(where: { $0.id == pending.chatID }),
           let message = chat.messages.first(where: { $0.id == pending.messageID }) {
            assistantMessage = message
        } else if pending != nil {
            isLoading = false
            return
        } else {
            assistantMessage = Message(role: .assistant, content: "", isCollapsed: true)
            addMessage(assistantMessage)
        }

        if var chat = chats.first(where: { $0.id == (pending?.chatID ?? currentChat?.id) }) {
            chat.hasActiveStream = true
            replaceChat(chat)
            if currentChat?.id == chat.id { currentChat = chat }
        }

        guard let streamChatId = pending?.chatID ?? currentChat?.id,
              let streamChat = chats.first(where: { $0.id == streamChatId }) else {
            isLoading = false
            return
        }
        let streamMessages = Array(streamChat.messages.prefix { $0.id != assistantMessage.id })
        let streamModel = streamChat.modelType
        isLoading = currentChat?.id == streamChatId
        let turnID = pending?.turnID ?? "turn_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let attemptID = UUID()
        responseAttemptID = attemptID

        currentTask = Task {
            var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
            backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "CompleteStreamingResponse") {
                self.detachResponseTransport()
                UIApplication.shared.endBackgroundTask(backgroundTaskId)
                backgroundTaskId = .invalid
            }
            defer {
                if backgroundTaskId != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTaskId)
                }
            }

            var hasRetriedWithFreshKey = false

            retryLoop: while true {
              do {
                if client == nil { setupClient() }

                guard let client = client else {
                    throw NSError(domain: "ChatApp", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Client not initialized. Check your API key."])
                }

                let settingsManager = SettingsManager.shared
                // The gateway resolves "makima-fast" to MAKIMA_FAST_MODEL. If the VPS has no
                // lighter model configured it answers 400, so the toggle must stay off there.
                let modelId = settingsManager.superModeEnabled ? SuperModel.requestId :
                    (settingsManager.lightweightModelMode ? FastModel.requestId : streamModel.modelName)

                var systemPrompt: String
                if settingsManager.isUsingCustomPrompt && !settingsManager.customSystemPrompt.isEmpty {
                    systemPrompt = settingsManager.customSystemPrompt
                } else {
                    systemPrompt = AppConfig.shared.systemPrompt
                }

                systemPrompt = systemPrompt.replacingOccurrences(of: "{MODEL_NAME}", with: streamModel.fullName)

                let languageToUse = settingsManager.selectedLanguage != "System" ? settingsManager.selectedLanguage : "Español"
                systemPrompt = systemPrompt.replacingOccurrences(of: "{LANGUAGE}", with: languageToUse)
                systemPrompt = systemPrompt.replacingOccurrences(of: "{USER_PREFERENCES}", with: "")

                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                let currentDateTime = dateFormatter.string(from: Date())
                let timezone = TimeZone.current.abbreviation() ?? TimeZone.current.identifier
                systemPrompt = systemPrompt.replacingOccurrences(of: "{CURRENT_DATETIME}", with: currentDateTime)
                systemPrompt = systemPrompt.replacingOccurrences(of: "{TIMEZONE}", with: timezone)

                var processedRules = AppConfig.shared.rules
                if !processedRules.isEmpty {
                    processedRules = processedRules.replacingOccurrences(of: "{MODEL_NAME}", with: streamModel.fullName)
                    processedRules = processedRules.replacingOccurrences(of: "{LANGUAGE}", with: languageToUse)
                    processedRules = processedRules.replacingOccurrences(of: "{USER_PREFERENCES}", with: "")
                    processedRules = processedRules.replacingOccurrences(of: "{CURRENT_DATETIME}", with: currentDateTime)
                    processedRules = processedRules.replacingOccurrences(of: "{TIMEZONE}", with: timezone)
                }

                let builtQuery = ChatQueryBuilder.buildQuery(
                    modelId: modelId,
                    systemPrompt: systemPrompt,
                    rules: processedRules,
                    conversationMessages: streamMessages,
                    maxMessages: settingsManager.maxMessages,
                    chatId: streamChatId,
                    turnId: turnID,
                    webSearchEnabled: false,
                    isMultimodal: streamModel.isMultimodal
                )

                let chatQuery = try pending.map { try ResponseRecovery.replayQuery(from: $0.request) } ?? builtQuery
                if let pending, pending.hasExpired {
                    throw NSError(domain: "MakimaRecovery", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "This response has expired. Please send the message again."])
                }
                if var chat = self.chats.first(where: { $0.id == streamChatId }) {
                    if chat.pendingResponse == nil {
                        chat.pendingResponse = PendingResponse(
                            turnID: turnID, chatID: streamChatId, messageID: assistantMessage.id,
                            host: AppConfig.shared.apiHost, request: try JSONEncoder().encode(chatQuery),
                            startedAt: Date(), estimatedDuration: ResponseRecovery.estimatedDuration(for: modelId))
                    }
                    chat.hasActiveStream = true
                    self.replaceChat(chat)
                    if self.currentChat?.id == streamChatId { self.currentChat = chat }
                    self.persistChats()
                    if let request = chat.pendingResponse {
                        // Acknowledge ownership before detaching; recovery repeats this exact POST.
                        try await ResponseRecovery.start(request)
                        try Task.checkCancellation()
                        guard self.responseAttemptID == attemptID else { throw CancellationError() }
                        if var latest = self.chats.first(where: { $0.id == streamChatId }) {
                            latest.pendingResponse?.submitted = true
                            self.replaceChat(latest)
                            if self.currentChat?.id == streamChatId { self.currentChat = latest }
                            self.persistChats()
                            if self.isApplicationBackgrounded, let confirmed = latest.pendingResponse {
                                NotificationService.scheduleReminder(for: confirmed)
                                self.detachResponseTransport()
                                throw CancellationError()
                            }
                        }
                    }
                }

                var collectedSources: [WebSearchSource] = []

                let stream: AsyncThrowingStream<ResponseStreamEvent, Error> = client.responses.createResponseStreaming(query: chatQuery)

                var thinkStartTime: Date? = nil
                var thoughtsBuffer = ""
                var isInThinkingMode = false
                var responseContent = ""
                var currentThoughts: String? = nil
                // Live checklist for an implementation task, plus the tail of a control block
                // whose remainder has not arrived yet.
                var checklist: ProgressChecklist? = nil
                var agentActivity: AgentActivity? = nil
                var checklistTail = ""
                var generationTimeSeconds: TimeInterval? = nil
                let hapticEnabled = SettingsManager.shared.hapticFeedbackEnabled
                var hapticGenerator: UIImpactFeedbackGenerator?
                var lastHapticTime = Date.distantPast
                let minHapticInterval: TimeInterval = 0.1
                let chunker = StreamingMarkdownChunker()
                let thinkingChunker = ThinkingTextChunker()
                var hapticChunkCount = 0
                var hasStartedResponse = false
                var didCompleteResponse = false
                var lastUIUpdateTime = Date.distantPast
                let uiUpdateInterval: TimeInterval = 0.033

                await MainActor.run {
                    if pending == nil, let chat = self.chats.first(where: { $0.id == streamChatId }),
                       !chat.messages.isEmpty,
                       let lastIndex = chat.messages.indices.last {
                        responseContent = chat.messages[lastIndex].content
                        currentThoughts = chat.messages[lastIndex].thoughts
                        generationTimeSeconds = chat.messages[lastIndex].generationTimeSeconds
                        isInThinkingMode = chat.messages[lastIndex].isThinking
                    }
                    if hapticEnabled {
                        hapticGenerator = UIImpactFeedbackGenerator(style: .light)
                        hapticGenerator?.prepare()
                    }
                }

                for try await event in stream {
                    try Task.checkCancellation()
                    guard self.responseAttemptID == attemptID else { throw CancellationError() }

                    // Haptic feedback
                    if hapticEnabled, let generator = hapticGenerator {
                        if hapticChunkCount < 5 {
                            let now = Date()
                            if now.timeIntervalSince(lastHapticTime) >= minHapticInterval {
                                generator.impactOccurred(intensity: 0.5)
                                lastHapticTime = now
                                hapticChunkCount += 1
                            }
                        }
                        if !isInThinkingMode && !hasStartedResponse {
                            hasStartedResponse = true
                            hapticChunkCount = 0
                        }
                    }

                    var didMutateState = false

                    switch event {
                    case .outputText(.delta(let textEvent)):
                        // Super Makima sends progress ticks inside the text stream, wrapped in
                        // record-separator blocks. They are state, not prose: pull them out so
                        // they never land in the answer, and apply them to the live checklist.
                        let chunk = ChecklistProtocol.split(textEvent.delta, pending: &checklistTail)
                        if !chunk.payloads.isEmpty {
                            for payload in chunk.payloads {
                                if case .activity(let activity) = payload { agentActivity = activity }
                                checklist = ChecklistProtocol.apply(payload, to: checklist)
                            }
                            // State changes bypass the prose throttle. Await the update so an
                            // older scheduled snapshot cannot overwrite a newer checklist.
                            let progress = checklist
                            let activity = agentActivity
                            await MainActor.run {
                                guard var chat = self.chats.first(where: { $0.id == streamChatId }),
                                      self.responseAttemptID == attemptID,
                                      chat.hasActiveStream,
                                      let index = chat.messages.firstIndex(where: { $0.id == assistantMessage.id }) else { return }
                                chat.messages[index].checklist = progress
                                chat.messages[index].agentActivity = activity
                                self.replaceChat(chat)
                                if self.currentChat?.id == streamChatId { self.currentChat = chat }
                            }
                        }
                        let content = chunk.text
                        if !content.isEmpty {
                            if isInThinkingMode {
                                if let startTime = thinkStartTime {
                                    generationTimeSeconds = Date().timeIntervalSince(startTime)
                                }
                                isInThinkingMode = false
                                thinkStartTime = nil
                                thinkingChunker.finalize()
                                currentThoughts = thoughtsBuffer.isEmpty ? nil : thoughtsBuffer
                                Task { @MainActor [weak self] in
                                    ThinkingSummaryService.shared.reset()
                                    self?.thinkingSummary = ""
                                }
                            }
                            responseContent += content
                            chunker.appendToken(content)
                            VoicePlaybackService.shared.feed(content)
                            didMutateState = true
                            if !hasStartedResponse {
                                hasStartedResponse = true
                                hapticChunkCount = 0
                            }
                        }

                    case .reasoning(.delta(let reasoningEvent)):
                        let text = (reasoningEvent.delta.value as? [String: Any])?["text"] as? String ?? ""
                        if !text.isEmpty {
                            if !isInThinkingMode {
                                isInThinkingMode = true
                                thinkStartTime = Date()
                                Task { @MainActor in ThinkingSummaryService.shared.reset() }
                            }
                            thoughtsBuffer += text
                            thinkingChunker.appendToken(text)
                            currentThoughts = thoughtsBuffer.isEmpty ? nil : thoughtsBuffer
                            didMutateState = true
                            let currentThoughtsForSummary = thoughtsBuffer
                            Task { @MainActor [weak self] in
                                ThinkingSummaryService.shared.generateSummary(thoughts: currentThoughtsForSummary) { summary in
                                    self?.thinkingSummary = summary
                                }
                            }
                        }

                    case .outputTextAnnotation(.added(let annotationEvent)):
                        if let dict = annotationEvent.annotation.value as? [String: Any],
                           let type = dict["type"] as? String,
                           type == "url_citation",
                           let url = dict["url"] as? String {
                            let title = dict["title"] as? String ?? url
                            collectedSources.append(WebSearchSource(title: title, url: url))
                            didMutateState = true
                        }

                    case .error(let errorEvent):
                        throw NSError(domain: "MakimaStream", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: errorEvent.message])

                    case .outputText(.done(_)), .completed(_):
                        didCompleteResponse = true

                    case .webSearchCall(.inProgress(_)), .webSearchCall(.searching(_)):
                        Task { @MainActor [weak self] in
                            guard let self = self else { return }
                            guard self.responseAttemptID == attemptID else { return }
                            guard var chat = self.chats.first(where: { $0.id == streamChatId }),
                                  let lastIndex = chat.messages.firstIndex(where: { $0.id == assistantMessage.id }) else { return }
                            if chat.messages[lastIndex].webSearchState == nil {
                                chat.messages[lastIndex].webSearchState = WebSearchState(status: .searching)
                            }
                            if self.currentChat?.id == streamChatId {
                                self.webSearchSummary = "Searching the web..."
                            }
                            self.replaceChat(chat)
                            if self.currentChat?.id == streamChatId {
                                self.currentChat = chat
                            }
                        }

                    case .webSearchCall(.completed(_)):
                        Task { @MainActor [weak self] in
                            guard let self = self else { return }
                            guard self.responseAttemptID == attemptID else { return }
                            guard var chat = self.chats.first(where: { $0.id == streamChatId }),
                                  let lastIndex = chat.messages.firstIndex(where: { $0.id == assistantMessage.id }) else { return }
                            chat.messages[lastIndex].webSearchState?.status = .completed
                            if self.currentChat?.id == streamChatId {
                                self.webSearchSummary = ""
                            }
                            self.replaceChat(chat)
                            if self.currentChat?.id == streamChatId {
                                self.currentChat = chat
                            }
                        }

                    default:
                        break
                    }

                    // Throttled UI update
                    let now = Date()
                    if didMutateState && now.timeIntervalSince(lastUIUpdateTime) >= uiUpdateInterval {
                        lastUIUpdateTime = now
                        let currentChunks = chunker.getAllChunks()
                        let currentThinkingChunks = thinkingChunker.getAllChunks()
                        let capturedContent = responseContent
                        let capturedThoughts = currentThoughts
                        let capturedThinking = isInThinkingMode
                        let capturedGenTime = generationTimeSeconds
                        let capturedSources = collectedSources

                        Task { @MainActor [weak self] in
                            guard let self = self else { return }
                            guard self.responseAttemptID == attemptID else { return }
                            guard var chat = self.chats.first(where: { $0.id == streamChatId }),
                                  chat.hasActiveStream,
                                   let lastIndex = chat.messages.firstIndex(where: { $0.id == assistantMessage.id }) else { return }

                            let processedContent = self.processCitationMarkers(capturedContent, sources: capturedSources)
                            let processedChunks = self.processChunksWithCitations(currentChunks, sources: capturedSources)

                            chat.messages[lastIndex].content = processedContent
                            chat.messages[lastIndex].thoughts = capturedThoughts
                            chat.messages[lastIndex].thinkingChunks = currentThinkingChunks
                            chat.messages[lastIndex].isThinking = capturedThinking
                            chat.messages[lastIndex].generationTimeSeconds = capturedGenTime
                            chat.messages[lastIndex].contentChunks = processedChunks

                            if !capturedSources.isEmpty {
                                var searchState = chat.messages[lastIndex].webSearchState ?? WebSearchState(status: .searching)
                                searchState.sources = capturedSources
                                chat.messages[lastIndex].webSearchState = searchState
                            }

                            self.replaceChat(chat)
                            if self.currentChat?.id == streamChatId {
                                self.currentChat = chat
                            }
                        }
                    }
                }
                try Task.checkCancellation()
                guard didCompleteResponse else { throw URLError(.networkConnectionLost) }

                // Handle remaining thinking content when stream ends
                if isInThinkingMode && !thoughtsBuffer.isEmpty {
                    currentThoughts = thoughtsBuffer.isEmpty ? nil : thoughtsBuffer
                    if responseContent.isEmpty {
                        responseContent = thoughtsBuffer
                        currentThoughts = nil
                    }
                    if let startTime = thinkStartTime { generationTimeSeconds = Date().timeIntervalSince(startTime) }
                    isInThinkingMode = false
                }

                // Finalize message
                await MainActor.run {
                    guard self.responseAttemptID == attemptID else { return }
                    guard var chat = self.chats.first(where: { $0.id == streamChatId }) else {
                        self.isLoading = false
                        self.currentTask = nil
                        return
                    }
                    chat.hasActiveStream = false
                    if let finished = chat.pendingResponse {
                        NotificationService.clearReminder(turnID: finished.turnID)
                        ResponseRecovery.recordDuration(finished, model: chatQuery.model)
                    }
                    chat.pendingResponse = nil

                    ThinkingSummaryService.shared.reset()
                    self.thinkingSummary = ""
                    self.webSearchSummary = ""

                    if let lastIndex = chat.messages.firstIndex(where: { $0.id == assistantMessage.id }) {
                        chunker.finalize()
                        thinkingChunker.finalize()
                        let processedContent = self.processCitationMarkers(responseContent, sources: collectedSources)
                        chat.messages[lastIndex].content = processedContent
                        chat.messages[lastIndex].thoughts = currentThoughts
                        chat.messages[lastIndex].thinkingChunks = thinkingChunker.getAllChunks()
                        chat.messages[lastIndex].isThinking = false
                        chat.messages[lastIndex].agentActivity = nil
                        chat.messages[lastIndex].generationTimeSeconds = generationTimeSeconds
                        let processedChunks = self.processChunksWithCitations(chunker.getAllChunks(), sources: collectedSources)
                        chat.messages[lastIndex].contentChunks = processedChunks
                        if let checklist = checklist {
                            chat.messages[lastIndex].checklist = checklist
                        }
                        if !collectedSources.isEmpty {
                            var searchState = chat.messages[lastIndex].webSearchState ?? WebSearchState(status: .searching)
                            searchState.sources = collectedSources
                            chat.messages[lastIndex].webSearchState = searchState
                        }
                    }

                    self.replaceChat(chat)
                    if self.currentChat?.id == streamChatId {
                        self.currentChat = chat
                    }
                    self.isLoading = self.currentChat?.hasActiveStream ?? false
                    self.currentTask = nil
                    self.responseAttemptID = nil
                    self.recoveryRetryCount = 0
                    self.persistChats()
                    VoicePlaybackService.shared.finishStreaming()
                    NotificationService.notifyResponseFinished(
                        preview: chat.messages.last(where: { $0.role == .assistant })?.content,
                        chatID: streamChatId
                    )
                    Task { await ChatArchive.sync(chat: chat) }

                    // Generate title if needed
                    if chat.needsGeneratedTitle && chat.messages.count >= 2 {
                        Task {
                            if let generated = await self.generateLLMTitle(from: chat.messages) {
                                if var updatedChat = self.chats.first(where: { $0.id == chat.id }) {
                                    updatedChat.title = generated
                                    updatedChat.titleState = .generated
                                    self.replaceChat(updatedChat)
                                    if self.currentChat?.id == updatedChat.id {
                                        self.currentChat = updatedChat
                                    }
                                    Chat.triggerSuccessFeedback()
                                }
                            }
                        }
                    }
                }
                break retryLoop
            } catch {
                guard self.responseAttemptID == attemptID else { break retryLoop }
                if error is CancellationError || (error as NSError).domain == NSURLErrorDomain {
                    self.currentTask = nil
                    self.responseAttemptID = nil
                    self.persistChats()
                    if !self.isApplicationBackgrounded { self.scheduleResponseRecovery() }
                    break retryLoop
                }
                let shouldRetry = await MainActor.run {
                    if !hasRetriedWithFreshKey && ChatViewModel.isAuthenticationError(error) { return true }
                    return false
                }

                if shouldRetry {
                    hasRetriedWithFreshKey = true
                    await self.refreshClientForRetry()
                    if await MainActor.run(body: { self.client != nil }) {
                        continue retryLoop
                    }
                }

                await MainActor.run {
                    self.isLoading = false
                    self.currentTask = nil
                    self.thinkingSummary = ""
                    self.webSearchSummary = ""

                    if var chat = self.chats.first(where: { $0.id == streamChatId }) {
                        chat.hasActiveStream = false
                        if let failed = chat.pendingResponse {
                            NotificationService.clearReminder(turnID: failed.turnID)
                        }
                        chat.pendingResponse = nil
                        if let lastIndex = chat.messages.firstIndex(where: { $0.id == assistantMessage.id }) {
                            chat.messages[lastIndex].streamError = self.formatUserFriendlyError(error)
                            chat.messages[lastIndex].isRequestError = self.isRequestError(error)
                            chat.messages[lastIndex].agentActivity = nil
                        }
                        self.replaceChat(chat)
                        if self.currentChat?.id == streamChatId {
                            self.currentChat = chat
                        }
                        self.persistChats()
                        Task { await ChatArchive.sync(chat: chat) }
                    }
                }
                self.responseAttemptID = nil
                VoicePlaybackService.shared.stop()
                break retryLoop
              }
            }
        }
    }

    func cancelGeneration() {
        lastGenerationCancelled = true
        if let chat = chats.first(where: { $0.pendingResponse != nil }), let pending = chat.pendingResponse {
            ResponseRecovery.cancel(pending)
            NotificationService.clearReminder(turnID: pending.turnID)
            var cancelled = chat
            cancelled.pendingResponse = nil
            cancelled.hasActiveStream = false
            for index in cancelled.messages.indices { cancelled.messages[index].agentActivity = nil }
            replaceChat(cancelled)
            if currentChat?.id == cancelled.id { currentChat = cancelled }
        }
        detachResponseTransport()
        isLoading = false
        thinkingSummary = ""
        webSearchSummary = ""

        if var chat = currentChat {
            chat.hasActiveStream = false
            for index in chat.messages.indices { chat.messages[index].agentActivity = nil }
            replaceChat(chat)
            currentChat = chat
        }
        persistChats()
    }

    /// Detaching closes only the iPhone subscriber. Explicit Stop uses DELETE separately.
    private func detachResponseTransport() {
        recoveryRetryTask?.cancel()
        recoveryRetryTask = nil
        responseAttemptID = nil
        currentTask?.cancel()
        currentTask = nil
        VoicePlaybackService.shared.stop()
        persistChats()
    }

    func responseSceneChanged(_ phase: ScenePhase) {
        if phase == .background {
            isApplicationBackgrounded = true
            persistChats()
            if let pending = chats.compactMap(\.pendingResponse).first, pending.submitted {
                NotificationService.scheduleReminder(for: pending)
                detachResponseTransport()
            }
        } else if phase == .active {
            isApplicationBackgrounded = false
            recoveryRetryCount = 0
            openResponseReminderIfNeeded()
            resumePendingResponse()
            Task { await ResponseRecovery.retryCancellations() }
        }
    }

    func openResponseReminderIfNeeded() {
        guard let id = UserDefaults.standard.string(forKey: "makima.openResponseChatID"),
              let chat = chats.first(where: { $0.id == id }) else { return }
        UserDefaults.standard.removeObject(forKey: "makima.openResponseChatID")
        selectChat(chat)
        scrollToBottomTrigger = UUID()
    }

    private func resumePendingResponse() {
        guard !isApplicationBackgrounded, currentTask == nil,
              let pending = chats.compactMap(\.pendingResponse).first else { return }
        recoveryRetryTask?.cancel()
        recoveryRetryTask = nil
        NotificationService.clearReminder(turnID: pending.turnID)
        generateResponse(resuming: pending)
    }

    private func scheduleResponseRecovery() {
        guard recoveryRetryCount < 5 else { return }
        recoveryRetryCount += 1
        recoveryRetryTask?.cancel()
        recoveryRetryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            self?.resumePendingResponse()
        }
    }

    func regenerateLastResponse() {
        guard let chat = currentChat, !isLoading else { return }
        guard let lastUserMessageIndex = chat.messages.lastIndex(where: { $0.role == .user }) else { return }

        var updatedChat = chat
        updatedChat.messages = Array(chat.messages.prefix(lastUserMessageIndex + 1))
        replaceChat(updatedChat)
        currentChat = updatedChat

        isScrollInteractionActive = false
        scrollToBottomTrigger = UUID()
        generateResponse()
    }

    func editMessage(at messageIndex: Int, newContent: String) {
        guard let chat = currentChat,
              !isLoading,
              messageIndex >= 0,
              messageIndex < chat.messages.count,
              chat.messages[messageIndex].role == .user else { return }

        let trimmedContent = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return }

        var updatedChat = chat
        updatedChat.messages = Array(chat.messages.prefix(messageIndex))
        replaceChat(updatedChat)
        currentChat = updatedChat

        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        isLoading = true

        let userMessage = Message(role: .user, content: trimmedContent)
        addMessage(userMessage)
        generateResponse()
    }

    func regenerateMessage(at messageIndex: Int) {
        guard let chat = currentChat,
              !isLoading,
              messageIndex >= 0,
              messageIndex < chat.messages.count,
              chat.messages[messageIndex].role == .user else { return }

        var updatedChat = chat
        updatedChat.messages = Array(chat.messages.prefix(messageIndex + 1))
        replaceChat(updatedChat)
        currentChat = updatedChat

        isScrollInteractionActive = false
        scrollToBottomTrigger = UUID()
        generateResponse()
    }

    // MARK: - Model Management

    func changeModel(to modelType: ModelType, shouldUpdateChat: Bool = true) {
        guard modelType != currentModel else { return }

        if shouldUpdateChat {
            currentTask?.cancel()
            currentTask = nil
            isLoading = false
        }

        self.currentModel = modelType
        AppConfig.shared.currentModel = modelType

        if shouldUpdateChat, var chat = currentChat {
            chat.modelType = modelType
            replaceChat(chat)
            currentChat = chat
        }
    }

    // MARK: - Thoughts Collapse

    func setThoughtsCollapsed(for messageId: String, collapsed: Bool) {
        guard var chat = currentChat,
              let messageIndex = chat.messages.firstIndex(where: { $0.id == messageId }) else { return }
        guard chat.messages[messageIndex].isCollapsed != collapsed else { return }
        chat.messages[messageIndex].isCollapsed = collapsed
        replaceChat(chat)
        currentChat = chat
    }

    // MARK: - Private Helpers

    private func addMessage(_ message: Message) {
        guard var chat = currentChat else { return }
        chat.messages.append(message)
        replaceChat(chat)
        currentChat = chat
    }

    private func replaceChat(_ updatedChat: Chat) {
        if let index = chats.firstIndex(where: { $0.id == updatedChat.id }) {
            chats[index] = updatedChat
        } else if !updatedChat.isBlankChat {
            chats.insert(updatedChat, at: min(1, chats.count))
        }
    }

    private func refreshClientForRetry() async {
        setupClient()
    }

    private func formatUserFriendlyError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed:
                return "The Internet connection appears to be offline."
            case NSURLErrorNetworkConnectionLost:
                return "Network connection was lost."
            case NSURLErrorTimedOut:
                return "Request timed out. Please try again."
            default:
                return "Network error. Please check your connection."
            }
        }
        if case OpenAIError.statusError(_, let statusCode) = error {
            switch statusCode {
            case 401:
                return "Invalid API key. Please check your key and try again."
            case 429:
                return "Rate limit exceeded. Please wait a moment and try again."
            case 404:
                return "Model not found. The selected model may not be available on your plan."
            case 500...599:
                return "The server encountered an error. Please try again later."
            default:
                return "Request failed (status \(statusCode)). Please try again."
            }
        }
        if let apiError = error as? APIErrorResponse {
            return apiError.error.message
        }
        return "An error occurred. Please try again."
    }

    private func isRequestError(_ error: Error) -> Bool {
        if case OpenAIError.statusError(_, let statusCode) = error,
           (400...499).contains(statusCode), statusCode != 401 { return true }
        return false
    }

    static func isAuthenticationError(_ error: Error) -> Bool {
        if case OpenAIError.statusError(_, let statusCode) = error, statusCode == 401 { return true }
        if let apiError = error as? APIErrorResponse, apiError.error.code == "invalid_api_key" { return true }
        return false
    }

    private func processChunksWithCitations(_ chunks: [ContentChunk], sources: [WebSearchSource]) -> [ContentChunk] {
        chunks.map { chunk in
            ContentChunk(id: chunk.id, type: chunk.type, content: processCitationMarkers(chunk.content, sources: sources), isComplete: chunk.isComplete)
        }
    }

    private func processCitationMarkers(_ content: String, sources: [WebSearchSource]) -> String {
        guard !sources.isEmpty else { return content }
        guard let regex = Self.citationMarkerRegex else { return content }

        let nsContent = content as NSString
        let matches = regex.matches(in: content, options: [], range: NSRange(location: 0, length: nsContent.length))
        guard !matches.isEmpty else { return content }

        var result = ""
        var lastEnd = content.startIndex

        for match in matches {
            guard let matchRange = Range(match.range, in: content),
                  let numRange = Range(match.range(at: 1), in: content),
                  let num = Int(content[numRange]) else { continue }

            let index = num - 1
            guard index >= 0, index < sources.count else { continue }
            let source = sources[index]

            let encodedUrl = source.url
                .replacingOccurrences(of: "(", with: "%28")
                .replacingOccurrences(of: ")", with: "%29")
                .replacingOccurrences(of: "|", with: "%7C")
                .replacingOccurrences(of: "~", with: "%7E")
            let encodedTitle = (source.title
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? source.title)
                .replacingOccurrences(of: "(", with: "%28")
                .replacingOccurrences(of: ")", with: "%29")
                .replacingOccurrences(of: "~", with: "%7E")

            result += content[lastEnd..<matchRange.lowerBound]
            result += "[\(num)](#cite-\(num)~\(encodedUrl)~\(encodedTitle))"
            lastEnd = matchRange.upperBound
        }

        result += content[lastEnd...]
        return result
    }
}

// MARK: - LLM Title Generation
extension ChatViewModel {
    fileprivate func generateLLMTitle(from messages: [Message]) async -> String? {
        guard let assistantMessage = messages.first(where: { $0.role == .assistant }),
              !assistantMessage.content.isEmpty else { return nil }

        // Use the title model if available, otherwise skip title generation
        guard let titleModelConfig = AppConfig.shared.titleModel else { return nil }

        let words = assistantMessage.content.split(separator: " ", omittingEmptySubsequences: true)
        let truncatedContent = words.prefix(Constants.TitleGeneration.wordThreshold).joined(separator: " ")

        do {
            guard let client = client else { return nil }

            let query = CreateModelResponseQuery(
                input: .inputItemList([
                    .inputMessage(EasyInputMessage(role: .user, content: .textInput(truncatedContent)))
                ]),
                model: titleModelConfig.modelName,
                instructions: Constants.TitleGeneration.systemPrompt,
                maxOutputTokens: 50,
                stream: true
            )

            var title = ""
            let stream: AsyncThrowingStream<ResponseStreamEvent, Error> = client.responses.createResponseStreaming(query: query)
            for try await event in stream {
                if case .outputText(.delta(let textEvent)) = event {
                    title += textEvent.delta
                }
            }

            let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\"", with: "")
            return Self.shortenTitle(cleaned)
        } catch {
            return nil
        }
    }

    /// Clamp a generated title to a few words. The prompt asks for 3-4, but small models
    /// ignore it and return a sentence or a whole paragraph; the sidebar row is single-line,
    /// so an untrimmed title is both ugly and unreadable. Trailing punctuation goes too.
    private static func shortenTitle(_ title: String) -> String? {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let words = cleaned.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let limited = words.prefix(Constants.TitleGeneration.maximumTitleWords)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!?-–—"))
        return limited.isEmpty ? nil : limited
    }
}
