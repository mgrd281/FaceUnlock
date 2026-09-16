import CoreImage
import CoreVideo
import Foundation

/// A rendered preview frame.
///
/// `CGImage` is immutable and thread-safe but not formally `Sendable`, hence the
/// `@unchecked` conformance on this wrapper.
public struct PreviewImage: @unchecked Sendable {
    public let image: CGImage
    public let timestamp: TimeInterval

    public init(image: CGImage, timestamp: TimeInterval) {
        self.image = image
        self.timestamp = timestamp
    }
}

/// Converts camera frames into images the UI can draw.
///
/// Only used while a window is actually showing a preview — enrolment, the
/// recognition test — never during ordinary unlock monitoring, where no frame is
/// ever rendered.
public final class PreviewRenderer: @unchecked Sendable {
    private let context: CIContext
    private let lock = NSLock()
    private var lastRender: TimeInterval = -.greatestFiniteMagnitude
    private let minimumInterval: TimeInterval

    public init(maximumFrameRate: Double = 15) {
        self.context = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
        self.minimumInterval = 1.0 / max(1, maximumFrameRate)
    }

    /// Returns a mirrored preview image, or `nil` when this frame should be
    /// skipped to stay inside the preview frame-rate budget.
    public func render(_ frame: CameraFrame) -> PreviewImage? {
        lock.lock()
        guard frame.timestamp - lastRender >= minimumInterval else {
            lock.unlock()
            return nil
        }
        lastRender = frame.timestamp
        lock.unlock()

        // Mirror horizontally so the preview behaves like a mirror, which is what
        // people expect when positioning their own face.
        let source = CIImage(cvPixelBuffer: frame.pixelBuffer)
        let mirrored = source
            .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
            .transformed(by: CGAffineTransform(translationX: source.extent.width, y: 0))
        guard let cgImage = context.createCGImage(mirrored, from: mirrored.extent) else { return nil }
        return PreviewImage(image: cgImage, timestamp: frame.timestamp)
    }
}
