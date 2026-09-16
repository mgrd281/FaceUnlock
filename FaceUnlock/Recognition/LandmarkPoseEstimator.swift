import Foundation
import Vision

/// Continuous head-pose estimation from the 2D landmark constellation.
///
/// ## Why this exists
///
/// `VNFaceObservation.yaw` is quantised to steps of π/4 (45°), so the only
/// values it ever reports are 0, ±0.785 and ±1.57. A "turn your head slightly"
/// step that asks for anything between 0.2 and 0.6 radians can therefore never
/// be satisfied: a slight turn still reads as 0, and the first non-zero reading
/// is already past the quality gate's extreme-pose limit. The user turns further
/// and further, is told to turn back, and concludes the app is broken.
///
/// The landmarks are continuous. The nose tip sits roughly half an inter-ocular
/// distance in front of the eye plane, so as the head yaws the tip slides
/// sideways relative to the eye midpoint by ~`noseDepth × sin(yaw)`; tilting
/// does the same vertically. Inverting that gives an estimate that is smooth,
/// monotonic in the true angle, and — after removing in-plane roll — free of
/// the quantisation. It is a proxy, not a calibrated angle: enrolment only ever
/// compares it against the same person's own straight-ahead baseline.
public enum LandmarkPoseEstimator {
    /// Nose-tip protrusion as a fraction of inter-ocular distance, for a typical
    /// adult face. Only the scale of the yaw estimate depends on it.
    private static let noseDepth = 0.55
    /// Typical vertical distance from the eye line to the nose tip, in
    /// inter-ocular units, for a level head. Centres the pitch proxy near zero.
    private static let nominalNoseDrop = 0.65
    private static let pitchScale = 0.5

    public static func estimate(from landmarks: VNFaceLandmarks2D) -> FacePose? {
        guard let leftEye = landmarks.leftEye.map(centroid),
              let rightEye = landmarks.rightEye.map(centroid) else { return nil }
        // Prefer the nose crest (bridge to tip) over the whole nose region, whose
        // centroid drifts with the nostrils.
        guard let nose = (landmarks.noseCrest ?? landmarks.nose).map(centroid) else { return nil }
        return estimate(leftEye: leftEye, rightEye: rightEye, nose: nose)
    }

    /// The geometry itself, on three points in any consistent, y-up coordinate
    /// space. Pure, so it can be tested without a `VNFaceLandmarks2D`.
    public static func estimate(leftEye: CGPoint, rightEye: CGPoint, nose: CGPoint) -> FacePose? {
        let dx = Double(rightEye.x - leftEye.x)
        let dy = Double(rightEye.y - leftEye.y)
        let interOcular = hypot(dx, dy)
        guard interOcular > 1e-4 else { return nil }

        // In-plane roll from the eye line, then rotate the nose into the eye-line
        // frame so roll cannot leak into the yaw and pitch estimates.
        let roll = atan2(dy, dx)
        let midX = Double(leftEye.x + rightEye.x) / 2
        let midY = Double(leftEye.y + rightEye.y) / 2
        let relX = Double(nose.x) - midX
        let relY = Double(nose.y) - midY
        let cosR = cos(-roll)
        let sinR = sin(-roll)
        let alongEyes = (relX * cosR - relY * sinR) / interOcular
        let acrossEyes = (relX * sinR + relY * cosR) / interOcular

        let yaw = asin(min(1, max(-1, alongEyes / noseDepth)))
        // Vision's landmark space has its origin at the bottom left, so a nose
        // below the eyes has a negative offset; flip it so "drop" is positive.
        let drop = -acrossEyes
        let pitch = (drop - nominalNoseDrop) / pitchScale

        return FacePose(yaw: yaw, pitch: pitch, roll: roll)
    }

    private static func centroid(_ region: VNFaceLandmarkRegion2D) -> CGPoint {
        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        for point in region.normalizedPoints {
            sumX += point.x
            sumY += point.y
        }
        let count = CGFloat(max(1, region.pointCount))
        return CGPoint(x: sumX / count, y: sumY / count)
    }
}
