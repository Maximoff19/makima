import AVFoundation
import Combine
import Foundation

/// Speaks streamed responses with the iPhone's local speech synthesizer and reports the exact
/// word frontier supplied by iOS. Siri Voice 2 is preferred when the device exposes it.
@MainActor
final class VoicePlaybackService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = VoicePlaybackService()

    @Published private(set) var isSpeaking = false
    @Published private(set) var isUtteranceActive = false
    @Published private(set) var spokenWordCount = 0

    private let synthesizer = AVSpeechSynthesizer()
    private var queue: [String] = []
    private var buffer = ""
    private var streamOpen = false
    private var pendingUtteranceCount = 0
    private var scheduledWordCount = 0
    private var progressByUtterance: [ObjectIdentifier: UtteranceProgress] = [:]

    private var isVoiceAllowed: Bool {
        SettingsManager.shared.voiceModeEnabled
            && SettingsManager.shared.autoPlayResponses
            && !SettingsManager.shared.isMuted
    }

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Control

    func stop() {
        streamOpen = false
        queue.removeAll()
        buffer = ""
        pendingUtteranceCount = 0
        scheduledWordCount = 0
        progressByUtterance.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        isUtteranceActive = false
        spokenWordCount = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func beginStreaming() {
        stop()
        guard isVoiceAllowed else { return }
        streamOpen = true
        isUtteranceActive = true
        configureAudioSession()
    }

    func feed(_ delta: String) {
        guard streamOpen, isVoiceAllowed, !delta.isEmpty else { return }
        buffer += delta
    }

    func finishStreaming() {
        guard streamOpen else { return }
        streamOpen = false

        let completeResponse = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        if !completeResponse.isEmpty {
            queue = [completeResponse]
        }
        pump()
    }

    func speak(_ text: String) {
        stop()
        let completeResponse = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isVoiceAllowed, !completeResponse.isEmpty else { return }
        isUtteranceActive = true
        configureAudioSession()
        queue = [completeResponse]
        pump()
    }

    // MARK: - Speech synthesis

    private func pump() {
        while !queue.isEmpty {
            let text = queue.removeFirst()
            let wordCount = Self.wordCount(text)
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = Self.preferredVoice()
            utterance.rate = Self.speechRate(for: SettingsManager.shared.speechSpeed)

            let identifier = ObjectIdentifier(utterance)
            progressByUtterance[identifier] = UtteranceProgress(
                startWord: scheduledWordCount,
                wordCount: wordCount
            )
            scheduledWordCount += wordCount
            pendingUtteranceCount += 1
            synthesizer.speak(utterance)
        }

        settleUtteranceIfFinished()
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
    }

    /// Prefer the installed Siri Voice 2 for Spanish. Voice identifiers aren't public API and
    /// can vary by locale, so matching uses both the localized name and identifier.
    private static func preferredVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let preferredLanguage = Locale.preferredLanguages.first ?? "es-ES"
        let preferredCode = preferredLanguage.split(separator: "-").first.map(String.init) ?? "es"

        func matchesLanguage(_ voice: AVSpeechSynthesisVoice) -> Bool {
            voice.language == preferredLanguage || voice.language.hasPrefix(preferredCode + "-")
        }

        func isSiriVoice2(_ voice: AVSpeechSynthesisVoice) -> Bool {
            let searchable = "\(voice.name) \(voice.identifier)"
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .lowercased()
            return searchable.contains("siri")
                && (searchable.contains("voice 2") || searchable.contains("voz 2"))
        }

        if let siriVoice = voices.first(where: { matchesLanguage($0) && isSiriVoice2($0) })
            ?? voices.first(where: isSiriVoice2) {
            return siriVoice
        }

        let voicesForLanguage = voices.filter(matchesLanguage)
        return voicesForLanguage.first(where: { $0.quality == .premium })
            ?? voicesForLanguage.first(where: { $0.quality == .enhanced })
            ?? AVSpeechSynthesisVoice(language: preferredLanguage)
            ?? AVSpeechSynthesisVoice(language: "es-ES")
    }

    private static func speechRate(for multiplier: Double) -> Float {
        let requested = AVSpeechUtteranceDefaultSpeechRate * Float(multiplier)
        return min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, requested))
    }

    nonisolated private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private func settleUtteranceIfFinished() {
        guard !streamOpen, queue.isEmpty, pendingUtteranceCount == 0 else { return }
        isSpeaking = false
        isUtteranceActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            self?.isSpeaking = true
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let identifier = ObjectIdentifier(utterance)
        let spokenPrefixLength = min(characterRange.location + characterRange.length, utterance.speechString.utf16.count)
        let prefix = (utterance.speechString as NSString).substring(to: spokenPrefixLength)
        let wordsReached = Self.wordCount(prefix)

        Task { @MainActor [weak self] in
            guard let self, let progress = self.progressByUtterance[identifier] else { return }
            self.spokenWordCount = progress.startWord + min(progress.wordCount, wordsReached)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        let identifier = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            self?.completeUtterance(identifier: identifier, revealRemainingWords: true)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        let identifier = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            self?.completeUtterance(identifier: identifier, revealRemainingWords: false)
        }
    }

    private func completeUtterance(identifier: ObjectIdentifier, revealRemainingWords: Bool) {
        guard let progress = progressByUtterance.removeValue(forKey: identifier) else { return }
        pendingUtteranceCount = max(0, pendingUtteranceCount - 1)
        if revealRemainingWords {
            spokenWordCount = max(spokenWordCount, progress.startWord + progress.wordCount)
        }
        isSpeaking = synthesizer.isSpeaking
        settleUtteranceIfFinished()
    }

    private struct UtteranceProgress {
        let startWord: Int
        let wordCount: Int
    }
}
