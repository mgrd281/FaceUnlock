import Foundation

/// User-facing error domain.
///
/// Every case carries a short, human-readable sentence. Raw `OSStatus` values and
/// other technical detail stay in `technicalDetail`, which is only surfaced in the
/// Diagnostics pane — never in the ordinary UI.
public enum FaceUnlockError: Error, Equatable, Sendable {
    case cameraPermissionDenied
    case cameraUnavailable
    case cameraBusy
    case cameraStartFailed(String)
    case accessibilityPermissionRequired
    case noEnrolledProfile
    case profileCorrupted
    /// The stored profile was enrolled with a different descriptor pipeline
    /// (for example before the Core ML model was added). It is intact but can
    /// never be scored, so it has to be set up again.
    case profileIncompatible(stored: String, active: String)
    case enrollmentIncomplete(capturedSamples: Int, requiredSamples: Int)
    case enrollmentQualityTooLow(String)
    case recognitionConfidenceTooLow(score: Double, threshold: Double)
    case livenessFailed(reason: String)
    case unlockUnavailableOnThisSystem
    case unlockVerificationFailed(String)
    case unlockAlreadyInProgress
    case timedOut
    case keychainFailure(status: Int32)
    case credentialMissing
    case credentialValidationFailed
    case localAuthenticationFailed(String)
    case loginItemRegistrationFailed(String)
    case embeddingFailed(String)
    case cancelled

    /// A complete, plain sentence suitable for direct presentation.
    public var message: String {
        switch self {
        case .cameraPermissionDenied:
            return "Camera access is disabled. FaceUnlock needs the camera to recognize you."
        case .cameraUnavailable:
            return "No usable camera was found on this Mac."
        case .cameraBusy:
            return "The camera is currently being used by another application."
        case .cameraStartFailed:
            return "The camera could not be started."
        case .accessibilityPermissionRequired:
            return "Accessibility permission is required for this action."
        case .noEnrolledProfile:
            return "No face is set up yet. Run the setup assistant to enroll your face."
        case .profileCorrupted:
            return "The stored face profile could not be read and has to be set up again."
        case .profileIncompatible:
            return "The recognition engine was updated. Your face has to be set up again."
        case let .enrollmentIncomplete(captured, required):
            return "Setup is not finished — \(captured) of \(required) samples were captured."
        case let .enrollmentQualityTooLow(reason):
            return "The captured samples were not good enough: \(reason)"
        case .recognitionConfidenceTooLow:
            return "Your face was detected but recognition confidence was too low."
        case let .livenessFailed(reason):
            return "Liveness verification failed: \(reason)"
        case .unlockUnavailableOnThisSystem:
            return "Unlock interaction is unavailable on this version of macOS."
        case let .unlockVerificationFailed(detail):
            return "The unlock was stopped because the screen could not be verified: \(detail)"
        case .unlockAlreadyInProgress:
            return "An unlock attempt is already running."
        case .timedOut:
            return "FaceUnlock stopped looking for your face because it took too long."
        case .keychainFailure:
            return "Secure storage could not be reached."
        case .credentialMissing:
            return "No password is saved for FaceUnlock."
        case .credentialValidationFailed:
            return "That password does not match your macOS account password."
        case let .localAuthenticationFailed(detail):
            return "Authentication was not completed: \(detail)"
        case .loginItemRegistrationFailed:
            return "FaceUnlock could not be registered to open at login."
        case .embeddingFailed:
            return "The face could not be analyzed."
        case .cancelled:
            return "The operation was cancelled."
        }
    }

    /// A short, actionable suggestion, when one exists.
    public var recoverySuggestion: String? {
        switch self {
        case .cameraPermissionDenied:
            return "Open System Settings › Privacy & Security › Camera and enable FaceUnlock."
        case .accessibilityPermissionRequired:
            return "Open System Settings › Privacy & Security › Accessibility and enable FaceUnlock."
        case .cameraBusy:
            return "Quit the other app that is using the camera, then try again."
        case .noEnrolledProfile, .profileCorrupted, .profileIncompatible, .enrollmentIncomplete, .enrollmentQualityTooLow:
            return "Open the setup assistant to set up your face again."
        case .recognitionConfidenceTooLow, .livenessFailed:
            return "Face the camera directly in even lighting and try again."
        case .unlockUnavailableOnThisSystem:
            return "See Known Limitations for the workflows that are supported on this Mac."
        case .credentialValidationFailed:
            return "Check the password for your macOS account and try again."
        default:
            return nil
        }
    }

    /// Non-sensitive technical context for the Diagnostics pane and log export.
    public var technicalDetail: String? {
        switch self {
        case let .cameraStartFailed(detail): return detail
        case let .unlockVerificationFailed(detail): return detail
        case let .keychainFailure(status): return "OSStatus \(status)"
        case let .embeddingFailed(detail): return detail
        case let .localAuthenticationFailed(detail): return detail
        case let .loginItemRegistrationFailed(detail): return detail
        case let .recognitionConfidenceTooLow(score, threshold):
            return String(format: "score %.4f < threshold %.4f", score, threshold)
        case let .livenessFailed(reason): return reason
        case let .enrollmentQualityTooLow(reason): return reason
        case let .profileIncompatible(stored, active):
            return "profile producer \(stored), active producer \(active)"
        default: return nil
        }
    }

    /// Short identifier used in logs. Contains no user data.
    public var code: String {
        switch self {
        case .cameraPermissionDenied: return "camera.permission"
        case .cameraUnavailable: return "camera.unavailable"
        case .cameraBusy: return "camera.busy"
        case .cameraStartFailed: return "camera.start"
        case .accessibilityPermissionRequired: return "permission.accessibility"
        case .noEnrolledProfile: return "profile.missing"
        case .profileCorrupted: return "profile.corrupt"
        case .profileIncompatible: return "profile.incompatible"
        case .enrollmentIncomplete: return "enroll.incomplete"
        case .enrollmentQualityTooLow: return "enroll.quality"
        case .recognitionConfidenceTooLow: return "recognition.low"
        case .livenessFailed: return "liveness.failed"
        case .unlockUnavailableOnThisSystem: return "unlock.unsupported"
        case .unlockVerificationFailed: return "unlock.verification"
        case .unlockAlreadyInProgress: return "unlock.busy"
        case .timedOut: return "timeout"
        case .keychainFailure: return "keychain.failure"
        case .credentialMissing: return "credential.missing"
        case .credentialValidationFailed: return "credential.invalid"
        case .localAuthenticationFailed: return "localauth.failed"
        case .loginItemRegistrationFailed: return "loginitem.failed"
        case .embeddingFailed: return "embedding.failed"
        case .cancelled: return "cancelled"
        }
    }
}

extension FaceUnlockError: LocalizedError {
    public var errorDescription: String? { message }
}
