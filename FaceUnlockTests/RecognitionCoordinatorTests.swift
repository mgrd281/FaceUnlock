import CoreVideo
import XCTest
@testable import FaceUnlock

/// End-to-end tests for the coordinator, driven entirely by fakes.
///
/// No camera, no lock screen, no Keychain and no face image is involved: the
/// dependency-injected pipeline lets a test script exactly which frames arrive,
/// what they are judged to be, and what the session state is.
final class RecognitionCoordinatorTests: XCTestCase {
    // MARK: Fixtures

    private func makeCoordinator(
        camera: FakeCameraManager,
        matches: Bool = true,
        livenessScore: Double = 0.9,
        livenessDisqualifier: String? = nil,
        qualityAcceptable: Bool = true,
        profile: BiometricProfile? = nil,
        unlock: FakeUnlockCoordinator = FakeUnlockCoordinator(),
        monitor: StubLockStateMonitor = StubLockStateMonitor(),
        locker: RecordingSessionLocker = RecordingSessionLocker(),
        configuration: RecognitionRuntimeConfiguration? = nil
    ) -> RecognitionCoordinator {
        let enrolled = profile ?? Fake.profile(
            embeddings: (1...6).map { Fake.embedding(seed: UInt64($0)) },
            threshold: 0.5001
        )
        var settings = RecognitionSettings.default
        settings.startDelayAfterLock = 0
        settings.attemptTimeout = 5
        let runtime = configuration ?? RecognitionRuntimeConfiguration(
            settings: settings, unlockEnabled: true, isPaused: false, lockWhenAbsent: false
        )
        return RecognitionCoordinator(
            camera: camera,
            detector: FakeFaceDetector(),
            quality: FakeQualityAnalyzer(acceptable: qualityAcceptable),
            embedder: FakeEmbedder(),
            matcher: FakeMatcher(matches: matches, threshold: enrolled.recognitionThreshold),
            liveness: FakeLiveness(score: livenessScore, disqualifier: livenessDisqualifier),
            profileStore: InMemoryProfileStore(profile: enrolled),
            unlockCoordinator: unlock,
            lockMonitor: monitor,
            permissions: StubPermissionManager(camera: .granted, accessibility: .granted),
            sessionLocker: locker,
            configurationProvider: { runtime }
        )
    }

    // MARK: Profile compatibility

    /// A profile from another descriptor pipeline is refused before any frame is
    /// captured, and the coordinator reports "no profile" rather than looping on
    /// "not recognised".
    func testProfileFromAnotherPipelineIsRefusedUpFront() async {
        let stale = Fake.profile(
            embeddings: (1...6).map { _ in
                FaceEmbedding(source: .visionFeaturePrint, producerVersion: "VNFeaturePrint.r2+geometry.v1",
                              values: Fake.embedding(seed: 1).values)
            },
            threshold: 0.88
        )
        let camera = FakeCameraManager(frameCount: 30)
        let unlock = FakeUnlockCoordinator()
        let coordinator = makeCoordinator(camera: camera, profile: stale, unlock: unlock)

        await coordinator.refreshPreconditions()
        let status = await coordinator.status
        XCTAssertEqual(status, .notConfigured)

        let statistics = await coordinator.currentStatistics
        XCTAssertEqual(
            statistics.lastErrorDescription,
            FaceUnlockError.profileIncompatible(stored: "", active: "").message
        )
        let attempts = await unlock.attemptCount
        XCTAssertEqual(attempts, 0)
    }

    // MARK: Happy path

    func testRecognisedAttemptUnlocksAndReleasesTheCamera() async {
        let camera = FakeCameraManager(frameCount: 30)
        let unlock = FakeUnlockCoordinator()
        let coordinator = makeCoordinator(camera: camera, unlock: unlock)

        let result = await coordinator.runAttempt(purpose: .unlock)

        let attempts = await unlock.attemptCount
        let running = await camera.isRunning()
        let stops = await camera.stopCount

        XCTAssertTrue(result.succeeded, "verdict was \(result.verdict)")
        XCTAssertEqual(attempts, 1)
        XCTAssertNotNil(result.unlockOutcome)
        XCTAssertFalse(running, "the camera must be released once the attempt ends")
        XCTAssertGreaterThanOrEqual(stops, 1)
    }

    /// A recognition test must never unlock anything.
    func testTestPurposeNeverUnlocks() async {
        let unlock = FakeUnlockCoordinator()
        let coordinator = makeCoordinator(camera: FakeCameraManager(frameCount: 30), unlock: unlock)

        let result = await coordinator.runAttempt(purpose: .test)

        let attempts = await unlock.attemptCount
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(attempts, 0)
        XCTAssertNil(result.unlockOutcome)
    }

    // MARK: Rejections

    func testNonMatchingFaceIsRejectedAndNothingUnlocks() async {
        let unlock = FakeUnlockCoordinator()
        let coordinator = makeCoordinator(
            camera: FakeCameraManager(frameCount: 20), matches: false, unlock: unlock
        )

        let result = await coordinator.runAttempt(purpose: .unlock)

        let attempts = await unlock.attemptCount
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(attempts, 0)
    }

    func testLivenessDisqualifierStopsTheAttempt() async {
        let unlock = FakeUnlockCoordinator()
        let coordinator = makeCoordinator(
            camera: FakeCameraManager(frameCount: 20),
            livenessDisqualifier: "the camera feed stopped changing",
            unlock: unlock
        )

        let result = await coordinator.runAttempt(purpose: .unlock)

        let attempts = await unlock.attemptCount
        XCTAssertEqual(result.verdict, .rejected(.livenessFailed))
        XCTAssertEqual(attempts, 0)
    }

    /// A liveness score below the floor must never become an accept, however many
    /// matching frames arrive.
    func testMarginalLivenessNeverAccepts() async {
        let unlock = FakeUnlockCoordinator()
        let coordinator = makeCoordinator(
            camera: FakeCameraManager(frameCount: 40), livenessScore: 0.2, unlock: unlock
        )

        let result = await coordinator.runAttempt(purpose: .unlock)

        let attempts = await unlock.attemptCount
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(attempts, 0)
    }

    func testPoorQualityFramesNeverReachTheMatcher() async {
        let unlock = FakeUnlockCoordinator()
        let coordinator = makeCoordinator(
            camera: FakeCameraManager(frameCount: 20), qualityAcceptable: false, unlock: unlock
        )

        let result = await coordinator.runAttempt(purpose: .unlock)

        let attempts = await unlock.attemptCount
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.bestScore, 0)
        XCTAssertEqual(attempts, 0)
    }

    func testAnEmptyFeedEndsAsTimedOut() async {
        let coordinator = makeCoordinator(camera: FakeCameraManager(frameCount: 0))
        let result = await coordinator.runAttempt(purpose: .unlock)
        XCTAssertEqual(result.verdict, .rejected(.timedOut))
    }

    // MARK: Preconditions

    func testMissingProfileFailsImmediately() async {
        let camera = FakeCameraManager(frameCount: 10)
        let coordinator = RecognitionCoordinator(
            camera: camera,
            detector: FakeFaceDetector(),
            quality: FakeQualityAnalyzer(acceptable: true),
            embedder: FakeEmbedder(),
            matcher: FakeMatcher(matches: true, threshold: 0.6),
            liveness: FakeLiveness(score: 0.9, disqualifier: nil),
            profileStore: InMemoryProfileStore(profile: nil),
            unlockCoordinator: FakeUnlockCoordinator(),
            lockMonitor: StubLockStateMonitor(),
            permissions: StubPermissionManager(camera: .granted, accessibility: .granted),
            sessionLocker: RecordingSessionLocker(),
            configurationProvider: {
                RecognitionRuntimeConfiguration(
                    settings: .default, unlockEnabled: true, isPaused: false, lockWhenAbsent: false
                )
            }
        )

        let result = await coordinator.runAttempt(purpose: .unlock)

        let starts = await camera.startCount
        XCTAssertEqual(result.verdict, .failed(.noEnrolledProfile))
        XCTAssertEqual(starts, 0, "the camera must not start without a profile")
    }

    func testCameraFailurePropagatesWithoutUnlocking() async {
        let camera = FakeCameraManager(frameCount: 0, startError: .cameraBusy)
        let unlock = FakeUnlockCoordinator()
        let coordinator = makeCoordinator(camera: camera, unlock: unlock)

        let result = await coordinator.runAttempt(purpose: .unlock)

        let attempts = await unlock.attemptCount
        XCTAssertEqual(result.verdict, .failed(.cameraBusy))
        XCTAssertEqual(attempts, 0)
    }

    // MARK: Lock-on-absence

    func testLockOnAbsenceRunsOnlyWhenEnabledAndStillUnlocked() async {
        var settings = RecognitionSettings.default
        settings.startDelayAfterLock = 0
        settings.attemptTimeout = 2

        let locker = RecordingSessionLocker()
        let monitor = StubLockStateMonitor(locked: false)
        let coordinator = makeCoordinator(
            camera: FakeCameraManager(frameCount: 10),
            matches: false,
            monitor: monitor,
            locker: locker,
            configuration: RecognitionRuntimeConfiguration(
                settings: settings, unlockEnabled: true, isPaused: false, lockWhenAbsent: true
            )
        )

        _ = await coordinator.runAttempt(purpose: .unlock)
        XCTAssertEqual(locker.lockCount, 1)
    }

    func testLockOnAbsenceIsSkippedWhenTheScreenIsAlreadyLocked() async {
        var settings = RecognitionSettings.default
        settings.startDelayAfterLock = 0
        settings.attemptTimeout = 2

        let locker = RecordingSessionLocker()
        let coordinator = makeCoordinator(
            camera: FakeCameraManager(frameCount: 10),
            matches: false,
            monitor: StubLockStateMonitor(locked: true),
            locker: locker,
            configuration: RecognitionRuntimeConfiguration(
                settings: settings, unlockEnabled: true, isPaused: false, lockWhenAbsent: true
            )
        )

        _ = await coordinator.runAttempt(purpose: .unlock)
        XCTAssertEqual(locker.lockCount, 0)
    }

    func testLockOnAbsenceIsSkippedForARecognitionTest() async {
        var settings = RecognitionSettings.default
        settings.startDelayAfterLock = 0
        settings.attemptTimeout = 2

        let locker = RecordingSessionLocker()
        let coordinator = makeCoordinator(
            camera: FakeCameraManager(frameCount: 10),
            matches: false,
            locker: locker,
            configuration: RecognitionRuntimeConfiguration(
                settings: settings, unlockEnabled: true, isPaused: false, lockWhenAbsent: true
            )
        )

        _ = await coordinator.runAttempt(purpose: .test)
        XCTAssertEqual(locker.lockCount, 0)
    }

    // MARK: Event-driven

    func testALockEventStartsAnAttempt() async throws {
        let camera = FakeCameraManager(frameCount: 30)
        let unlock = FakeUnlockCoordinator()
        let monitor = StubLockStateMonitor(locked: true)
        let coordinator = makeCoordinator(camera: camera, unlock: unlock, monitor: monitor)

        await coordinator.start()
        monitor.send(.screenLocked)

        try await waitUntil("an unlock is attempted") {
            await unlock.attemptCount == 1
        }
        await coordinator.stop()
    }

    func testNoAttemptStartsWhileUnlockIsDisabled() async throws {
        var settings = RecognitionSettings.default
        settings.startDelayAfterLock = 0
        let camera = FakeCameraManager(frameCount: 30)
        let monitor = StubLockStateMonitor(locked: true)
        let coordinator = makeCoordinator(
            camera: camera,
            monitor: monitor,
            configuration: RecognitionRuntimeConfiguration(
                settings: settings, unlockEnabled: false, isPaused: false, lockWhenAbsent: false
            )
        )

        await coordinator.start()
        monitor.send(.screenLocked)
        // Give the event a generous chance to be mishandled.
        try await Task.sleep(for: .milliseconds(300))
        let starts = await camera.startCount
        XCTAssertEqual(starts, 0)
        await coordinator.stop()
    }

    func testNoAttemptStartsWhilePaused() async throws {
        var settings = RecognitionSettings.default
        settings.startDelayAfterLock = 0
        let camera = FakeCameraManager(frameCount: 30)
        let monitor = StubLockStateMonitor(locked: true)
        let coordinator = makeCoordinator(
            camera: camera,
            monitor: monitor,
            configuration: RecognitionRuntimeConfiguration(
                settings: settings, unlockEnabled: true, isPaused: true, lockWhenAbsent: false
            )
        )

        await coordinator.start()
        monitor.send(.screenLocked)
        try await Task.sleep(for: .milliseconds(300))
        let starts = await camera.startCount
        XCTAssertEqual(starts, 0)
        await coordinator.stop()
    }

    // MARK: Helpers

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        _ condition: @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for \(description)")
    }
}

/// A match must never be accepted before liveness has had a full window.
///
/// A photograph matches on every frame just as promptly as a person does, so a
/// face that clears the consecutive-match requirement in about a second gets
/// there before the liveness window has filled. Concluding at that point would
/// accept an identity nothing had checked for liveness.
final class LivenessOrderingTests: XCTestCase {
    func testAnInstantMatchStillWaitsForTheLivenessWindow() async {
        // The liveness analyser is fed nothing, so its window never fills and it
        // can never authorise a conclusion. A perfect matcher must therefore not
        // be able to force one.
        let camera = FakeCameraManager(frameCount: 8)
        let unlock = FakeUnlockCoordinator()
        let profile = Fake.profile(
            embeddings: (1...6).map { Fake.embedding(seed: UInt64($0)) }, threshold: 0.5001)
        var mutable = RecognitionSettings.default
        mutable.startDelayAfterLock = 0
        mutable.attemptTimeout = 1
        let settings = mutable
        let coordinator = RecognitionCoordinator(
            camera: camera,
            detector: FakeFaceDetector(),
            quality: FakeQualityAnalyzer(acceptable: true),
            embedder: FakeEmbedder(),
            matcher: FakeMatcher(matches: true, threshold: profile.recognitionThreshold),
            // Only 8 frames are ever delivered, so the 12-frame window never fills.
            liveness: FakeLiveness(score: 0.99, disqualifier: nil),
            profileStore: InMemoryProfileStore(profile: profile),
            unlockCoordinator: unlock,
            lockMonitor: StubLockStateMonitor(),
            permissions: StubPermissionManager(camera: .granted, accessibility: .granted),
            sessionLocker: RecordingSessionLocker(),
            configurationProvider: {
                RecognitionRuntimeConfiguration(
                    settings: settings, unlockEnabled: true, isPaused: false, lockWhenAbsent: false)
            }
        )
        await coordinator.refreshPreconditions()
        let result = await coordinator.runAttempt(purpose: .challenge)
        XCTAssertFalse(
            result.succeeded,
            "a match must not be accepted while liveness has judged nothing"
        )
        let attempts = await unlock.attemptCount
        XCTAssertEqual(attempts, 0)
    }
}

/// Liveness that always reports the marginal band, so the coordinator has to
/// decide what to do when a prompt is wanted.
private final class MarginalLiveness: LivenessAnalyzing, @unchecked Sendable {
    private let score: Double
    private let lock = NSLock()
    private var recorded = 0

    init(score: Double) { self.score = score }

    func record(_ sample: LivenessSample) { lock.lock(); recorded += 1; lock.unlock() }

    func assess(configuration: BiometricProfile.LivenessConfiguration) -> LivenessAssessment {
        lock.lock(); let count = recorded; lock.unlock()
        return LivenessAssessment(
            score: score,
            signals: LivenessSignals(),
            sampleCount: count,
            disqualifier: nil,
            // Always in the band, so a prompt is always wanted.
            suggestedChallenge: count >= configuration.windowFrames ? .blink : nil
        )
    }

    func challengeSatisfied(_ challenge: LivenessChallenge) -> Bool { false }
    func reset() { lock.lock(); recorded = 0; lock.unlock() }
}

/// The lock-screen path judges liveness on the floor alone.
///
/// This is the deliberate weakening recorded in SECURITY.md and
/// KNOWN_LIMITATIONS.md §14: no prompt can be drawn over the lock screen, so the
/// marginal band is allowed through there and only the floor is enforced. These
/// tests exist so that the concession stays exactly this size — it must not
/// spread to the in-app paths, and it must not reach below the floor.
final class LockScreenLivenessFloorTests: XCTestCase {
    private func coordinator(
        livenessScore: Double,
        unlock: FakeUnlockCoordinator = FakeUnlockCoordinator()
    ) -> RecognitionCoordinator {
        let profile = Fake.profile(
            embeddings: (1...6).map { Fake.embedding(seed: UInt64($0)) }, threshold: 0.5001)
        var mutable = RecognitionSettings.default
        mutable.startDelayAfterLock = 0
        mutable.attemptTimeout = 3
        let settings = mutable
        return RecognitionCoordinator(
            camera: FakeCameraManager(frameCount: 40),
            detector: FakeFaceDetector(),
            quality: FakeQualityAnalyzer(acceptable: true),
            embedder: FakeEmbedder(),
            matcher: FakeMatcher(matches: true, threshold: profile.recognitionThreshold),
            liveness: MarginalLiveness(score: livenessScore),
            profileStore: InMemoryProfileStore(profile: profile),
            unlockCoordinator: unlock,
            lockMonitor: StubLockStateMonitor(),
            permissions: StubPermissionManager(camera: .granted, accessibility: .granted),
            sessionLocker: RecordingSessionLocker(),
            configurationProvider: {
                RecognitionRuntimeConfiguration(
                    settings: settings, unlockEnabled: true, isPaused: false, lockWhenAbsent: false)
            }
        )
    }

    private var floor: Double { SensitivityPreset.balanced.livenessFloor }

    func testAMarginalScoreAboveTheFloorIsAcceptedAtTheLockScreen() async {
        let coordinator = coordinator(livenessScore: floor + 0.01)
        await coordinator.refreshPreconditions()
        let result = await coordinator.runAttempt(purpose: .challenge)
        XCTAssertTrue(result.succeeded, "above the floor, the lock screen accepts without a prompt")
    }

    func testBelowTheFloorIsStillRefusedAtTheLockScreen() async {
        let coordinator = coordinator(livenessScore: floor - 0.01)
        await coordinator.refreshPreconditions()
        let result = await coordinator.runAttempt(purpose: .challenge)
        XCTAssertFalse(result.succeeded, "the floor is the one line this concession does not cross")
    }

    /// The concession is scoped to the lock screen. In the app, where a prompt
    /// can be shown, a marginal score must still ask for one — and a challenge
    /// this fake never satisfies must therefore never succeed.
    func testTheInAppPathStillDemandsAChallenge() async {
        let coordinator = coordinator(livenessScore: floor + 0.01)
        await coordinator.refreshPreconditions()
        let result = await coordinator.runAttempt(purpose: .test)
        XCTAssertFalse(
            result.succeeded,
            "the in-app path must keep asking for a challenge, not inherit the lock screen's relaxation"
        )
    }
}
