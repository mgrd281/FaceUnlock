import Foundation

/// The result of evaluating a single camera frame before it is used.
///
/// Quality gating happens *before* embedding extraction: it is far cheaper to
/// reject a blurry or badly lit frame than to run Vision's feature-print request
/// on it, and it keeps low-information samples out of the enrolled template.
public struct FaceQuality: Equatable, Sendable {
    /// Fraction of the frame's shorter edge covered by the face bounding box.
    public var faceSize: Double
    /// Mean luminance of the face region, 0...1.
    public var luminance: Double
    /// Normalised variance-of-Laplacian style sharpness estimate, 0...1.
    public var sharpness: Double
    /// Vision's landmark confidence, used as an occlusion proxy, 0...1.
    public var landmarkConfidence: Double
    /// Pixel motion relative to the previous accepted frame, 0...1.
    public var motion: Double
    /// Measured head pose.
    public var pose: FacePose

    public init(
        faceSize: Double,
        luminance: Double,
        sharpness: Double,
        landmarkConfidence: Double,
        motion: Double,
        pose: FacePose
    ) {
        self.faceSize = faceSize
        self.luminance = luminance
        self.sharpness = sharpness
        self.landmarkConfidence = landmarkConfidence
        self.motion = motion
        self.pose = pose
    }
}

/// Why a frame was not accepted. Each case maps to a sentence the user can act on.
public enum FaceQualityIssue: String, Equatable, Sendable, CaseIterable {
    case noFace
    case multipleFaces
    case faceTooSmall
    case faceTooClose
    case tooDark
    case tooBright
    case blurry
    case occluded
    case extremePose
    case tooMuchMotion

    public var message: String {
        switch self {
        case .noFace: return "No face in view."
        case .multipleFaces: return "More than one face is in view."
        case .faceTooSmall: return "Move a little closer to the camera."
        case .faceTooClose: return "Move a little further from the camera."
        case .tooDark: return "There is not enough light."
        case .tooBright: return "The image is overexposed."
        case .blurry: return "Hold still — the image is blurry."
        case .occluded: return "Part of your face is covered."
        case .extremePose: return "Turn your head back towards the camera."
        case .tooMuchMotion: return "Hold still for a moment."
        }
    }
}

/// Outcome of the quality gate for one frame.
public enum FaceQualityVerdict: Equatable, Sendable {
    case acceptable(FaceQuality)
    case rejected([FaceQualityIssue])

    public var quality: FaceQuality? {
        if case let .acceptable(quality) = self { return quality }
        return nil
    }

    public var issues: [FaceQualityIssue] {
        if case let .rejected(issues) = self { return issues }
        return []
    }
}
