import XCTest
@testable import FaceUnlock

/// The landmark-based pose estimate is what makes the "turn slightly" steps
/// satisfiable at all, so its geometry is pinned down here on synthetic points.
final class LandmarkPoseEstimatorTests: XCTestCase {
    // A level, frontal face in a y-up unit space: eyes 0.3 apart, nose tip 0.65
    // of that below the eye midpoint.
    private let leftEye = CGPoint(x: 0.35, y: 0.60)
    private let rightEye = CGPoint(x: 0.65, y: 0.60)
    private var frontalNose: CGPoint { CGPoint(x: 0.50, y: 0.60 - 0.65 * 0.30) }

    func testFrontalFaceIsNearZero() throws {
        let pose = try XCTUnwrap(LandmarkPoseEstimator.estimate(
            leftEye: leftEye, rightEye: rightEye, nose: frontalNose
        ))
        XCTAssertEqual(pose.yaw, 0, accuracy: 0.02)
        XCTAssertEqual(pose.pitch, 0, accuracy: 0.05)
        XCTAssertEqual(pose.roll, 0, accuracy: 0.001)
    }

    func testNoseSlidingSidewaysReadsAsYaw() throws {
        let turned = CGPoint(x: frontalNose.x + 0.06, y: frontalNose.y)
        let pose = try XCTUnwrap(LandmarkPoseEstimator.estimate(
            leftEye: leftEye, rightEye: rightEye, nose: turned
        ))
        XCTAssertGreaterThan(pose.yaw, EnrollmentPose.left.minimumLean)
        XCTAssertEqual(pose.pitch, 0, accuracy: 0.05)

        let other = CGPoint(x: frontalNose.x - 0.06, y: frontalNose.y)
        let opposite = try XCTUnwrap(LandmarkPoseEstimator.estimate(
            leftEye: leftEye, rightEye: rightEye, nose: other
        ))
        XCTAssertLessThan(opposite.yaw, -EnrollmentPose.right.minimumLean)
    }

    func testNoseRisingOrDroppingReadsAsPitch() throws {
        let up = CGPoint(x: frontalNose.x, y: frontalNose.y + 0.04)
        let down = CGPoint(x: frontalNose.x, y: frontalNose.y - 0.04)
        let upPose = try XCTUnwrap(LandmarkPoseEstimator.estimate(leftEye: leftEye, rightEye: rightEye, nose: up))
        let downPose = try XCTUnwrap(LandmarkPoseEstimator.estimate(leftEye: leftEye, rightEye: rightEye, nose: down))
        XCTAssertGreaterThan(abs(upPose.pitch - downPose.pitch), EnrollmentPose.up.minimumLean)
        XCTAssertNotEqual(upPose.pitch < 0, downPose.pitch < 0, "up and down must have opposite signs")
        XCTAssertEqual(upPose.yaw, 0, accuracy: 0.02)
    }

    /// Tilting the head sideways must not masquerade as a turn: roll is removed
    /// before yaw and pitch are read.
    func testInPlaneRollDoesNotLeakIntoYaw() throws {
        let angle = 0.25
        func rotate(_ point: CGPoint) -> CGPoint {
            let cx = 0.5, cy = 0.6
            let x = Double(point.x) - cx, y = Double(point.y) - cy
            return CGPoint(x: cx + x * cos(angle) - y * sin(angle), y: cy + x * sin(angle) + y * cos(angle))
        }
        let pose = try XCTUnwrap(LandmarkPoseEstimator.estimate(
            leftEye: rotate(leftEye), rightEye: rotate(rightEye), nose: rotate(frontalNose)
        ))
        XCTAssertEqual(pose.roll, angle, accuracy: 0.01)
        XCTAssertEqual(pose.yaw, 0, accuracy: 0.03)
        XCTAssertEqual(pose.pitch, 0, accuracy: 0.06)
    }

    func testDegenerateEyesReturnNil() {
        XCTAssertNil(LandmarkPoseEstimator.estimate(leftEye: leftEye, rightEye: leftEye, nose: frontalNose))
    }

    /// The whole point: a modest turn lands *inside* the enrolment window, which
    /// Vision's π/4-quantised yaw never could.
    func testAModestTurnIsInsideTheEnrolmentWindow() throws {
        let slight = CGPoint(x: frontalNose.x + 0.045, y: frontalNose.y)
        let pose = try XCTUnwrap(LandmarkPoseEstimator.estimate(leftEye: leftEye, rightEye: rightEye, nose: slight))
        let thresholds = FaceQualityAnalyzer.Thresholds()
        XCTAssertGreaterThanOrEqual(abs(pose.yaw), EnrollmentPose.left.minimumLean)
        XCTAssertLessThan(abs(pose.yaw), thresholds.maximumAbsoluteYaw)
    }
}
