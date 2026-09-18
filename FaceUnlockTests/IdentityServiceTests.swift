import XCTest
@testable import FaceUnlock

/// A scripted stand-in for the recognition stack.
private actor ScriptedRecogniser: ChallengeRunning {
    private let verdict: RecognitionAttemptResult.Verdict
    private let delay: Duration
    private(set) var attempts = 0

    init(verdict: RecognitionAttemptResult.Verdict, delay: Duration = .zero) {
        self.verdict = verdict
        self.delay = delay
    }

    func runAttempt(purpose: RecognitionPurpose) async -> RecognitionAttemptResult {
        attempts += 1
        recordedPurposes.append(purpose)
        if delay != .zero { try? await Task.sleep(for: delay) }
        return RecognitionAttemptResult(
            verdict: verdict, bestScore: 0.9, threshold: 0.8,
            livenessScore: 0.9, framesProcessed: 4, duration: 0.1, unlockOutcome: nil
        )
    }

    private(set) var recordedPurposes: [RecognitionPurpose] = []
    func attemptCount() -> Int { attempts }
    func purposes() -> [RecognitionPurpose] { recordedPurposes }
}

final class IdentityServiceTests: XCTestCase {
    private func nonce(_ byte: UInt8 = 7) -> ChallengeNonce {
        ChallengeNonce(bytes: Data(repeating: byte, count: BrokerProtocol.nonceLength))
    }

    private func configuration(unlockEnabled: Bool = true) -> @Sendable () async -> RecognitionRuntimeConfiguration {
        { RecognitionRuntimeConfiguration(
            settings: .default, unlockEnabled: unlockEnabled,
            isPaused: false, lockWhenAbsent: false) }
    }

    private func storeWithProfile() -> InMemoryProfileStore {
        InMemoryProfileStore(profile: Fake.profile(embeddings: [Fake.embedding(seed: 1)]))
    }

    func testARecognisedAttemptSatisfiesTheChallenge() async {
        let service = IdentityService(
            recogniser: ScriptedRecogniser(verdict: .recognized),
            profileStore: storeWithProfile(),
            configurationProvider: configuration()
        )
        let verdict = await service.answerChallenge(nonce(), deadline: .seconds(5))
        XCTAssertTrue(verdict.recognised)
        XCTAssertNil(verdict.refusal)
    }

    func testTheChallengePurposeNeverDrivesTheProviderChain() async {
        // `.challenge` exists precisely so that answering the lock screen cannot
        // re-enter the unlock provider chain; the unlock is completed by
        // SecurityAgent on the other side.
        let recogniser = ScriptedRecogniser(verdict: .recognized)
        let service = IdentityService(
            recogniser: recogniser,
            profileStore: storeWithProfile(),
            configurationProvider: configuration()
        )
        _ = await service.answerChallenge(nonce(), deadline: .seconds(5))
        let purposes = await recogniser.purposes()
        XCTAssertEqual(purposes, [.challenge])
    }

    func testARejectedAttemptRefuses() async {
        let service = IdentityService(
            recogniser: ScriptedRecogniser(verdict: .rejected(.lowConfidence)),
            profileStore: storeWithProfile(),
            configurationProvider: configuration()
        )
        let verdict = await service.answerChallenge(nonce(), deadline: .seconds(5))
        XCTAssertFalse(verdict.recognised)
        XCTAssertEqual(verdict.refusal, .notRecognised)
    }

    func testUnlockDisabledRefusesWithoutRunningTheCamera() async {
        let recogniser = ScriptedRecogniser(verdict: .recognized)
        let service = IdentityService(
            recogniser: recogniser,
            profileStore: storeWithProfile(),
            configurationProvider: configuration(unlockEnabled: false)
        )
        let verdict = await service.answerChallenge(nonce(), deadline: .seconds(5))
        XCTAssertEqual(verdict.refusal, .unlockDisabled)
        let attempts = await recogniser.attemptCount()
        XCTAssertEqual(attempts, 0, "a refused precondition must not cost a camera start")
    }

    func testNoEnrolledProfileRefusesWithoutRunningTheCamera() async {
        let recogniser = ScriptedRecogniser(verdict: .recognized)
        let service = IdentityService(
            recogniser: recogniser,
            profileStore: InMemoryProfileStore(profile: nil),
            configurationProvider: configuration()
        )
        let verdict = await service.answerChallenge(nonce(), deadline: .seconds(5))
        XCTAssertEqual(verdict.refusal, .noProfileEnrolled)
        let attempts = await recogniser.attemptCount()
        XCTAssertEqual(attempts, 0)
    }

    func testAMalformedNonceIsRefused() async {
        let service = IdentityService(
            recogniser: ScriptedRecogniser(verdict: .recognized),
            profileStore: storeWithProfile(),
            configurationProvider: configuration()
        )
        let short = ChallengeNonce(bytes: Data(repeating: 1, count: 8))
        let verdict = await service.answerChallenge(short, deadline: .seconds(5))
        XCTAssertEqual(verdict.refusal, .malformedChallenge)
    }

    func testTheSameNonceIsNeverAnsweredTwice() async {
        let service = IdentityService(
            recogniser: ScriptedRecogniser(verdict: .recognized),
            profileStore: storeWithProfile(),
            configurationProvider: configuration()
        )
        let challenge = nonce(42)
        let first = await service.answerChallenge(challenge, deadline: .seconds(5))
        let second = await service.answerChallenge(challenge, deadline: .seconds(5))
        XCTAssertTrue(first.recognised)
        XCTAssertFalse(second.recognised, "a replayed challenge must never be satisfied")
        XCTAssertEqual(second.refusal, .challengeReplayed)
    }

    func testAnAttemptThatOutlastsTheDeadlineIsRefused() async {
        let service = IdentityService(
            recogniser: ScriptedRecogniser(verdict: .recognized, delay: .seconds(10)),
            profileStore: storeWithProfile(),
            configurationProvider: configuration()
        )
        let verdict = await service.answerChallenge(nonce(), deadline: .milliseconds(200))
        XCTAssertFalse(verdict.recognised)
        XCTAssertEqual(verdict.refusal, .deadlineExceeded)
    }

    /// The deadline has to bound when the answer *arrives*, not merely what it
    /// says. The first implementation raced the attempt against a sleeper inside
    /// a task group, which decided the verdict on time and then waited for the
    /// slow attempt anyway; on the first real run the answer was settled at 5.5 s
    /// and delivered at 15.1 s, long after the broker had stopped listening.
    func testTheDeadlineBoundsWhenTheAnswerArrivesNotJustItsContent() async {
        let service = IdentityService(
            recogniser: ScriptedRecogniser(verdict: .recognized, delay: .seconds(10)),
            profileStore: storeWithProfile(),
            configurationProvider: configuration()
        )
        let started = ContinuousClock.now
        _ = await service.answerChallenge(nonce(), deadline: .milliseconds(300))
        let elapsed = ContinuousClock.now - started
        XCTAssertLessThan(
            elapsed, .seconds(3),
            "the answer must come back on the deadline, not when the attempt finishes"
        )
    }

    /// Two tasks can finish at nearly the same instant, and a checked
    /// continuation resumed twice traps. Run the race often enough to catch it.
    func testTheDeadlineAndTheAttemptCanNeverBothAnswer() async {
        for _ in 0..<200 {
            let service = IdentityService(
                recogniser: ScriptedRecogniser(verdict: .recognized, delay: .milliseconds(1)),
                profileStore: storeWithProfile(),
                configurationProvider: configuration()
            )
            _ = await service.answerChallenge(nonce(), deadline: .milliseconds(1))
        }
    }

    /// A profile that exists but cannot be decrypted must say so. It is the
    /// difference between "enrol" and "re-enrol", and the refusal is the only
    /// place the lock screen can carry that.
    func testAnUnreadableProfileIsDistinguishedFromAMissingOne() async {
        let service = IdentityService(
            recogniser: ScriptedRecogniser(verdict: .failed(.profileCorrupted)),
            profileStore: storeWithProfile(),
            configurationProvider: configuration()
        )
        let verdict = await service.answerChallenge(nonce(), deadline: .seconds(5))
        XCTAssertEqual(verdict.refusal, .profileUnreadable)
    }

    func testAMissingProfileFoundMidAttemptIsReportedAsMissing() async {
        let service = IdentityService(
            recogniser: ScriptedRecogniser(verdict: .failed(.noEnrolledProfile)),
            profileStore: storeWithProfile(),
            configurationProvider: configuration()
        )
        let verdict = await service.answerChallenge(nonce(), deadline: .seconds(5))
        XCTAssertEqual(verdict.refusal, .noProfileEnrolled)
    }

    func testAnIncompatibleProfileIsReportedAsSuch() async {
        let failure = RecognitionAttemptResult.Verdict.failed(
            .profileIncompatible(stored: "a", active: "b"))
        let service = IdentityService(
            recogniser: ScriptedRecogniser(verdict: failure),
            profileStore: storeWithProfile(),
            configurationProvider: configuration()
        )
        let verdict = await service.answerChallenge(nonce(), deadline: .seconds(5))
        XCTAssertEqual(verdict.refusal, .profileIncompatible)
    }
}
