import AVFoundation
import UIKit

/// Asks for camera and microphone access the first time the app opens.
///
/// Without this the first tap on the camera button is what triggers the system
/// prompt, which reads like a random interruption. Asking up front, in context,
/// is both friendlier and required before background audio can be configured.
@MainActor
enum PermissionPrimer {
    private static let askedKey = "makima.permissionsAsked"

    /// Request microphone always; request camera too, since attaching a photo is a
    /// core part of talking to Makima.
    static func requestEssentialsIfNeeded() {
        let defaults = UserDefaults.standard
        let alreadyAsked = defaults.bool(forKey: askedKey)

        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined || !alreadyAsked {
            AVCaptureDevice.requestAccess(for: .video) { _ in }
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined || !alreadyAsked {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        if !alreadyAsked {
            defaults.set(true, forKey: askedKey)
        }
    }
}
