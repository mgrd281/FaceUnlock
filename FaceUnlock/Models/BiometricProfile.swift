import Foundation

/// The enrolled representation of one person.
///
/// Deliberately minimal: no name, no account identifier, no imagery, no device
/// identifiers. Everything here is required either to match a face or to explain
/// to the user when and how the profile was made.
public struct BiometricProfile: Codable, Equatable, Sendable {
    public static let currentVersion = 2

    public var profileVersion: Int
    public var createdAt: Date
    public var updatedAt: Date
    /// One descriptor per accepted enrolment sample.
    public var embeddings: [FaceEmbedding]
    /// Which guided pose each embedding came from, parallel to `embeddings`.
    public var poseTags: [EnrollmentPose]
    /// The calibrated score a live frame must reach, in `0...1`.
    public var recognitionThreshold: Double
    /// Metric the threshold was calibrated against.
    public var metric: SimilarityMetric
    /// Liveness configuration captured at calibration time.
    public var livenessConfiguration: LivenessConfiguration
    /// Sensitivity preset in force when the threshold was calibrated.
    public var calibratedFor: SensitivityPreset

    public struct LivenessConfiguration: Codable, Equatable, Sendable {
        public var mode: LivenessMode
        public var minimumScore: Double
        public var windowFrames: Int

        public init(mode: LivenessMode, minimumScore: Double, windowFrames: Int) {
            self.mode = mode
            self.minimumScore = minimumScore
            self.windowFrames = windowFrames
        }

        public static let `default` = LivenessConfiguration(
            mode: .adaptiveChallenge,
            minimumScore: SensitivityPreset.balanced.livenessFloor,
            windowFrames: 12
        )
    }

    public init(
        profileVersion: Int = BiometricProfile.currentVersion,
        createdAt: Date,
        updatedAt: Date,
        embeddings: [FaceEmbedding],
        poseTags: [EnrollmentPose],
        recognitionThreshold: Double,
        metric: SimilarityMetric = .cosine,
        livenessConfiguration: LivenessConfiguration = .default,
        calibratedFor: SensitivityPreset = .balanced
    ) {
        self.profileVersion = profileVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.embeddings = embeddings
        self.poseTags = poseTags
        self.recognitionThreshold = recognitionThreshold
        self.metric = metric
        self.livenessConfiguration = livenessConfiguration
        self.calibratedFor = calibratedFor
    }

    /// Structural validation. A profile that fails this is treated as corrupted
    /// rather than silently matched against, because a truncated or tampered
    /// template could otherwise lower the effective threshold.
    public var isStructurallyValid: Bool {
        guard profileVersion > 0, profileVersion <= Self.currentVersion else { return false }
        guard !embeddings.isEmpty, embeddings.count == poseTags.count else { return false }
        guard recognitionThreshold.isFinite, recognitionThreshold > 0.5, recognitionThreshold <= 1 else { return false }
        guard let first = embeddings.first else { return false }
        guard first.dimension > 0 else { return false }
        return embeddings.allSatisfy { $0.isComparable(with: first) }
    }

    /// Non-sensitive summary for the Privacy and Diagnostics panes. Never includes
    /// any component of any descriptor.
    public var summary: Summary {
        Summary(
            createdAt: createdAt,
            updatedAt: updatedAt,
            sampleCount: embeddings.count,
            descriptorDimension: embeddings.first?.dimension ?? 0,
            producerVersion: embeddings.first?.producerVersion ?? "unknown",
            threshold: recognitionThreshold,
            posesCovered: Set(poseTags).count
        )
    }

    public struct Summary: Equatable, Sendable {
        public var createdAt: Date
        public var updatedAt: Date
        public var sampleCount: Int
        public var descriptorDimension: Int
        public var producerVersion: String
        public var threshold: Double
        public var posesCovered: Int
    }
}
