import CoreVideo
import Foundation
import Vision

/// One face found in a frame, reduced to the values the rest of the pipeline uses.
public struct DetectedFace: @unchecked Sendable {
    /// Face rectangle in pixel coordinates with the origin at the top left.
    public let pixelRect: CGRect
    /// Vision's normalised bounding box, origin bottom left.
    public let normalizedRect: CGRect
    public let confidence: Double
    public let pose: FacePose
    public let landmarks: VNFaceLandmarks2D?
    /// The originating observation, retained for the embedding stage.
    public let observation: VNFaceObservation

    public init(
        pixelRect: CGRect,
        normalizedRect: CGRect,
        confidence: Double,
        pose: FacePose,
        landmarks: VNFaceLandmarks2D?,
        observation: VNFaceObservation
    ) {
        self.pixelRect = pixelRect
        self.normalizedRect = normalizedRect
        self.confidence = confidence
        self.pose = pose
        self.landmarks = landmarks
        self.observation = observation
    }
}

public protocol FaceDetecting: Sendable {
    func detectFaces(in frame: CameraFrame) throws -> [DetectedFace]
}

/// Vision-based detection.
///
/// `VNDetectFaceLandmarksRequest` implies rectangle detection, so a single request
/// produces both the bounding box and the 76-point landmark constellation the
/// quality, liveness and geometry stages need. Running one request instead of two
/// roughly halves the per-frame cost.
public final class FaceDetector: FaceDetecting, @unchecked Sendable {
    private let handlerOptions: [VNImageOption: Any]

    public init() {
        self.handlerOptions = [:]
    }

    public func detectFaces(in frame: CameraFrame) throws -> [DetectedFace] {
        let request = VNDetectFaceLandmarksRequest()
        // Constellation76Points gives the eye contours the blink detector needs.
        request.constellation = .constellation76Points
        // The camera feed is upright; declaring it avoids Vision's orientation search.
        let handler = VNImageRequestHandler(
            cvPixelBuffer: frame.pixelBuffer,
            orientation: .up,
            options: handlerOptions
        )
        do {
            try handler.perform([request])
        } catch {
            throw FaceUnlockError.embeddingFailed("Face detection failed: \(error.localizedDescription)")
        }

        let width = CGFloat(frame.width)
        let height = CGFloat(frame.height)
        return (request.results ?? []).map { observation in
            DetectedFace(
                pixelRect: VNImageRectForNormalizedRect(observation.boundingBox, Int(width), Int(height))
                    .flippedVertically(inHeight: height),
                normalizedRect: observation.boundingBox,
                confidence: Double(observation.confidence),
                pose: FacePose(
                    yaw: observation.yaw?.doubleValue ?? 0,
                    pitch: observation.pitch?.doubleValue ?? 0,
                    roll: observation.roll?.doubleValue ?? 0
                ),
                landmarks: observation.landmarks,
                observation: observation
            )
        }
    }
}

extension CGRect {
    /// Converts between Vision's bottom-left origin and the buffer's top-left origin.
    func flippedVertically(inHeight height: CGFloat) -> CGRect {
        CGRect(x: minX, y: height - maxY, width: width, height: self.height)
    }

    /// Expands the rectangle by `factor` around its centre, staying inside `bounds`.
    func expanded(by factor: CGFloat, clampedTo bounds: CGRect) -> CGRect {
        let dx = width * (factor - 1) / 2
        let dy = height * (factor - 1) / 2
        return insetBy(dx: -dx, dy: -dy).intersection(bounds)
    }
}
