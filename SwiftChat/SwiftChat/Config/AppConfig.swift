//
//  AppConfig.swift
//  SwiftChat
//
//  Created on 03/25/26.
//  Copyright © 2026 Sacha Servan-Schreiber. All rights reserved.
//

import Foundation
import Combine
import OpenAI

/// A model available for chat
struct ModelType: Identifiable, Codable, Hashable, Equatable {
    let id: String
    let displayName: String
    let fullName: String
    let iconName: String
    let isMultimodal: Bool

    var modelName: String { id }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: ModelType, rhs: ModelType) -> Bool { lhs.id == rhs.id }
}

/// Application-wide configuration
@MainActor
class AppConfig: ObservableObject {
    static let shared = AppConfig()

    // MARK: - Configuration

    /// Gateway credentials are configured by the user and stored in Keychain.
    var apiKey: String = MakimaCredential.load() ?? ""

    /// OpenAI-compatible API host (no scheme, no path)
    var apiHost: String = UserDefaults.standard.string(forKey: "makimaHost") ?? ""

    /// Base path for the API
    var apiBasePath: String = "/v1"

    /// System prompt sent with every conversation
    var systemPrompt: String = ""

    /// Additional rules appended to the system prompt
    var rules: String = ""

    // MARK: - State

    @Published private(set) var isInitialized = false
    @Published private(set) var initializationError: Error?
    @Published var currentModel: ModelType? {
        didSet {
            if let model = currentModel {
                UserDefaults.standard.set(model.id, forKey: "selectedModel")
            }
        }
    }
    @Published private(set) var availableModels: [ModelType] = []
    @Published private(set) var networkMonitor = NetworkMonitor()

    private init() {
        setupDefaultModels()
        loadLastSelectedModel()
        isInitialized = true
    }

    // MARK: - Models

    /// Override this to change available models
    private func setupDefaultModels() {
        availableModels = [
            // Normal Makima uses Qwen2.5-VL directly; send real input_image parts.
            ModelType(id: "makima", displayName: "Makima", fullName: "Makima", iconName: "waveform", isMultimodal: true),
        ]
    }

    private func loadLastSelectedModel() {
        if let savedId = UserDefaults.standard.string(forKey: "selectedModel"),
           let model = availableModels.first(where: { $0.id == savedId }) {
            currentModel = model
        } else {
            currentModel = availableModels.first
        }
    }

    func filteredModelTypes() -> [ModelType] {
        return availableModels
    }

    /// The model used for generating chat titles (nil = skip title generation).
    /// Returning nil here silently disabled AI titles, so every chat stayed "Untitled".
    var titleModel: ModelType? {
        currentModel
    }

    // MARK: - OpenAI Client

    func makeClient() -> OpenAI {
        let config = OpenAI.Configuration(
            token: apiKey,
            host: apiHost,
            basePath: apiBasePath,
            // 300 s cut off any real implementation: the agent was still working and the phone
            // dropped the stream. A long task now streams progress until it finishes, so this is
            // only a last-resort ceiling for a connection that is genuinely dead.
            timeoutInterval: 3600
        )
        return OpenAI(configuration: config)
    }
}
