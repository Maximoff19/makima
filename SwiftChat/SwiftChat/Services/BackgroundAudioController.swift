import AVFoundation
import UIKit

/// Keeps the audio session alive so Makima's voice is not cut the moment the
/// app leaves the foreground. iOS suspends and mutes audio by default when the
/// screen locks or the user swipes up, which is why this has to be explicit.
@MainActor
final class BackgroundAudioController {
    static let shared = BackgroundAudioController()

    private var session: AVAudioSession?

    private init() {}

    func refresh() {
        let enabled = UserDefaults.standard.object(forKey: "makima.backgroundAudio") as? Bool ?? true
        configure(enabled: enabled)
    }

    func configure(enabled: Bool) {
        let session = AVAudioSession.sharedInstance()
        self.session = session
        do {
            if enabled {
                // .playback keeps audio running when the ringer switch is silenced,
                // which is the whole point: Makima keeps talking.
                try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                try session.setActive(true)
                UIApplication.shared.beginReceivingRemoteControlEvents()
            } else {
                try session.setActive(false, options: .notifyOthersOnDeactivation)
            }
        } catch {
            // Audio session configuration can legitimately fail (for example during
            // a phone call). Never crash the chat over it.
            NSLog("BackgroundAudioController: \(error.localizedDescription)")
        }
    }
}
