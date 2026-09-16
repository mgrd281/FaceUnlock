import CoreImage
import CoreVideo
import Foundation
import Vision

/// Produces a canonical, pose-normalised face crop.
///
/// Alignment matters more here than it would with a purpose-trained face network:
/// the descriptor FaceUnlock uses by default is a general-purpose image
/// descriptor, so removing in-plane rotation and scale variation is what makes
/// two pictures of the same person land close together.
public final class FaceAligner: @unchecked Sendable {
    /// Edge length of the aligned crop. 160 px is the smallest size at which the
    /// feature print stayed stable in testing while keeping the request cheap.
    public static let outputSize = 160

    private let context: CIContext
    private let lock = NSLock()
    private var scratchBuffer: CVPixelBuffer?

    public init() {
        // Software rendering is disabled so the GPU (or the Neural Engine, for the
        // Vision requests downstream) does the work instead of the CPU.
        self.context = CIContext(options: [
            .useSoftwareRenderer: false,
            .cacheIntermediates: false
        ])
    }

    /// Returns a square, upright crop centred on the face, or `nil` when the
    /// landmarks needed for alignment are missing.
    public func alignedCrop(for face: DetectedFace, in frame: CameraFrame) -> CVPixelBuffer? {
        let source = CIImage(cvPixelBuffer: frame.pixelBuffer)
        let imageHeight = CGFloat(frame.height)
        let imageWidth = CGFloat(frame.width)

        // Work in Core Image's bottom-left origin space throughout.
        let faceRect = VNImageRectForNormalizedRect(
            face.normalizedRect, Int(imageWidth), Int(imageHeight)
        )

        let rotation: CGFloat
        let eyeCentre: CGPoint
        let interOcular: CGFloat
        if let eyes = eyeCentres(for: face, faceRect: faceRect) {
            let delta = CGPoint(x: eyes.right.x - eyes.left.x, y: eyes.right.y - eyes.left.y)
            rotation = -atan2(delta.y, delta.x)
            eyeCentre = CGPoint(x: (eyes.left.x + eyes.right.x) / 2, y: (eyes.left.y + eyes.right.y) / 2)
            interOcular = max(1, hypot(delta.x, delta.y))
        } else {
            // Fall back to the bounding box when landmarks are unavailable. The roll
            // angle from the observation still removes most in-plane rotation.
            rotation = CGFloat(-face.pose.roll)
            eyeCentre = CGPoint(x: faceRect.midX, y: faceRect.midY + faceRect.height * 0.12)
            interOcular = faceRect.width * 0.42
        }

        // Place the eyes 0.42 of the crop apart, a little above centre — the usual
        // convention for aligned face crops.
        let outputSize = CGFloat(Self.outputSize)
        let scale = (outputSize * 0.42) / interOcular
        guard scale.isFinite, scale > 0 else { return nil }

        var transform = CGAffineTransform.identity
        transform = transform.translatedBy(x: outputSize / 2, y: outputSize * 0.58)
        transform = transform.scaledBy(x: scale, y: scale)
        transform = transform.rotated(by: rotation)
        transform = transform.translatedBy(x: -eyeCentre.x, y: -eyeCentre.y)

        let transformed = source.transformed(by: transform)
        let cropRect = CGRect(x: 0, y: 0, width: outputSize, height: outputSize)
        let cropped = transformed.cropped(to: cropRect)
        guard !cropped.extent.isEmpty else { return nil }

        lock.lock(); defer { lock.unlock() }
        guard let buffer = reusableBuffer() else { return nil }
        context.render(
            cropped,
            to: buffer,
            bounds: cropRect,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return buffer
    }

    /// Eye centres in image coordinates, bottom-left origin.
    func eyeCentres(for face: DetectedFace, faceRect: CGRect) -> (left: CGPoint, right: CGPoint)? {
        guard let landmarks = face.landmarks,
              let leftEye = landmarks.leftEye,
              let rightEye = landmarks.rightEye,
              leftEye.pointCount > 0, rightEye.pointCount > 0 else { return nil }
        return (
            centroid(of: leftEye, in: faceRect),
            centroid(of: rightEye, in: faceRect)
        )
    }

    private func centroid(of region: VNFaceLandmarkRegion2D, in faceRect: CGRect) -> CGPoint {
        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        for point in region.normalizedPoints {
            sumX += CGFloat(point.x)
            sumY += CGFloat(point.y)
        }
        let count = CGFloat(region.pointCount)
        return CGPoint(
            x: faceRect.minX + (sumX / count) * faceRect.width,
            y: faceRect.minY + (sumY / count) * faceRect.height
        )
    }

    /// A single reusable destination buffer. Rendering is serialised by `lock`, so
    /// one buffer is enough and it avoids an allocation per frame.
    private func reusableBuffer() -> CVPixelBuffer? {
        if let scratchBuffer { return scratchBuffer }
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Self.outputSize,
            Self.outputSize,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess else {
            AppLogger.recognition.error("Could not allocate the aligned-crop buffer")
            return nil
        }
        scratchBuffer = buffer
        return buffer
    }
}
