import XCTest
@testable import FaceUnlock

final class LivenessAnalyzerTests: XCTestCase {
    private let configuration = BiometricProfile.LivenessConfiguration(
        mode: .passive,
        minimumScore: SensitivityPreset.balanced.livenessFloor,
        windowFrames: 16
    )

    private func assess(_ samples: [LivenessSample]) -> LivenessAssessment {
        let analyzer = LivenessAnalyzer()
        for sample in samples { analyzer.record(sample) }
        return analyzer.assess(configuration: configuration)
    }

    func testALivePersonPasses() {
        let assessment = assess(Fake.liveSamples())
        XCTAssertNil(assessment.disqualifier)
        XCTAssertGreaterThanOrEqual(
            assessment.score, configuration.minimumScore,
            "signals: \(assessment.signals)"
        )
    }

    func testAHeldPhotographFails() {
        let assessment = assess(Fake.photoSamples())
        XCTAssertLessThan(assessment.score, configuration.minimumScore)
    }

    func testAScreenReplayScoresLowerThanTheLiveSubject() {
        let live = assess(Fake.liveSamples()).score
        let replay = assess(Fake.screenReplaySamples()).score
        XCTAssertLessThan(replay, live)
    }

    func testAFrozenFeedIsDisqualifiedOutright() {
        let assessment = assess(Fake.frozenSamples())
        XCTAssertEqual(assessment.score, 0)
        XCTAssertEqual(assessment.disqualifier, "the camera feed stopped changing")
        XCTAssertFalse(assessment.isConclusive)
    }

    func testARepeatedFrameSequenceIsDisqualified() {
        let samples = (0..<12).map { index in
            LivenessSample(
                timestamp: Double(index) * 0.1,
                sequence: 42,  // the camera keeps handing back the same frame
                pose: FacePose(yaw: Double(index) * 0.01),
                eyeAspectRatio: 0.29,
                noseEyeRatio: 1.0,
                frameDifference: index == 0 ? -1 : 0.02,
                highFrequencyRatio: 0.2
            )
        }
        XCTAssertEqual(assess(samples).disqualifier, "the camera delivered the same frame repeatedly")
    }

    func testTooFewSamplesIsNeverAPass() {
        let assessment = assess(Array(Fake.liveSamples().prefix(3)))
        XCTAssertEqual(assessment.score, 0)
    }

    func testNoSingleSignalCanCarryTheScore() {
        var signals = LivenessSignals()
        signals.blink = 1
        XCTAssertLessThan(signals.aggregate, SensitivityPreset.convenient.livenessFloor)
        signals = LivenessSignals()
        signals.texture = 1
        XCTAssertLessThan(signals.aggregate, SensitivityPreset.convenient.livenessFloor)
        signals = LivenessSignals()
        signals.microMotion = 1
        XCTAssertLessThan(signals.aggregate, SensitivityPreset.convenient.livenessFloor)
    }

    func testAllSignalsTogetherReachTheTop() {
        var signals = LivenessSignals()
        signals.blink = 1
        signals.poseVariation = 1
        signals.microMotion = 1
        signals.texture = 1
        signals.parallax = 1
        XCTAssertEqual(signals.aggregate, 1, accuracy: 1e-9)
    }

    func testBlinkRequiresAFullOpenClosedOpenSequence() {
        let analyzer = LivenessAnalyzer()
        // Eyes closed the whole time is not a blink.
        let alwaysClosed = (0..<10).map { index in
            LivenessSample(
                timestamp: Double(index) * 0.1, sequence: UInt64(index + 1), pose: FacePose(),
                eyeAspectRatio: 0.10, noseEyeRatio: 1, frameDifference: 0.02, highFrequencyRatio: 0.2
            )
        }
        XCTAssertEqual(analyzer.blinkScore(alwaysClosed), 0)
        XCTAssertEqual(analyzer.blinkScore(Fake.liveSamples()), 1)
    }

    func testChallengeIsSuggestedInTheMarginalBand() {
        let analyzer = LivenessAnalyzer()
        for sample in Fake.photoSamples() { analyzer.record(sample) }
        let adaptive = BiometricProfile.LivenessConfiguration(
            mode: .adaptiveChallenge, minimumScore: 0.62, windowFrames: 16
        )
        XCTAssertNotNil(analyzer.assess(configuration: adaptive).suggestedChallenge)

        let passive = BiometricProfile.LivenessConfiguration(
            mode: .passive, minimumScore: 0.62, windowFrames: 16
        )
        XCTAssertNil(analyzer.assess(configuration: passive).suggestedChallenge)
    }

    func testAlwaysChallengeAlwaysAsks() {
        let analyzer = LivenessAnalyzer()
        for sample in Fake.liveSamples() { analyzer.record(sample) }
        let always = BiometricProfile.LivenessConfiguration(
            mode: .alwaysChallenge, minimumScore: 0.1, windowFrames: 16
        )
        XCTAssertNotNil(analyzer.assess(configuration: always).suggestedChallenge)
    }

    func testHeadTurnChallengeNeedsBothTheTurnAndAReturn() {
        let analyzer = LivenessAnalyzer()
        for sample in Fake.liveSamples() { analyzer.record(sample) }
        // The live sequence only drifts by ±0.09 rad, well short of the 0.18 needed.
        XCTAssertFalse(analyzer.challengeSatisfied(.turnRight))

        analyzer.reset()
        let turning: [Double] = [0.0, 0.05, 0.12, 0.22, 0.26, 0.15, 0.04, 0.0]
        for (index, yaw) in turning.enumerated() {
            analyzer.record(
                LivenessSample(
                    timestamp: Double(index) * 0.1, sequence: UInt64(index + 1),
                    pose: FacePose(yaw: yaw), eyeAspectRatio: 0.29,
                    noseEyeRatio: 1 + yaw * 0.6, frameDifference: 0.03, highFrequencyRatio: 0.2
                )
            )
        }
        XCTAssertTrue(analyzer.challengeSatisfied(.turnRight))
        XCTAssertFalse(analyzer.challengeSatisfied(.turnLeft))
    }

    func testResetClearsTheWindow() {
        let analyzer = LivenessAnalyzer()
        for sample in Fake.liveSamples() { analyzer.record(sample) }
        analyzer.reset()
        XCTAssertEqual(analyzer.assess(configuration: configuration).sampleCount, 0)
    }
}
