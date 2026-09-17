import Foundation

/// User-selectable strictness. Raw thresholds are deliberately not exposed: an
/// arbitrary slider makes it trivial to configure an unsafe false-accept rate.
public enum SensitivityPreset: String, Codable, CaseIterable, Sendable, Identifiable {
    case strict
    case balanced
    case convenient

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .strict: return "Strict"
        case .balanced: return "Balanced"
        case .convenient: return "Convenient"
        }
    }

    public var summary: String {
        switch self {
        case .strict:
            return "Fewest false accepts. Expect to be asked to try again more often."
        case .balanced:
            return "The recommended trade-off between security and speed."
        case .convenient:
            return "Faster recognition in good light. Still refuses uncertain matches."
        }
    }

    /// Absolute floor for the match score, independent of calibration. Calibration
    /// may raise the threshold but never lower it below this value.
    ///
    /// The floor depends on which descriptor produced the scores, because the two
    /// pipelines live on different scales. Scores are `(cosine + 1) / 2`:
    ///
    /// - The Vision feature-print descriptor is a general image descriptor, so
    ///   even unrelated faces score high (impostors ≈ 0.80–0.86, the same person
    ///   ≈ 0.90–0.97). Its floors therefore sit at 0.84 and above.
    /// - The bundled FaceNet-style network is metric-learned for identity: the
    ///   same person typically lands at cosine 0.6–0.85 (score 0.80–0.93) and a
    ///   different person at cosine −0.1–0.35 (score 0.45–0.68). The published
    ///   VGGFace2 operating point (L2 distance 1.1 ≈ cosine 0.40 ≈ score 0.70)
    ///   is the *convenient* floor; *balanced* and *strict* sit well above it.
    public func scoreFloor(for source: FaceEmbedding.Source) -> Double {
        switch source {
        case .coreMLModel:
            switch self {
            case .strict: return 0.80
            case .balanced: return 0.75
            case .convenient: return 0.71
            }
        case .visionFeaturePrint, .synthetic:
            switch self {
            case .strict: return 0.92
            case .balanced: return 0.88
            case .convenient: return 0.84
            }
        }
    }

    /// How far above `scoreFloor(for:)` calibration may push the threshold.
    ///
    /// Calibration samples are captured in one sitting, seconds apart, in one
    /// lighting condition — so their spread measures frame-to-frame noise, not
    /// the day-to-day variation the user will actually present. Left uncapped,
    /// a metric-learned descriptor happily calibrates to 0.97 (the same face,
    /// same light, same second) and then refuses the same person tomorrow in a
    /// different room. The cap keeps the calibrated threshold in the band where
    /// genuine scores still land under changed conditions, while remaining far
    /// above the impostor band.
    public func maximumCalibrationLift(for source: FaceEmbedding.Source) -> Double {
        switch source {
        case .coreMLModel: return 0.06
        case .visionFeaturePrint, .synthetic: return 0.04
        }
    }

    /// Consecutive accepted frames required before an unlock is attempted.
    public var requiredConsecutiveMatches: Int {
        switch self {
        case .strict: return 6
        case .balanced: return 4
        case .convenient: return 3
        }
    }

    /// Minimum liveness risk score (0...1, higher is more likely live).
    public var livenessFloor: Double {
        switch self {
        case .strict: return 0.75
        case .balanced: return 0.62
        case .convenient: return 0.52
        }
    }

    /// Standard deviations below the enrolment mean the calibrated threshold may sit.
    public var calibrationSigma: Double {
        switch self {
        case .strict: return 1.0
        case .balanced: return 1.5
        case .convenient: return 2.0
        }
    }
}

/// How hard FaceUnlock works to prove a live person is present.
public enum LivenessMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Passive multi-frame analysis only.
    case passive
    /// Passive analysis, plus an explicit prompt when the passive score is marginal.
    case adaptiveChallenge
    /// Always ask for a blink or a small head turn before unlocking.
    case alwaysChallenge

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .passive: return "Passive"
        case .adaptiveChallenge: return "Passive, with challenge when unsure"
        case .alwaysChallenge: return "Always challenge"
        }
    }

    public var summary: String {
        switch self {
        case .passive:
            return "Analyses movement, blinking and texture across several frames. Fastest."
        case .adaptiveChallenge:
            return "Adds a short blink or head-turn prompt only when the passive score is marginal."
        case .alwaysChallenge:
            return "Always asks you to blink or turn your head. Slowest, hardest to spoof."
        }
    }
}

/// Non-secret recognition tuning that is safe to keep in `UserDefaults`.
public struct RecognitionSettings: Codable, Equatable, Sendable {
    public var sensitivity: SensitivityPreset
    public var livenessMode: LivenessMode
    /// How long one recognition attempt may run before it gives up, in seconds.
    public var attemptTimeout: TimeInterval
    /// Delay after the screen locks before the camera is started, in seconds.
    public var startDelayAfterLock: TimeInterval
    /// Frames per second handed to the recognition pipeline.
    public var processingFrameRate: Double

    public static let `default` = RecognitionSettings(
        sensitivity: .balanced,
        livenessMode: .adaptiveChallenge,
        attemptTimeout: 15,
        startDelayAfterLock: 1.5,
        processingFrameRate: 6
    )

    public init(
        sensitivity: SensitivityPreset,
        livenessMode: LivenessMode,
        attemptTimeout: TimeInterval,
        startDelayAfterLock: TimeInterval,
        processingFrameRate: Double
    ) {
        self.sensitivity = sensitivity
        self.livenessMode = livenessMode
        self.attemptTimeout = attemptTimeout
        self.startDelayAfterLock = startDelayAfterLock
        self.processingFrameRate = processingFrameRate
    }

    /// Clamps values to ranges the pipeline is known to behave well in. Applied on
    /// load so a hand-edited preferences file cannot widen the security envelope.
    public func sanitized() -> RecognitionSettings {
        var copy = self
        copy.attemptTimeout = min(30, max(5, attemptTimeout))
        copy.startDelayAfterLock = min(10, max(0, startDelayAfterLock))
        copy.processingFrameRate = min(15, max(2, processingFrameRate))
        return copy
    }
}
