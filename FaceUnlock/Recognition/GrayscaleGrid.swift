import Accelerate
import CoreVideo
import Foundation

/// A small, normalised grayscale sample of a region of a frame.
///
/// Every pixel-level heuristic in FaceUnlock (lighting, sharpness, motion,
/// high-frequency texture) works on one of these rather than on a `CVPixelBuffer`.
/// That keeps the heuristics pure, cheap and unit-testable without a camera.
public struct GrayscaleGrid: Equatable, Sendable {
    public let width: Int
    public let height: Int
    /// Row-major luminance values in `0...1`.
    public let values: [Float]

    public init(width: Int, height: Int, values: [Float]) {
        precondition(values.count == width * height, "Grid dimensions must match the value count")
        self.width = width
        self.height = height
        self.values = values
    }

    /// Samples a BGRA pixel buffer into a fixed-size grid.
    ///
    /// Nearest-neighbour sampling is deliberate: the grid is small (typically
    /// 48×48), so a box filter would blur away exactly the high-frequency content
    /// the sharpness and texture heuristics depend on.
    public init?(pixelBuffer: CVPixelBuffer, cropRect: CGRect, size: Int = 48) {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return nil
        }
        guard size > 2 else { return nil }

        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
        let clamped = cropRect.intersection(CGRect(x: 0, y: 0, width: bufferWidth, height: bufferHeight))
        guard clamped.width >= 2, clamped.height >= 2 else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pointer = base.assumingMemoryBound(to: UInt8.self)

        var samples = [Float](repeating: 0, count: size * size)
        for row in 0..<size {
            let sourceY = Int(clamped.minY + (CGFloat(row) + 0.5) / CGFloat(size) * clamped.height)
            let clampedY = min(max(sourceY, 0), bufferHeight - 1)
            for column in 0..<size {
                let sourceX = Int(clamped.minX + (CGFloat(column) + 0.5) / CGFloat(size) * clamped.width)
                let clampedX = min(max(sourceX, 0), bufferWidth - 1)
                let offset = clampedY * bytesPerRow + clampedX * 4
                let blue = Float(pointer[offset])
                let green = Float(pointer[offset + 1])
                let red = Float(pointer[offset + 2])
                // Rec. 601 luma, matching how the ISP already weights the channels.
                samples[row * size + column] = (0.299 * red + 0.587 * green + 0.114 * blue) / 255
            }
        }
        self.init(width: size, height: size, values: samples)
    }

    public subscript(x: Int, y: Int) -> Float {
        values[y * width + x]
    }
}

/// Pure image statistics used by the quality and liveness heuristics.
public enum ImageAnalysis {
    /// Mean luminance in `0...1`.
    public static func meanLuminance(_ grid: GrayscaleGrid) -> Double {
        guard !grid.values.isEmpty else { return 0 }
        return Double(vDSP.mean(grid.values))
    }

    /// Variance of the 4-neighbour Laplacian, a standard focus measure.
    ///
    /// The raw value is unbounded, so it is squashed into `0...1` with a saturating
    /// curve whose knee sits near the response of a well-focused webcam face crop.
    public static func sharpness(_ grid: GrayscaleGrid) -> Double {
        guard grid.width > 2, grid.height > 2 else { return 0 }
        var responses: [Double] = []
        responses.reserveCapacity((grid.width - 2) * (grid.height - 2))
        for y in 1..<(grid.height - 1) {
            for x in 1..<(grid.width - 1) {
                let laplacian = Double(
                    4 * grid[x, y] - grid[x - 1, y] - grid[x + 1, y] - grid[x, y - 1] - grid[x, y + 1]
                )
                responses.append(laplacian)
            }
        }
        let variance = Self.variance(responses)
        let knee = 0.0025
        return variance / (variance + knee)
    }

    /// Mean absolute difference between two grids of equal size, in `0...1`.
    public static func meanAbsoluteDifference(_ lhs: GrayscaleGrid, _ rhs: GrayscaleGrid) -> Double {
        guard lhs.width == rhs.width, lhs.height == rhs.height, !lhs.values.isEmpty else { return 1 }
        var total: Double = 0
        for index in 0..<lhs.values.count {
            total += Double(abs(lhs.values[index] - rhs.values[index]))
        }
        return total / Double(lhs.values.count)
    }

    /// Ratio of horizontal high-frequency energy to total energy.
    ///
    /// A face re-photographed from an LCD or OLED panel carries the panel's pixel
    /// grid, which shows up as an unusually strong, regular high-frequency
    /// component. This is a weak signal on its own and is only ever combined with
    /// others — see `LivenessAnalyzer`.
    public static func highFrequencyRatio(_ grid: GrayscaleGrid) -> Double {
        guard grid.width > 3, grid.height > 1 else { return 0 }
        var highFrequency: Double = 0
        var total: Double = 0
        for y in 0..<grid.height {
            for x in 1..<(grid.width - 1) {
                let secondDerivative = Double(2 * grid[x, y] - grid[x - 1, y] - grid[x + 1, y])
                let firstDerivative = Double(grid[x, y] - grid[x - 1, y])
                highFrequency += secondDerivative * secondDerivative
                total += firstDerivative * firstDerivative
            }
        }
        guard total > 1e-9 else { return 0 }
        return min(1, highFrequency / (total * 4))
    }

    /// How directional the fine detail is, `0...1`, where 1 is perfectly
    /// isotropic and 0 is entirely aligned to one axis.
    ///
    /// This is the single most useful thing a still frame can say about a
    /// display. Skin texture — pores, fine hair, the grain of the sensor's noise
    /// — has no preferred direction, so its horizontal and vertical gradient
    /// energies are about equal. An LCD or OLED panel photographed off-axis adds
    /// a *regular grid*, and a grid is strongly anisotropic: energy piles up on
    /// the row and column axes. A printed photograph often shows the same thing
    /// from halftone screening.
    ///
    /// Unlike micro-motion this needs no time to accumulate, which is what lets
    /// a motionless face be judged at all.
    public static func textureIsotropy(_ grid: GrayscaleGrid) -> Double {
        guard grid.width > 2, grid.height > 2 else { return 0 }
        var horizontal: Double = 0
        var vertical: Double = 0
        for y in 1..<(grid.height - 1) {
            for x in 1..<(grid.width - 1) {
                let dx = Double(grid[x + 1, y] - grid[x - 1, y])
                let dy = Double(grid[x, y + 1] - grid[x, y - 1])
                horizontal += dx * dx
                vertical += dy * dy
            }
        }
        let total = horizontal + vertical
        guard total > 1e-9 else { return 0 }
        // 1 when the two axes carry equal energy, falling to 0 as one dominates.
        return 1 - abs(horizontal - vertical) / total
    }

    /// Population variance of a sample.
    public static func variance(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let sumOfSquares = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return sumOfSquares / Double(values.count)
    }

    public static func standardDeviation(_ values: [Double]) -> Double {
        variance(values).squareRoot()
    }

    public static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}
