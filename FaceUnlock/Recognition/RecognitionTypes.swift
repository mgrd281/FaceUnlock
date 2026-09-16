import Foundation

/// What a recognition attempt was for.
public enum RecognitionPurpose: String, Equatable, Sendable {
    /// Triggered by a session lock; a successful result leads to an unlock attempt.
    case unlock
    /// Started from the UI; never triggers an unlock.
    case test
}

/// The result of one complete attempt.
public struct RecognitionAttemptResult: Equatable, Sendable {
    public enum Verdict: Equatable, Sendable {
        case recognized
        case rejected(AppStatus.RejectionReason)
        case failed(FaceUnlockError)
    }

    public var verdict: Verdict
    public var bestScore: Double
    public var threshold: Double
    public var livenessScore: Double
    public var framesProcessed: Int
    public var duration: TimeInterval
    public var unlockOutcome: UnlockOutcome?

    public var succeeded: Bool {
        if case .recognized = verdict { return true }
        return false
    }
}

/// Live feedback emitted while an attempt runs, for the recognition animation and
/// the test window.
///
/// `@unchecked Sendable` because of the optional `PreviewImage`, which wraps an
/// immutable `CGImage`. A preview is only ever attached for `RecognitionPurpose.test`;
/// an unlock attempt never renders a frame.
public struct RecognitionProgress: @unchecked Sendable {
    public var status: AppStatus
    public var matchScore: Double?
    public var threshold: Double?
    public var livenessScore: Double?
    public var qualityIssues: [FaceQualityIssue]
    public var activeChallenge: LivenessChallenge?
    public var consecutiveMatches: Int
    public var requiredMatches: Int
    public var preview: PreviewImage?

    public init(
        status: AppStatus,
        matchScore: Double? = nil,
        threshold: Double? = nil,
        livenessScore: Double? = nil,
        qualityIssues: [FaceQualityIssue] = [],
        activeChallenge: LivenessChallenge? = nil,
        consecutiveMatches: Int = 0,
        requiredMatches: Int = 0,
        preview: PreviewImage? = nil
    ) {
        self.status = status
        self.matchScore = matchScore
        self.threshold = threshold
        self.livenessScore = livenessScore
        self.qualityIssues = qualityIssues
        self.activeChallenge = activeChallenge
        self.consecutiveMatches = consecutiveMatches
        self.requiredMatches = requiredMatches
        self.preview = preview
    }
}

/// Rolling, non-sensitive statistics shown in Diagnostics.
public struct RecognitionStatistics: Equatable, Sendable {
    public var lastResultDescription: String?
    public var lastResultAt: Date?
    public var lastErrorDescription: String?
    public var lastErrorAt: Date?
    public var averageLatency: TimeInterval?
    public var attemptCount: Int = 0
    public var successCount: Int = 0

    public init() {}

    public var successRateDescription: String {
        guard attemptCount > 0 else { return "No attempts yet" }
        let percentage = Double(successCount) / Double(attemptCount) * 100
        return String(format: "%d of %d (%.0f%%)", successCount, attemptCount, percentage)
    }
}
