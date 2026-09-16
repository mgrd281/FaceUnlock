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
