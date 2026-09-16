import XCTest
@testable import FaceUnlock

final class RecognitionStateMachineTests: XCTestCase {
    private func armedMachine() -> RecognitionStateMachine {
        RecognitionStateMachine(hasProfile: true, missingPermission: nil, cameraAvailable: true)
    }

    func testRestingStatusReflectsPreconditions() {
        XCTAssertEqual(RecognitionStateMachine().status, .notConfigured)
        XCTAssertEqual(armedMachine().status, .ready)
        XCTAssertEqual(
            RecognitionStateMachine(hasProfile: true, missingPermission: .camera).status,
            .permissionRequired(.camera)
        )
        XCTAssertEqual(
            RecognitionStateMachine(hasProfile: true, cameraAvailable: false).status,
            .cameraUnavailable
        )
    }

    func testMissingPermissionOutranksMissingProfile() {
        var machine = RecognitionStateMachine(hasProfile: false, missingPermission: .camera)
        XCTAssertEqual(machine.status, .permissionRequired(.camera))
        machine.apply(.permissionsSatisfied)
        XCTAssertEqual(machine.status, .notConfigured)
    }

    func testHappyPathTransitions() {
        var machine = armedMachine()
        machine.apply(.attemptStarted)
        XCTAssertEqual(machine.status, .monitoring)
        machine.apply(.faceSeen)
        XCTAssertEqual(machine.status, .faceDetected)
        machine.apply(.frameEvaluated(progress: 0.5))
        XCTAssertEqual(machine.status, .recognizing(progress: 0.5))
        machine.apply(.matchConfirmed)
        XCTAssertEqual(machine.status, .recognized)
        machine.apply(.unlockStarted)
        XCTAssertEqual(machine.status, .unlockAttempt)
        machine.apply(.unlockSucceeded)
        XCTAssertEqual(machine.status, .unlocked)
        machine.apply(.attemptFinished)
        XCTAssertEqual(machine.status, .ready)
    }

    func testProgressIsClamped() {
        var machine = armedMachine()
        machine.apply(.attemptStarted)
        machine.apply(.frameEvaluated(progress: 4.2))
        XCTAssertEqual(machine.status, .recognizing(progress: 1))
        machine.apply(.frameEvaluated(progress: -3))
        XCTAssertEqual(machine.status, .recognizing(progress: 0))
    }

    /// An unlock can only begin from `recognized`, never from a partial state.
    func testUnlockCannotStartWithoutRecognition() {
        var machine = armedMachine()
        machine.apply(.attemptStarted)
        machine.apply(.faceSeen)
        machine.apply(.unlockStarted)
        XCTAssertEqual(machine.status, .faceDetected)
    }

    func testPausedAbsorbsActivityEvents() {
        var machine = armedMachine()
        machine.apply(.paused(until: nil))
        XCTAssertEqual(machine.status, .paused(until: .distantFuture))
        machine.apply(.attemptStarted)
        machine.apply(.faceSeen)
        machine.apply(.matchConfirmed)
        machine.apply(.unlockSucceeded)
        XCTAssertEqual(machine.status, .paused(until: .distantFuture))
        machine.apply(.resumed)
        XCTAssertEqual(machine.status, .ready)
    }

    func testPauseExpiryReturnsToReady() {
        var machine = armedMachine()
        machine.apply(.paused(until: Date().addingTimeInterval(-1)))
        machine.apply(.attemptFinished)
        XCTAssertEqual(machine.status, .ready)
    }

    func testLosingTheProfileMidAttemptStopsActivity() {
        var machine = armedMachine()
        machine.apply(.attemptStarted)
        machine.apply(.profileRemoved)
        XCTAssertEqual(machine.status, .notConfigured)
        machine.apply(.faceSeen)
        XCTAssertEqual(machine.status, .notConfigured)
    }

    func testLosingCameraPermissionMidAttemptStopsActivity() {
        var machine = armedMachine()
        machine.apply(.attemptStarted)
        machine.apply(.permissionLost(.camera))
        XCTAssertEqual(machine.status, .permissionRequired(.camera))
        machine.apply(.matchConfirmed)
        XCTAssertEqual(machine.status, .permissionRequired(.camera))
    }

    func testApplyReportsWhetherTheStatusChanged() {
        var machine = armedMachine()
        XCTAssertTrue(machine.apply(.attemptStarted))
        XCTAssertFalse(machine.apply(.attemptStarted))
    }

    func testRejectionIsClearedWhenTheAttemptEnds() {
        var machine = armedMachine()
        machine.apply(.attemptStarted)
        machine.apply(.rejected(.livenessFailed))
        XCTAssertEqual(machine.status, .rejected(.livenessFailed))
        machine.apply(.attemptFinished)
        XCTAssertEqual(machine.status, .ready)
    }

    func testErrorStatusCarriesTheError() {
        var machine = armedMachine()
        machine.apply(.attemptStarted)
        machine.apply(.failed(.cameraBusy))
        XCTAssertEqual(machine.status, .error(.cameraBusy))
        XCTAssertEqual(machine.status.identifier, "error.camera.busy")
    }

    func testIsActiveOnlyWhileFramesAreBeingConsumed() {
        XCTAssertTrue(AppStatus.monitoring.isActive)
        XCTAssertTrue(AppStatus.recognizing(progress: 0.2).isActive)
        XCTAssertTrue(AppStatus.unlockAttempt.isActive)
        XCTAssertFalse(AppStatus.ready.isActive)
        XCTAssertFalse(AppStatus.paused(until: nil).isActive)
        XCTAssertFalse(AppStatus.unlocked.isActive)
    }
}

/// Enrolment pose geometry.
///
/// The security-relevant property is that "left" and "right" (and "up" and
/// "down") capture two genuinely *different* head orientations. That must hold
/// without asserting Vision's sign convention for `yaw` and `pitch`, which is
/// exactly what the coordinator's direction calibration provides.
final class EnrollmentPoseTests: XCTestCase {
    func testOpposedPairsShareAnAxis() {
        XCTAssertEqual(EnrollmentPose.left.axis, .yaw)
        XCTAssertEqual(EnrollmentPose.right.axis, .yaw)
        XCTAssertEqual(EnrollmentPose.up.axis, .pitch)
        XCTAssertEqual(EnrollmentPose.down.axis, .pitch)
        XCTAssertEqual(EnrollmentPose.straight.axis, .none)
        XCTAssertEqual(EnrollmentPose.neutralExpression.axis, .none)
    }

    func testExactlyOnePoseOfEachPairIsTheOpposite() {
        let yawPoses = EnrollmentPose.allCases.filter { $0.axis == .yaw }
        let pitchPoses = EnrollmentPose.allCases.filter { $0.axis == .pitch }
        XCTAssertEqual(yawPoses.filter(\.isOpposite).count, 1)
        XCTAssertEqual(pitchPoses.filter(\.isOpposite).count, 1)
    }

    /// The first pose of a pair must be recorded before its partner is asked for,
    /// otherwise the opposite-sign requirement has nothing to compare against.
    func testTheFirstOfEachPairComesFirst() {
        let order = EnrollmentPose.allCases
        func index(_ pose: EnrollmentPose) -> Int {
            order.firstIndex(of: pose) ?? Int.max
        }
        XCTAssertLessThan(index(.left), index(.right))
        XCTAssertLessThan(index(.up), index(.down))
    }

    func testDirectionalPosesRequireAMeaningfulLean() {
        for pose in EnrollmentPose.allCases where pose.axis != .none {
            XCTAssertGreaterThanOrEqual(pose.minimumLean, 0.1, "\(pose) should need a real turn")
            // Well inside the quality gate's own limits, so an accepted frame is
            // never one the analyser would have rejected as an extreme pose.
            XCTAssertLessThan(pose.minimumLean, 0.5)
        }
        XCTAssertEqual(EnrollmentPose.straight.minimumLean, 0)
    }

    func testEveryPoseAsksForTheSameNumberOfSamples() {
        let counts = Set(EnrollmentPose.allCases.map(\.requiredSamples))
        XCTAssertEqual(counts.count, 1)
        XCTAssertGreaterThanOrEqual(counts.first ?? 0, 3)
    }

    func testEveryPoseHasDistinctUserFacingText() {
        XCTAssertEqual(Set(EnrollmentPose.allCases.map(\.title)).count, EnrollmentPose.allCases.count)
        XCTAssertEqual(Set(EnrollmentPose.allCases.map(\.shortTitle)).count, EnrollmentPose.allCases.count)
    }
}
