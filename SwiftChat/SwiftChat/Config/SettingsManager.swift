//
//  SettingsManager.swift
//  SwiftChat
//
//  Created on 03/25/26.
//  Copyright © 2026 Sacha Servan-Schreiber. All rights reserved.
//

import SwiftUI
import Combine

/// Minimal settings manager for the chat template
@MainActor
class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    @Published var hapticFeedbackEnabled: Bool {
        didSet { UserDefaults.standard.set(hapticFeedbackEnabled, forKey: "hapticFeedbackEnabled") }
    }

    @Published var selectedLanguage: String {
        didSet { UserDefaults.standard.set(selectedLanguage, forKey: "selectedLanguage") }
    }

    @Published var maxMessages: Int {
        didSet { UserDefaults.standard.set(maxMessages, forKey: "maxPromptMessages") }
    }

    @Published var webSearchEnabled: Bool {
        didSet { UserDefaults.standard.set(webSearchEnabled, forKey: "webSearchEnabled") }
    }

    @Published var voiceModeEnabled: Bool {
        didSet { UserDefaults.standard.set(voiceModeEnabled, forKey: "voiceModeEnabled") }
    }
    @Published var autoPlayResponses: Bool {
        didSet { UserDefaults.standard.set(autoPlayResponses, forKey: "autoPlayResponses") }
    }
    @Published var isMuted: Bool {
        didSet { UserDefaults.standard.set(isMuted, forKey: "voiceMuted") }
    }
    @Published var speechSpeed: Double {
        didSet { UserDefaults.standard.set(speechSpeed, forKey: "speechSpeed") }
    }
    @Published var transcriptionLanguage: String {
        didSet { UserDefaults.standard.set(transcriptionLanguage, forKey: "transcriptionLanguage") }
    }

    // MARK: - Appearance (Makima)
    @Published var accentHex: String {
        didSet { UserDefaults.standard.set(accentHex, forKey: "makima.accentHex") }
    }

    /// Pure black chat canvas rather than the usual #121212 grouped grey.
    @Published var pureBlackBackground: Bool {
        didSet { UserDefaults.standard.set(pureBlackBackground, forKey: "makima.pureBlackBackground") }
    }

    @Published var orbCaptionsEnabled: Bool {
        didSet { UserDefaults.standard.set(orbCaptionsEnabled, forKey: "makima.orbCaptions") }
    }

    // MARK: - Behaviour (Makima)
    /// Keep audio and streaming alive when the app is backgrounded.
    @Published var backgroundAudioEnabled: Bool {
        didSet {
            UserDefaults.standard.set(backgroundAudioEnabled, forKey: "makima.backgroundAudio")
            BackgroundAudioController.shared.refresh()
        }
    }

    /// One-pass answers: skips the web-search round trip when on.
    @Published var fastMode: Bool {
        didSet { UserDefaults.standard.set(fastMode, forKey: "makima.fastMode") }
    }

    /// Routes replies through the gateway's lighter model instead of the main one.
    /// Distinct from `fastMode`, which only skips web search on the same model.
    @Published var lightweightModelMode: Bool {
        didSet {
            UserDefaults.standard.set(lightweightModelMode, forKey: "makima.lightweightModel")
            if lightweightModelMode { superModeEnabled = false }
        }
    }

    @Published var superModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(superModeEnabled, forKey: "makima.superMode")
            if superModeEnabled { lightweightModelMode = false }
        }
    }

    static let accentPresets: [(name: String, hex: String)] = [
        ("Rojo", "FF3B30"), ("Carmesi", "D7263D"), ("Naranja", "FF7A00"),
        ("Dorado", "E0A800"), ("Verde", "2FBF71"), ("Turquesa", "00B8D9"),
        ("Azul", "0A84FF"), ("Violeta", "8E5BEF"), ("Rosa", "FF4FA3"),
    ]

    var accentColor: Color { Color(hex: accentHex) }

    @Published var isUsingCustomPrompt: Bool {
        didSet { UserDefaults.standard.set(isUsingCustomPrompt, forKey: "isUsingCustomPrompt") }
    }

    @Published var customSystemPrompt: String {
        didSet { UserDefaults.standard.set(customSystemPrompt, forKey: "customSystemPrompt") }
    }

    private init() {
        self.hapticFeedbackEnabled = UserDefaults.standard.object(forKey: "hapticFeedbackEnabled") as? Bool ?? true
        self.selectedLanguage = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "System"
        self.maxMessages = UserDefaults.standard.object(forKey: "maxPromptMessages") as? Int ?? Constants.Context.defaultMaxMessages
        self.webSearchEnabled = false
        self.voiceModeEnabled = UserDefaults.standard.bool(forKey: "voiceModeEnabled")
        self.autoPlayResponses = UserDefaults.standard.object(forKey: "autoPlayResponses") as? Bool ?? true
        self.isMuted = UserDefaults.standard.bool(forKey: "voiceMuted")
        self.speechSpeed = UserDefaults.standard.object(forKey: "speechSpeed") as? Double ?? 1.0
        self.accentHex = UserDefaults.standard.string(forKey: "makima.accentHex") ?? "FF3B30"
        // Defaults to false so a fresh install respects the system appearance
        // instead of forcing a black canvas (and a black top bar) on the user.
        self.pureBlackBackground = UserDefaults.standard.object(forKey: "makima.pureBlackBackground") as? Bool ?? false
        self.orbCaptionsEnabled = UserDefaults.standard.object(forKey: "makima.orbCaptions") as? Bool ?? true
        self.backgroundAudioEnabled = UserDefaults.standard.object(forKey: "makima.backgroundAudio") as? Bool ?? true
        self.fastMode = UserDefaults.standard.object(forKey: "makima.fastMode") as? Bool ?? false
        // Off by default: the gateway rejects "makima-fast" unless MAKIMA_FAST_MODEL is set.
        self.lightweightModelMode = UserDefaults.standard.object(forKey: "makima.lightweightModel") as? Bool ?? false
        self.superModeEnabled = UserDefaults.standard.object(forKey: "makima.superMode") as? Bool ?? false
        self.transcriptionLanguage = UserDefaults.standard.string(forKey: "transcriptionLanguage") ?? "auto"
        self.isUsingCustomPrompt = UserDefaults.standard.object(forKey: "isUsingCustomPrompt") as? Bool ?? false
        self.customSystemPrompt = UserDefaults.standard.string(forKey: "customSystemPrompt") ?? ""
    }
}
