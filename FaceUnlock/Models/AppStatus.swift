import Foundation

/// The single source of truth for what FaceUnlock is currently doing.
///
/// The menu-bar icon, the status line and the optional recognition animation are
/// all derived from this value, so there is exactly one place where meaning is
/// assigned to a state.
public enum AppStatus: Equatable, Sendable {
    /// No biometric profile exists yet.
    case notConfigured
    /// A required permission (camera, and optionally Accessibility) is missing.
    case permissionRequired(PermissionKind)
    /// A profile exists and permissions are granted, but no camera is usable.
    case cameraUnavailable
    /// Idle and armed: waiting for a lock event.
    case ready
    /// The camera is running and frames are being searched for a face.
    case monitoring
    /// A face is in frame but has not been analyzed yet.
    case faceDetected
    /// Embeddings are being compared and liveness is being scored.
    case recognizing(progress: Double)
    /// The enrolled user was recognized with sufficient confidence and liveness.
    case recognized
    /// A face was analyzed and rejected.
    case rejected(RejectionReason)
    /// An unlock attempt is executing.
    case unlockAttempt
    /// The session was unlocked after a successful attempt.
    case unlocked
    /// The user paused FaceUnlock (indefinitely or until a date).
    case paused(until: Date?)
    /// A recoverable error is being surfaced.
    case error(FaceUnlockError)

    public enum PermissionKind: String, Equatable, Sendable {
        case camera
        case accessibility
    }

    public enum RejectionReason: String, Equatable, Sendable {
        case lowConfidence
        case livenessFailed
        case poorQuality
        case timedOut
    }

    /// Whether the recognition pipeline is actively consuming camera frames.
    public var isActive: Bool {
        switch self {
        case .monitoring, .faceDetected, .recognizing, .recognized, .unlockAttempt:
            return true
        default:
            return false
        }
    }

    /// Stable identifier used for logging and diagnostics. Carries no user data.
    public var identifier: String {
        switch self {
        case .notConfigured: return "notConfigured"
        case let .permissionRequired(kind): return "permissionRequired.\(kind.rawValue)"
        case .cameraUnavailable: return "cameraUnavailable"
        case .ready: return "ready"
        case .monitoring: return "monitoring"
        case .faceDetected: return "faceDetected"
        case .recognizing: return "recognizing"
        case .recognized: return "recognized"
        case let .rejected(reason): return "rejected.\(reason.rawValue)"
        case .unlockAttempt: return "unlockAttempt"
        case .unlocked: return "unlocked"
        case .paused: return "paused"
        case let .error(error): return "error.\(error.code)"
        }
    }
}
