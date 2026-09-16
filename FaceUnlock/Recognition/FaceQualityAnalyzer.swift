import CoreVideo
import Foundation

/// Decides whether a frame is good enough to be embedded.
///
/// Running this before the embedding stage is both a quality and a power measure:
/// a rejected frame costs one 48×48 sample and a handful of arithmetic, whereas a
/// feature-print request costs orders of magnitude more.
public protocol FaceQualityAnalyzing: Sendable {
    func evaluate(faces: [DetectedFace], frame: CameraFrame) -> FaceQualityVerdict
    /// Clears the motion reference, e.g. between enrolment steps.
    func reset()
}

public final class FaceQualityAnalyzer: FaceQualityAnalyzing, @unchecked Sendable {
    public struct Thresholds: Sendable {
        /// Fraction of the frame's shorter edge the face box must cover.
        ///
        /// 0.17 turned out to reject someone sitting back from a laptop at a
        /// perfectly ordinary distance. At 720p capture, 0.12 still leaves an
        /// ~86-pixel face box to align and describe, which is ample.
        public var minimumFaceSize: Double = 0.12
        public var maximumFaceSize: Double = 0.95
        public var minimumLuminance: Double = 0.16
        public var maximumLuminance: Double = 0.92
        public var minimumSharpness: Double = 0.30
        // A turned head legitimately lowers landmark confidence, and the turned
        // poses are exactly the ones enrolment needs.
        public var minimumLandmarkConfidence: Double = 0.45
        public var maximumMotion: Double = 0.16
        // Limits are in `LandmarkPoseEstimator` units. Yaw is an angle estimate
        // (0.70 ≈ 40°, beyond which the far eye's landmarks stop being reliable).
        // Pitch is a raw nose-drop proxy with no universal zero, so it gets only
        // a sanity ceiling: a drop this large is not a face, it is a landmark
        // failure. Real tilts are judged relative to the user's own baseline.
        public var maximumAbsoluteYaw: Double = 0.70
        public var maximumAbsolutePitch: Double = 1.6
        public var maximumAbsoluteRoll: Double = 0.45

        public init() {}
    }

    private let thresholds: Thresholds
    private let lock = NSLock()
    private var previousGrid: GrayscaleGrid?

    public init(thresholds: Thresholds = Thresholds()) {
        self.thresholds = thresholds
    }

    public func reset() {
        lock.lock(); previousGrid = nil; lock.unlock()
    }

    public func evaluate(faces: [DetectedFace], frame: CameraFrame) -> FaceQualityVerdict {
        guard !faces.isEmpty else { return .rejected([.noFace], nil) }
        guard faces.count == 1 else { return .rejected([.multipleFaces], nil) }
        guard let face = faces.first else { return .rejected([.noFace], nil) }

        let shorterEdge = Double(min(frame.width, frame.height))
        guard shorterEdge > 0 else { return .rejected([.noFace], nil) }
        let faceSize = Double(face.pixelRect.height) / shorterEdge

        let bounds = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        guard let grid = GrayscaleGrid(
            pixelBuffer: frame.pixelBuffer,
            cropRect: face.pixelRect.expanded(by: 1.1, clampedTo: bounds)
        ) else {
            return .rejected([.noFace], nil)
        }

        let luminance = ImageAnalysis.meanLuminance(grid)
        let sharpness = ImageAnalysis.sharpness(grid)
        let motion = motionSince(grid)

        let quality = FaceQuality(
            faceSize: faceSize,
            luminance: luminance,
            sharpness: sharpness,
            landmarkConfidence: Double(face.landmarks?.confidence ?? 0),
            motion: motion,
            pose: face.pose
        )

        var issues: [FaceQualityIssue] = []
        if faceSize < thresholds.minimumFaceSize { issues.append(.faceTooSmall) }
        if faceSize > thresholds.maximumFaceSize { issues.append(.faceTooClose) }
        if luminance < thresholds.minimumLuminance { issues.append(.tooDark) }
        if luminance > thresholds.maximumLuminance { issues.append(.tooBright) }
        if sharpness < thresholds.minimumSharpness { issues.append(.blurry) }
        if quality.landmarkConfidence < thresholds.minimumLandmarkConfidence { issues.append(.occluded) }
        if motion > thresholds.maximumMotion { issues.append(.tooMuchMotion) }
        if abs(face.pose.yaw) > thresholds.maximumAbsoluteYaw
            || abs(face.pose.pitch) > thresholds.maximumAbsolutePitch
            || abs(face.pose.roll) > thresholds.maximumAbsoluteRoll {
            issues.append(.extremePose)
        }

        return issues.isEmpty ? .acceptable(quality) : .rejected(issues, quality)
    }

    private func motionSince(_ grid: GrayscaleGrid) -> Double {
        lock.lock(); defer { lock.unlock() }
        defer { previousGrid = grid }
        guard let previousGrid else { return 0 }
        return ImageAnalysis.meanAbsoluteDifference(previousGrid, grid)
    }
}
