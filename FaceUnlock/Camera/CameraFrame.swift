import CoreVideo
import Foundation

/// One camera frame handed to the recognition pipeline.
///
/// `CVPixelBuffer` is a Core Foundation type without `Sendable` conformance. The
/// buffer is produced by the capture callback, handed to exactly one consumer and
/// never mutated, so transferring it across isolation domains is safe. That
/// invariant is the reason for the `@unchecked` conformance.
public struct CameraFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    /// Host time of capture, in seconds.
    public let timestamp: TimeInterval
    /// Monotonically increasing per capture session; used to detect a stalled
    /// or replayed feed.
    public let sequence: UInt64

    public init(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval, sequence: UInt64) {
        self.pixelBuffer = pixelBuffer
        self.timestamp = timestamp
        self.sequence = sequence
    }

    public var width: Int { CVPixelBufferGetWidth(pixelBuffer) }
    public var height: Int { CVPixelBufferGetHeight(pixelBuffer) }
}
