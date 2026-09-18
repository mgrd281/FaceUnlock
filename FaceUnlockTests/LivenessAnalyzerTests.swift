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
        signals.isotropy = 1
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

/// Regression: a challenge must not be raised before the evidence exists.
final class LivenessChallengeTimingTests: XCTestCase {
    private func configuration(windowFrames: Int = 12) -> BiometricProfile.LivenessConfiguration {
        BiometricProfile.LivenessConfiguration(
            mode: .adaptiveChallenge,
            minimumScore: SensitivityPreset.balanced.livenessFloor,
            windowFrames: windowFrames
        )
    }

    /// The bug that stopped the lock screen ever unlocking.
    ///
    /// A matching face reaches the required consecutive matches within about
    /// four frames. At that point the liveness window held four samples, the
    /// passive score was necessarily near zero, and a blink challenge was
    /// latched — permanently, because the caller never clears it. In the app the
    /// user saw the prompt and blinked; at the lock screen, where no prompt can
    /// be drawn, the attempt simply ran out of time.
    func testNoChallengeIsSuggestedBeforeTheWindowIsFull() {
        let analyzer = LivenessAnalyzer()
        for sample in Fake.liveSamples(count: 5) { analyzer.record(sample) }
        let assessment = analyzer.assess(configuration: configuration())
        XCTAssertLessThan(assessment.sampleCount, 12)
        XCTAssertNil(
            assessment.suggestedChallenge,
            "a quarter-full window is a measurement artifact, not marginal evidence"
        )
    }

    /// The rule must not become "never challenge": once the window is full, a
    /// genuinely marginal score still has to ask.
    func testAMarginalScoreOnAFullWindowStillAsks() {
        let analyzer = LivenessAnalyzer()
        // A held photograph: a full window whose passive evidence is weak.
        for sample in Fake.photoSamples(count: 16) { analyzer.record(sample) }
        let assessment = analyzer.assess(configuration: configuration())
        XCTAssertGreaterThanOrEqual(assessment.sampleCount, 12)
        if assessment.disqualifier == nil {
            XCTAssertNotNil(
                assessment.suggestedChallenge,
                "a full window with marginal evidence must still ask"
            )
        }
    }
}


/// The blink requirement is the whole of the lock screen's anti-spoofing now,
/// so it has to be exactly as strong as it claims.
///
/// Measured reality that motivated this: a phone held at one distance scored
/// 0.95 on texture isotropy — indistinguishable from real skin — and unlocked
/// this Mac three times in a row. A blink was the only signal left that a still
/// image cannot fake. These tests exist so that claim stays true.
final class BlinkRequirementTests: XCTestCase {
    private func configuration() -> BiometricProfile.LivenessConfiguration {
        BiometricProfile.LivenessConfiguration(
            mode: .adaptiveChallenge,
            minimumScore: SensitivityPreset.balanced.livenessFloor,
            windowFrames: 12
        )
    }

    /// The failure that would make the whole design worthless.
    func testAStillImageNeverSatisfiesTheBlink() {
        let analyzer = LivenessAnalyzer()
        for sample in Fake.photoSamples(count: 24) { analyzer.record(sample) }
        XCTAssertFalse(
            analyzer.challengeSatisfied(.blink),
            "a photograph must never register a blink — the lock screen relies on it"
        )
    }

    /// A still image displayed on a screen must fail the same way.
    ///
    /// The fixture matters here: `screenReplaySamples` is a replay of *live*
    /// footage, so it contains a real blink and passes — correctly, because a
    /// video replay genuinely can blink. What must never pass is a still image,
    /// which is what a photograph on a phone actually is.
    func testAStillImageOnAScreenNeverSatisfiesTheBlink() {
        let analyzer = LivenessAnalyzer()
        for sample in Fake.stillImageOnScreenSamples(count: 24) { analyzer.record(sample) }
        XCTAssertFalse(analyzer.challengeSatisfied(.blink))
    }

    /// The exact attack that unlocked this Mac: a phone at the distance where
    /// isotropy reads like skin. It must now fail on the blink.
    func testThePhoneAttackThatSucceededNowFails() {
        let analyzer = LivenessAnalyzer()
        for sample in Fake.stillImageOnScreenSamples(count: 24) { analyzer.record(sample) }
        XCTAssertFalse(
            analyzer.challengeSatisfied(.blink),
            "this is the measured attack; it unlocked three times out of three before the blink was required"
        )
    }

    /// Eyes that are simply closed in the picture are not a blink either: a
    /// blink is a transition, and a photograph of someone mid-blink is still a
    /// photograph.
    func testPermanentlyClosedEyesAreNotABlink() {
        let analyzer = LivenessAnalyzer()
        for sample in Fake.photoSamples(count: 20) {
            var closed = sample
            closed.eyeAspectRatio = 0.10
            analyzer.record(closed)
        }
        XCTAssertFalse(analyzer.challengeSatisfied(.blink))
    }

    /// And a genuine open-closed-open sequence must still pass, or the feature
    /// is unusable rather than merely strict.
    func testAGenuineBlinkIsAccepted() {
        let analyzer = LivenessAnalyzer()
        var samples = Fake.liveSamples(count: 18)
        samples[6].eyeAspectRatio = 0.10
        samples[7].eyeAspectRatio = 0.09
        for sample in samples { analyzer.record(sample) }
        XCTAssertTrue(analyzer.challengeSatisfied(.blink))
    }
}
