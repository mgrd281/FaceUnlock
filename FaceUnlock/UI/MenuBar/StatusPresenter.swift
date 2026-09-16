import SwiftUI

/// Translates `AppStatus` into everything the UI needs to show it.
///
/// Keeping this in one place means the icon, the status line and the VoiceOver
/// description can never disagree about what a state means.
public enum StatusPresenter {
    public static func headline(for status: AppStatus) -> String {
        switch status {
        case .notConfigured:
            return "Not set up yet"
        case let .permissionRequired(kind):
            return kind == .camera ? "Camera access needed" : "Accessibility access needed"
        case .cameraUnavailable:
            return "No camera available"
        case .ready:
            return "Ready — your face can unlock this Mac"
        case .monitoring:
            return "Looking for you…"
        case .faceDetected:
            return "Face detected"
        case .recognizing:
            return "Checking that it is you…"
        case .recognized:
            return "Recognised"
        case let .rejected(reason):
            switch reason {
            case .lowConfidence: return "Not confident enough — try again"
            case .livenessFailed: return "Could not confirm a live person"
            case .poorQuality: return "The camera view was not good enough"
            case .timedOut: return "Stopped looking"
            }
        case .unlockAttempt:
            return "Completing the unlock…"
        case .unlocked:
            return "Unlocked"
        case let .paused(until):
            guard let until, until < Date.distantFuture else { return "Paused" }
            return "Paused until \(until.formatted(date: .omitted, time: .shortened))"
        case let .error(error):
            return error.message
        }
    }

    public static func symbolName(for status: AppStatus) -> String {
        switch status {
        case .notConfigured: return "person.crop.circle.badge.questionmark"
        case .permissionRequired: return "lock.shield"
        case .cameraUnavailable: return "video.slash"
        case .ready: return "faceid"
        case .monitoring, .faceDetected: return "viewfinder"
        case .recognizing: return "viewfinder.circle"
        case .recognized, .unlocked: return "checkmark.circle"
        case .rejected: return "exclamationmark.circle"
        case .unlockAttempt: return "lock.open"
        case .paused: return "pause.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    public static func tint(for status: AppStatus) -> Color {
        switch status {
        case .recognized, .unlocked: return .green
        case .rejected, .error: return .orange
        case .permissionRequired, .cameraUnavailable: return .red
        case .paused: return .secondary
        default: return .primary
        }
    }

    /// A complete sentence for VoiceOver, including the reason where one exists.
    public static func accessibilityDescription(for status: AppStatus) -> String {
        "FaceUnlock: \(headline(for: status))"
    }
}
