import Foundation
import Vision

/// A compact shape descriptor built from Vision's landmark constellation.
///
/// Why this exists: Apple's `VNGenerateImageFeaturePrintRequest` is a general
/// image descriptor, not a face-recognition embedding, so on its own it is more
/// sensitive to lighting and background than to identity. Pairing it with an
/// explicitly geometric descriptor — ratios of distances between stable landmarks,
/// normalised by inter-ocular distance — adds a signal that is invariant to
/// brightness and scale and that a general descriptor does not capture well.
///
/// The descriptor is scale- and rotation-invariant by construction because every
/// distance is divided by the inter-ocular distance and measured on the aligned
/// landmark set.
public enum FaceGeometryDescriptor {
    /// Landmark groups whose centroids are stable enough to anchor the descriptor.
    private enum Anchor: Int, CaseIterable {
        case leftEye
        case rightEye
        case leftEyebrow
        case rightEyebrow
        case noseCrest
        case nose
        case outerLips
        case innerLips
        case medianLine
        case leftPupil
        case rightPupil
        case faceContour
    }

    /// Number of values produced. Twelve anchors give 66 unordered pairs.
    public static let dimension = Anchor.allCases.count * (Anchor.allCases.count - 1) / 2

    /// Builds the descriptor, or returns `nil` when too many anchors are missing to
    /// make the result meaningful.
    public static func descriptor(for landmarks: VNFaceLandmarks2D) -> [Float]? {
        var points: [Anchor: CGPoint] = [:]
        for anchor in Anchor.allCases {
            if let region = region(for: anchor, in: landmarks), region.pointCount > 0 {
                points[anchor] = centroid(of: region)
            }
        }
        // Both eyes are required: they define the normalising distance.
        guard let leftEye = points[.leftEye] ?? points[.leftPupil],
              let rightEye = points[.rightEye] ?? points[.rightPupil] else { return nil }
        let interOcular = hypot(rightEye.x - leftEye.x, rightEye.y - leftEye.y)
        guard interOcular > 1e-6 else { return nil }
        // Require at least two thirds of the anchors so a heavily occluded face does
        // not produce a descriptor dominated by fallback zeros.
        guard points.count * 3 >= Anchor.allCases.count * 2 else { return nil }

        let centre = CGPoint(x: (leftEye.x + rightEye.x) / 2, y: (leftEye.y + rightEye.y) / 2)
        var values: [Float] = []
        values.reserveCapacity(dimension)
        let anchors = Anchor.allCases
        for outer in 0..<anchors.count {
            for inner in (outer + 1)..<anchors.count {
                // A missing anchor falls back to the eye midpoint, which keeps the
                // vector length fixed and the value bounded.
                let first = points[anchors[outer]] ?? centre
                let second = points[anchors[inner]] ?? centre
                let distance = hypot(second.x - first.x, second.y - first.y) / interOcular
                values.append(Float(distance))
            }
        }
        return values
    }

    private static func region(for anchor: Anchor, in landmarks: VNFaceLandmarks2D) -> VNFaceLandmarkRegion2D? {
        switch anchor {
        case .leftEye: return landmarks.leftEye
        case .rightEye: return landmarks.rightEye
        case .leftEyebrow: return landmarks.leftEyebrow
        case .rightEyebrow: return landmarks.rightEyebrow
        case .noseCrest: return landmarks.noseCrest
        case .nose: return landmarks.nose
        case .outerLips: return landmarks.outerLips
        case .innerLips: return landmarks.innerLips
        case .medianLine: return landmarks.medianLine
        case .leftPupil: return landmarks.leftPupil
        case .rightPupil: return landmarks.rightPupil
        case .faceContour: return landmarks.faceContour
        }
    }

    private static func centroid(of region: VNFaceLandmarkRegion2D) -> CGPoint {
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
