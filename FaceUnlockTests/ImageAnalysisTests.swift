import XCTest
@testable import FaceUnlock

final class ImageAnalysisTests: XCTestCase {
    func testMeanLuminanceOfAFlatGrid() {
        let grid = Fake.grid { _, _ in 0.25 }
        XCTAssertEqual(ImageAnalysis.meanLuminance(grid), 0.25, accuracy: 1e-5)
    }

    func testFlatGridHasNoSharpness() {
        XCTAssertEqual(ImageAnalysis.sharpness(Fake.grid { _, _ in 0.5 }), 0, accuracy: 1e-9)
    }

    func testCheckerboardIsSharperThanAGradient() {
        let checker = Fake.grid(size: 16) { x, y in (x + y) % 2 == 0 ? 0 : 1 }
        let gradient = Fake.grid(size: 16) { x, _ in Float(x) / 16 }
        XCTAssertGreaterThan(ImageAnalysis.sharpness(checker), ImageAnalysis.sharpness(gradient))
    }

    func testSharpnessIsBounded() {
        let extreme = Fake.grid(size: 16) { x, y in (x + y) % 2 == 0 ? -100 : 100 }
        let value = ImageAnalysis.sharpness(extreme)
        XCTAssertGreaterThan(value, 0)
        XCTAssertLessThanOrEqual(value, 1)
    }

    func testIdenticalGridsHaveNoDifference() {
        let grid = Fake.grid { x, y in Float(x * y) / 64 }
        XCTAssertEqual(ImageAnalysis.meanAbsoluteDifference(grid, grid), 0, accuracy: 1e-9)
    }

    func testDifferenceIsSymmetricAndScaled() {
        let dark = Fake.grid { _, _ in 0.2 }
        let light = Fake.grid { _, _ in 0.7 }
        XCTAssertEqual(ImageAnalysis.meanAbsoluteDifference(dark, light), 0.5, accuracy: 1e-5)
        XCTAssertEqual(
            ImageAnalysis.meanAbsoluteDifference(dark, light),
            ImageAnalysis.meanAbsoluteDifference(light, dark),
            accuracy: 1e-9
        )
    }

    func testMismatchedGridsReportMaximumDifference() {
        let small = Fake.grid(size: 4) { _, _ in 0.5 }
        let large = Fake.grid(size: 8) { _, _ in 0.5 }
        XCTAssertEqual(ImageAnalysis.meanAbsoluteDifference(small, large), 1)
    }

    /// A pixel-grid pattern is exactly what a re-photographed display produces.
    func testHighFrequencyRatioSeparatesGridPatternsFromSmoothImages() {
        let panel = Fake.grid(size: 16) { x, _ in x % 2 == 0 ? 0.2 : 0.8 }
        let smooth = Fake.grid(size: 16) { x, _ in Float(x) / 16 }
        XCTAssertGreaterThan(
            ImageAnalysis.highFrequencyRatio(panel),
            ImageAnalysis.highFrequencyRatio(smooth)
        )
        XCTAssertLessThanOrEqual(ImageAnalysis.highFrequencyRatio(panel), 1)
    }

    func testStatisticsHelpers() {
        XCTAssertEqual(ImageAnalysis.mean([]), 0)
        XCTAssertEqual(ImageAnalysis.mean([1, 2, 3]), 2, accuracy: 1e-9)
        XCTAssertEqual(ImageAnalysis.variance([2, 2, 2]), 0, accuracy: 1e-9)
        XCTAssertEqual(ImageAnalysis.standardDeviation([1, 3]), 1, accuracy: 1e-9)
        XCTAssertEqual(ImageAnalysis.variance([5]), 0)
    }

    func testEmbeddingNormalisation() {
        let embedding = FaceEmbedding(source: .synthetic, producerVersion: "v", values: [3, 4])
        XCTAssertEqual(embedding.values[0], 0.6, accuracy: 1e-5)
        XCTAssertEqual(embedding.values[1], 0.8, accuracy: 1e-5)
        XCTAssertEqual(embedding.cosineSimilarity(to: embedding), 1, accuracy: 1e-6)
    }

    func testZeroVectorDoesNotProduceNaN() {
        let zero = FaceEmbedding(source: .synthetic, producerVersion: "v", values: [0, 0, 0])
        XCTAssertFalse(zero.cosineSimilarity(to: zero).isNaN)
        XCTAssertEqual(zero.cosineSimilarity(to: zero), 0, accuracy: 1e-9)
    }
}

/// The quality gate's thresholds are a usability/security trade-off, so they get
/// their own guard rails.
final class FaceQualityTests: XCTestCase {
    private func quality(faceSize: Double) -> FaceQuality {
        FaceQuality(
            faceSize: faceSize, luminance: 0.5, sharpness: 0.8,
            landmarkConfidence: 0.9, motion: 0.02, pose: FacePose()
        )
    }

    /// A rejection has to say what was measured, or "move closer" is unfalsifiable.
    func testRejectionCarriesItsMeasurements() {
        let measured = quality(faceSize: 0.09)
        let verdict = FaceQualityVerdict.rejected([.faceTooSmall], measured)
        XCTAssertEqual(verdict.issues, [.faceTooSmall])
        XCTAssertEqual(verdict.measured, measured)
        XCTAssertNil(verdict.quality, "a rejected frame is not an acceptable one")
    }

    func testAcceptanceExposesTheSameMeasurementsBothWays() {
        let measured = quality(faceSize: 0.4)
        let verdict = FaceQualityVerdict.acceptable(measured)
        XCTAssertEqual(verdict.quality, measured)
        XCTAssertEqual(verdict.measured, measured)
        XCTAssertTrue(verdict.issues.isEmpty)
    }

    /// The readout is shown on screen, so it must stay free of anything sensitive.
    func testReadoutIsThreePercentagesAndNothingElse() {
        let readout = quality(faceSize: 0.123).readout
        XCTAssertTrue(readout.contains("face"))
        XCTAssertTrue(readout.contains("light"))
        XCTAssertTrue(readout.contains("sharp"))
        XCTAssertFalse(readout.contains("pose"))
        XCTAssertFalse(readout.contains("yaw"))
    }

    func testDefaultThresholdsAdmitAnOrdinarySeatedUser() {
        let thresholds = FaceQualityAnalyzer.Thresholds()
        // Roughly a face at arm's length from a laptop, which must not be refused.
        XCTAssertLessThanOrEqual(thresholds.minimumFaceSize, 0.15)
        // ...but a speck in the corner still has to be.
        XCTAssertGreaterThan(thresholds.minimumFaceSize, 0.05)
        XCTAssertLessThan(thresholds.minimumLandmarkConfidence, 0.5)
        XCTAssertGreaterThan(thresholds.minimumLandmarkConfidence, 0.2)
    }

    func testEveryIssueHasItsOwnSentence() {
        let messages = FaceQualityIssue.allCases.map(\.message)
        XCTAssertEqual(Set(messages).count, FaceQualityIssue.allCases.count)
        XCTAssertTrue(messages.allSatisfy { $0.count > 10 })
    }
}
