import Foundation

/// The outcome of comparing one live descriptor against an enrolled profile.
public struct MatchResult: Equatable, Sendable {
    /// Aggregated similarity in `0...1`, larger is more similar.
    public let score: Double
    /// The threshold the score was judged against.
    public let threshold: Double
    /// Highest single-sample similarity, kept for diagnostics.
    public let bestSampleScore: Double
    /// Which enrolment pose produced `bestSampleScore`.
    public let bestPose: EnrollmentPose?

    public var isMatch: Bool { score >= threshold }
    /// How far above (positive) or below (negative) the threshold the score landed.
    public var margin: Double { score - threshold }

    public init(score: Double, threshold: Double, bestSampleScore: Double, bestPose: EnrollmentPose?) {
        self.score = score
        self.threshold = threshold
        self.bestSampleScore = bestSampleScore
        self.bestPose = bestPose
    }

    public static let noMatch = MatchResult(score: 0, threshold: 1, bestSampleScore: 0, bestPose: nil)
}

public protocol FaceMatching: Sendable {
    func match(_ embedding: FaceEmbedding, against profile: BiometricProfile) -> MatchResult
}

/// Compares a live descriptor against every enrolled sample.
///
/// Aggregation is the mean of the best `k` similarities rather than the single
/// best. Using only the maximum makes one lucky frame — or one over-general
/// enrolment sample — sufficient to authenticate, which is exactly the failure
/// mode a face unlock must not have. Averaging the top few keeps pose coverage
/// useful while requiring agreement from more than one sample.
public struct FaceMatcher: FaceMatching {
    /// How many of the best per-sample scores are averaged.
    public let topK: Int

    public init(topK: Int = 3) {
        self.topK = max(1, topK)
    }

    public func match(_ embedding: FaceEmbedding, against profile: BiometricProfile) -> MatchResult {
        guard profile.isStructurallyValid else { return .noMatch }
        guard let reference = profile.embeddings.first,
              embedding.isComparable(with: reference) else {
            // A descriptor produced by a different pipeline version must never be
            // scored against this profile — mismatched vectors would produce a
            // meaningless number rather than an honest rejection.
            AppLogger.recognition.error("Descriptor is not comparable with the stored profile")
            return MatchResult(score: 0, threshold: profile.recognitionThreshold, bestSampleScore: 0, bestPose: nil)
        }

        let metric = profile.metric
        var scored: [(score: Double, pose: EnrollmentPose?)] = []
        scored.reserveCapacity(profile.embeddings.count)
        for (index, candidate) in profile.embeddings.enumerated() {
            let score = metric.score(embedding, candidate)
            scored.append((score, index < profile.poseTags.count ? profile.poseTags[index] : nil))
        }

        let sorted = scored.sorted { $0.score > $1.score }
        let considered = Array(sorted.prefix(min(topK, sorted.count)))
        let aggregate = ImageAnalysis.mean(considered.map(\.score))

        return MatchResult(
            score: aggregate,
            threshold: profile.effectiveThreshold(for: embedding.source),
            bestSampleScore: sorted.first?.score ?? 0,
            bestPose: sorted.first?.pose
        )
    }
}

/// Derives a per-user recognition threshold from calibration samples.
///
/// The rule is deliberately conservative: the calibrated threshold is
/// `mean − sigma × stddev` of the genuine scores observed during calibration, but
/// it is never allowed below the preset's own floor. Calibration can therefore
/// only ever make FaceUnlock *stricter* than the preset, never more permissive —
/// a user in unusually poor conditions cannot calibrate themselves into a weak
/// configuration.
///
/// It is also not allowed to make FaceUnlock *arbitrarily* stricter. Calibration
/// measures one sitting, so its spread understates real variation; the lift above
/// the floor is capped by `SensitivityPreset.maximumCalibrationLift(for:)`.
public enum ThresholdCalibrator {
    /// Fewer than this many genuine samples is not enough to estimate a spread.
    public static let minimumSamples = 8
    /// Hard ceiling: a threshold this high would reject the enrolled user too.
    public static let maximumThreshold = 0.985

    public struct Outcome: Equatable, Sendable {
        public var threshold: Double
        public var meanScore: Double
        public var standardDeviation: Double
        public var sampleCount: Int
        /// True when the floor, rather than the measurement, decided the threshold.
        public var clampedToFloor: Bool
    }

    public static func calibrate(
        genuineScores: [Double],
        preset: SensitivityPreset,
        source: FaceEmbedding.Source
    ) -> Outcome {
        let floor = preset.scoreFloor(for: source)
        guard genuineScores.count >= minimumSamples else {
            return Outcome(
                threshold: floor,
                meanScore: ImageAnalysis.mean(genuineScores),
                standardDeviation: ImageAnalysis.standardDeviation(genuineScores),
                sampleCount: genuineScores.count,
                clampedToFloor: true
            )
        }
        let mean = ImageAnalysis.mean(genuineScores)
        let deviation = ImageAnalysis.standardDeviation(genuineScores)
        let measured = mean - preset.calibrationSigma * deviation
        // The lift cap matters more than the absolute ceiling here: see
        // `SensitivityPreset.maximumCalibrationLift(for:)`.
        let ceiling = min(maximumThreshold, floor + preset.maximumCalibrationLift(for: source))
        let threshold = min(ceiling, max(floor, measured))
        return Outcome(
            threshold: threshold,
            meanScore: mean,
            standardDeviation: deviation,
            sampleCount: genuineScores.count,
            clampedToFloor: threshold <= floor
        )
    }
}
