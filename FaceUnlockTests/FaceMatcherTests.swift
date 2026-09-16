import XCTest
@testable import FaceUnlock

final class FaceMatcherTests: XCTestCase {
    func testIdenticalEmbeddingScoresAtTheTop() {
        let base = Fake.embedding(seed: 1)
        let profile = Fake.profile(embeddings: [base, base, base])
        let result = FaceMatcher().match(base, against: profile)
        XCTAssertEqual(result.score, 1.0, accuracy: 1e-6)
        XCTAssertTrue(result.isMatch)
        XCTAssertGreaterThan(result.margin, 0)
    }

    func testUnrelatedEmbeddingIsRejected() {
        let enrolled = (1...5).map { Fake.embedding(seed: UInt64($0)) }
        let profile = Fake.profile(embeddings: enrolled)
        let stranger = Fake.embedding(seed: 9_999)
        let result = FaceMatcher().match(stranger, against: profile)
        XCTAssertFalse(result.isMatch)
        XCTAssertLessThan(result.score, profile.recognitionThreshold)
    }

    func testSmallAngleVariationStillMatches() {
        let base = Fake.embedding(seed: 3)
        let enrolled = (0..<4).map { Fake.embedding(near: base, angle: 0.08, seed: UInt64(100 + $0)) }
        let profile = Fake.profile(embeddings: enrolled, threshold: 0.95)
        let live = Fake.embedding(near: base, angle: 0.10, seed: 500)
        let result = FaceMatcher().match(live, against: profile)
        XCTAssertTrue(result.isMatch, "score \(result.score) should clear \(result.threshold)")
    }

    /// One over-general enrolment sample must not be able to authenticate on its
    /// own — this is the reason the matcher averages the best `k` rather than
    /// taking the maximum.
    func testASingleCloseSampleIsNotEnough() {
        let base = Fake.embedding(seed: 11)
        let outlier = Fake.embedding(seed: 12)
        let enrolled = [outlier] + (0..<4).map { Fake.embedding(near: base, angle: 0.9, seed: UInt64(200 + $0)) }
        let profile = Fake.profile(embeddings: enrolled, threshold: 0.9)

        let topKResult = FaceMatcher(topK: 3).match(outlier, against: profile)
        let maxOnlyResult = FaceMatcher(topK: 1).match(outlier, against: profile)

        XCTAssertTrue(maxOnlyResult.isMatch, "the single best score alone would accept")
        XCTAssertFalse(topKResult.isMatch, "averaging the best three must not accept")
    }

    func testDescriptorFromADifferentProducerIsNeverScored() {
        let enrolled = (1...3).map { Fake.embedding(seed: UInt64($0)) }
        let profile = Fake.profile(embeddings: enrolled)
        let foreign = FaceEmbedding(
            source: .visionFeaturePrint,
            producerVersion: "something.else",
            values: enrolled[0].values
        )
        let result = FaceMatcher().match(foreign, against: profile)
        XCTAssertEqual(result.score, 0)
        XCTAssertFalse(result.isMatch)
    }

    func testDimensionMismatchIsNotComparable() {
        let a = Fake.embedding(seed: 1, dimension: 64)
        let b = Fake.embedding(seed: 1, dimension: 32)
        XCTAssertFalse(a.isComparable(with: b))
        XCTAssertEqual(a.cosineSimilarity(to: b), -1)
    }

    func testStructurallyInvalidProfileNeverMatches() {
        let profile = BiometricProfile(
            createdAt: Date(), updatedAt: Date(),
            embeddings: [], poseTags: [],
            recognitionThreshold: 0.9
        )
        XCTAssertFalse(profile.isStructurallyValid)
        XCTAssertFalse(FaceMatcher().match(Fake.embedding(seed: 1), against: profile).isMatch)
    }

    func testMetricsAgreeOnOrdering() {
        let base = Fake.embedding(seed: 5)
        let near = Fake.embedding(near: base, angle: 0.1, seed: 1)
        let far = Fake.embedding(near: base, angle: 1.0, seed: 1)
        for metric in SimilarityMetric.allCases {
            XCTAssertGreaterThan(
                metric.score(base, near), metric.score(base, far),
                "\(metric) should rank the nearer vector higher"
            )
        }
    }

    // MARK: Calibration

    func testCalibrationNeverGoesBelowThePresetFloor() {
        // Wildly inconsistent scores would push mean - sigma*sd very low.
        let scores = [0.99, 0.5, 0.99, 0.4, 0.98, 0.45, 0.97, 0.42, 0.96, 0.5]
        for preset in SensitivityPreset.allCases {
            let outcome = ThresholdCalibrator.calibrate(genuineScores: scores, preset: preset, source: .synthetic)
            XCTAssertGreaterThanOrEqual(outcome.threshold, preset.scoreFloor(for: .synthetic))
            XCTAssertTrue(outcome.clampedToFloor)
        }
    }

    func testTightlyClusteredScoresRaiseTheThreshold() {
        let scores = Array(repeating: 0.985, count: 12)
        let outcome = ThresholdCalibrator.calibrate(genuineScores: scores, preset: .balanced, source: .synthetic)
        XCTAssertGreaterThan(outcome.threshold, SensitivityPreset.balanced.scoreFloor(for: .synthetic))
        XCTAssertLessThanOrEqual(outcome.threshold, ThresholdCalibrator.maximumThreshold)
        XCTAssertFalse(outcome.clampedToFloor)
    }

    /// The metric-learned model scores on a lower scale, so its floors are lower
    /// in absolute terms — but they must still sit well above the published
    /// impostor operating point (score ≈ 0.70) and never above the Vision floors.
    func testCoreMLFloorsAreLowerButStillAboveTheImpostorBand() {
        for preset in SensitivityPreset.allCases {
            let coreML = preset.scoreFloor(for: .coreMLModel)
            let vision = preset.scoreFloor(for: .visionFeaturePrint)
            XCTAssertGreaterThanOrEqual(coreML, 0.70, "\(preset) floor is inside the impostor band")
            XCTAssertLessThan(coreML, vision)
        }
        let scores = Array(repeating: 0.86, count: 12)
        let outcome = ThresholdCalibrator.calibrate(genuineScores: scores, preset: .balanced, source: .coreMLModel)
        XCTAssertGreaterThan(outcome.threshold, SensitivityPreset.balanced.scoreFloor(for: .coreMLModel))
        XCTAssertLessThanOrEqual(outcome.threshold, ThresholdCalibrator.maximumThreshold)
    }

    func testTooFewSamplesFallsBackToTheFloor() {
        let outcome = ThresholdCalibrator.calibrate(genuineScores: [0.99, 0.99], preset: .strict, source: .synthetic)
        XCTAssertEqual(outcome.threshold, SensitivityPreset.strict.scoreFloor(for: .synthetic))
        XCTAssertTrue(outcome.clampedToFloor)
    }

    func testStricterPresetsNeverProduceLowerThresholds() {
        let scores = Array(repeating: 0.97, count: 15)
        let strict = ThresholdCalibrator.calibrate(genuineScores: scores, preset: .strict).threshold
        let balanced = ThresholdCalibrator.calibrate(genuineScores: scores, preset: .balanced, source: .synthetic).threshold
        let convenient = ThresholdCalibrator.calibrate(genuineScores: scores, preset: .convenient).threshold
        XCTAssertGreaterThanOrEqual(strict, balanced)
        XCTAssertGreaterThanOrEqual(balanced, convenient)
    }
}
