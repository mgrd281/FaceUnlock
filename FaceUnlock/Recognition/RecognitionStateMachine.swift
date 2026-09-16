import Foundation

/// Everything that can move FaceUnlock from one state to another.
public enum RecognitionEvent: Equatable, Sendable {
    case profileBecameAvailable
    case profileRemoved
    case permissionLost(AppStatus.PermissionKind)
    case permissionsSatisfied
    case cameraBecameUnavailable
    case armed
    case attemptStarted
    case faceSeen
    case frameEvaluated(progress: Double)
    case matchConfirmed
    case rejected(AppStatus.RejectionReason)
    case unlockStarted
    case unlockSucceeded
    case failed(FaceUnlockError)
    case attemptFinished
    case paused(until: Date?)
    case resumed
}

/// The transition rules, kept as a value type with no dependencies so the whole
/// state graph can be exercised in tests without a camera, a lock screen or a
/// running app.
///
/// Guarding rules encoded here:
/// * `paused` absorbs everything except `resumed` and the configuration events
///   that would make resuming pointless.
/// * A missing profile or permission outranks any activity state: FaceUnlock can
///   never appear to be "monitoring" when it has nothing to match against.
/// * `unlocked` and `rejected` are terminal for one attempt and are cleared by
///   `attemptFinished`.
public struct RecognitionStateMachine: Sendable {
    public private(set) var status: AppStatus
    /// Whether the prerequisites for arming are currently met.
    private var hasProfile: Bool
    private var missingPermission: AppStatus.PermissionKind?
    private var cameraAvailable: Bool
    private var pausedUntil: Date?

    public init(
        hasProfile: Bool = false,
        missingPermission: AppStatus.PermissionKind? = nil,
        cameraAvailable: Bool = true
    ) {
        self.hasProfile = hasProfile
        self.missingPermission = missingPermission
        self.cameraAvailable = cameraAvailable
        self.pausedUntil = nil
        self.status = .notConfigured
        self.status = Self.restingStatus(
            hasProfile: hasProfile,
            missingPermission: missingPermission,
            cameraAvailable: cameraAvailable,
            pausedUntil: nil
        )
    }

    /// Applies an event. Returns `true` when the visible status changed.
    @discardableResult
    public mutating func apply(_ event: RecognitionEvent) -> Bool {
        let previous = status

        switch event {
        case .profileBecameAvailable:
            hasProfile = true
            settle()
        case .profileRemoved:
            hasProfile = false
            settle()
        case let .permissionLost(kind):
            missingPermission = kind
            settle()
        case .permissionsSatisfied:
            missingPermission = nil
            settle()
        case .cameraBecameUnavailable:
            cameraAvailable = false
            settle()
        case .armed:
            cameraAvailable = true
            settle()
        case let .paused(until):
            pausedUntil = until ?? Date.distantFuture
            status = .paused(until: pausedUntil)
        case .resumed:
            pausedUntil = nil
            settle()

        case .attemptStarted:
            guard canRun else { break }
            status = .monitoring
        case .faceSeen:
            guard canRun, status.isActive || status == .ready else { break }
            status = .faceDetected
        case let .frameEvaluated(progress):
            guard canRun, status.isActive else { break }
            status = .recognizing(progress: min(1, max(0, progress)))
        case .matchConfirmed:
            guard canRun, status.isActive else { break }
            status = .recognized
        case let .rejected(reason):
            guard canRun else { break }
            status = .rejected(reason)
        case .unlockStarted:
            guard canRun, status == .recognized else { break }
            status = .unlockAttempt
        case .unlockSucceeded:
            guard canRun else { break }
            status = .unlocked
        case let .failed(error):
            guard canRun else { break }
            status = .error(error)
        case .attemptFinished:
            settle()
        }

        return status != previous
    }

    /// True when nothing structural is blocking recognition.
    private var canRun: Bool {
        !isPaused && hasProfile && missingPermission == nil && cameraAvailable
    }

    private var isPaused: Bool {
        guard let pausedUntil else { return false }
        return pausedUntil > Date()
    }

    private mutating func settle() {
        if let pausedUntil, pausedUntil <= Date() { self.pausedUntil = nil }
        status = Self.restingStatus(
            hasProfile: hasProfile,
            missingPermission: missingPermission,
            cameraAvailable: cameraAvailable,
            pausedUntil: pausedUntil
        )
    }

    private static func restingStatus(
        hasProfile: Bool,
        missingPermission: AppStatus.PermissionKind?,
        cameraAvailable: Bool,
        pausedUntil: Date?
    ) -> AppStatus {
        if let pausedUntil, pausedUntil > Date() { return .paused(until: pausedUntil) }
        if let missingPermission { return .permissionRequired(missingPermission) }
        if !hasProfile { return .notConfigured }
        if !cameraAvailable { return .cameraUnavailable }
        return .ready
    }
}
