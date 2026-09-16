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
    /// Carries the measurements as well as the issues: a user told "move closer"
    /// deserves to see how close they actually are, and it is the only way to
    /// tell a badly chosen threshold from a genuinely bad frame.
    case rejected([FaceQualityIssue], FaceQuality?)

    public var quality: FaceQuality? {
        if case let .acceptable(quality) = self { return quality }
        return nil
    }

    /// What was measured, whether or not the frame was accepted.
    public var measured: FaceQuality? {
        switch self {
        case let .acceptable(quality): return quality
        case let .rejected(_, quality): return quality
        }
    }

    public var issues: [FaceQualityIssue] {
        if case let .rejected(issues, _) = self { return issues }
        return []
    }
}

extension FaceQuality {
    /// A compact, non-sensitive readout of the measurements, for the enrolment
    /// screen and diagnostics. Contains no descriptor and no image data.
    public var readout: String {
        String(
            format: "face %.0f%% · light %.0f%% · sharp %.0f%%",
            faceSize * 100, luminance * 100, sharpness * 100
        )
    }
}
