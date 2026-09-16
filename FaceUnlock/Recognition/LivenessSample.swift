import Foundation
import Vision

/// One frame reduced to the measurements the liveness heuristics consume.
///
/// Keeping this separate from Vision types is what makes the liveness logic
/// testable: the test suite synthesises sequences of samples that represent a
/// live person, a held photograph, a phone replay or a frozen feed.
public struct LivenessSample: Equatable, Sendable {
    public var timestamp: TimeInterval
    public var sequence: UInt64
    public var pose: FacePose
    /// Eye aspect ratio, ~0.3 when open and ~0.1 when closed. `nil` when the eye
    /// contours were not resolved.
    public var eyeAspectRatio: Double?
    /// `distance(nose, leftEye) / distance(nose, rightEye)`. On a real head this
    /// tracks yaw strongly; on a flat photograph it barely moves.
    public var noseEyeRatio: Double?
    /// Mean absolute pixel difference from the previous sample, `0...1`.
    public var frameDifference: Double
    /// Horizontal high-frequency energy ratio of the face crop, `0...1`.
    public var highFrequencyRatio: Double

    public init(
        timestamp: TimeInterval,
        sequence: UInt64,
        pose: FacePose,
        eyeAspectRatio: Double?,
        noseEyeRatio: Double?,
        frameDifference: Double,
        highFrequencyRatio: Double
    ) {
        self.timestamp = timestamp
        self.sequence = sequence
        self.pose = pose
        self.eyeAspectRatio = eyeAspectRatio
        self.noseEyeRatio = noseEyeRatio
        self.frameDifference = frameDifference
        self.highFrequencyRatio = highFrequencyRatio
    }
}

/// Turns a detected face plus its frame into a `LivenessSample`.
public final class LivenessSampleBuilder: @unchecked Sendable {
    private let lock = NSLock()
    private var previousGrid: GrayscaleGrid?

    public init() {}

    public func reset() {
        lock.lock(); previousGrid = nil; lock.unlock()
    }

    public func makeSample(for face: DetectedFace, in frame: CameraFrame) -> LivenessSample {
        let bounds = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        let grid = GrayscaleGrid(
            pixelBuffer: frame.pixelBuffer,
            cropRect: face.pixelRect.expanded(by: 1.05, clampedTo: bounds)
        )

        var difference = 0.0
        var highFrequency = 0.0
        lock.lock()
        if let grid {
            if let previousGrid {
                difference = ImageAnalysis.meanAbsoluteDifference(previousGrid, grid)
            } else {
                // The first sample has no reference; treat it as plausible motion so a
                // single frame can never satisfy the micro-motion signal on its own.
                difference = -1
            }
            highFrequency = ImageAnalysis.highFrequencyRatio(grid)
            previousGrid = grid
        }
        lock.unlock()

        return LivenessSample(
            timestamp: frame.timestamp,
            sequence: frame.sequence,
            pose: face.pose,
            eyeAspectRatio: face.landmarks.flatMap(Self.eyeAspectRatio),
            noseEyeRatio: face.landmarks.flatMap(Self.noseEyeRatio),
            frameDifference: difference,
            highFrequencyRatio: highFrequency
        )
    }

    /// Mean of the left and right eye aspect ratios.
    ///
    /// The eye contour from the 76-point constellation is ordered around the eye,
    /// so the ratio of its vertical extent to its horizontal extent is a workable
    /// openness measure without needing a specific point ordering.
    static func eyeAspectRatio(_ landmarks: VNFaceLandmarks2D) -> Double? {
        let ratios = [landmarks.leftEye, landmarks.rightEye]
            .compactMap { $0 }
            .compactMap(aspectRatio)
        guard !ratios.isEmpty else { return nil }
        return ImageAnalysis.mean(ratios)
    }

    private static func aspectRatio(_ region: VNFaceLandmarkRegion2D) -> Double? {
        guard region.pointCount >= 4 else { return nil }
        let points = region.normalizedPoints
        let xs = points.map { Double($0.x) }
        let ys = points.map { Double($0.y) }
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return nil }
        let width = maxX - minX
        guard width > 1e-6 else { return nil }
        return (maxY - minY) / width
    }

    static func noseEyeRatio(_ landmarks: VNFaceLandmarks2D) -> Double? {
        guard let nose = landmarks.nose.map(centroid),
              let leftEye = landmarks.leftEye.map(centroid),
              let rightEye = landmarks.rightEye.map(centroid) else { return nil }
        let left = hypot(nose.x - leftEye.x, nose.y - leftEye.y)
        let right = hypot(nose.x - rightEye.x, nose.y - rightEye.y)
        guard right > 1e-6 else { return nil }
        return left / right
    }

    private static func centroid(_ region: VNFaceLandmarkRegion2D) -> CGPoint {
        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        for point in region.normalizedPoints {
            sumX += CGFloat(point.x)
            sumY += CGFloat(point.y)
        }
        let count = CGFloat(max(1, region.pointCount))
        return CGPoint(x: sumX / count, y: sumY / count)
    }
}
