import Foundation

/// Head orientation in radians, as reported by Vision's face observation.
public struct FacePose: Equatable, Codable, Sendable {
    public var yaw: Double
    public var pitch: Double
    public var roll: Double

    public init(yaw: Double = 0, pitch: Double = 0, roll: Double = 0) {
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
    }

    public static let neutral = FacePose()

    /// Angular distance to another pose, used for enrollment step matching.
    public func angularDistance(to other: FacePose) -> Double {
        let dy = yaw - other.yaw
        let dp = pitch - other.pitch
        let dr = roll - other.roll
        return (dy * dy + dp * dp + dr * dr).squareRoot()
    }
}

/// The guided head positions requested during enrollment.
public enum EnrollmentPose: String, CaseIterable, Codable, Sendable, Identifiable {
    case straight
    case left
    case right
    case up
    case down
    case neutralExpression

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .straight: return "Look straight ahead"
        case .left: return "Turn your head slightly left"
        case .right: return "Turn your head slightly right"
        case .up: return "Tilt your head slightly up"
        case .down: return "Tilt your head slightly down"
        case .neutralExpression: return "Relax your expression"
        }
    }

    public var instruction: String {
        switch self {
        case .straight: return "Face the camera directly and hold still."
        case .left: return "Turn just far enough that one ear starts to hide."
        case .right: return "Turn just far enough that the other ear starts to hide."
        case .up: return "Lift your chin a little — keep both eyes visible."
        case .down: return "Lower your chin a little — keep both eyes visible."
        case .neutralExpression: return "Look straight ahead with a neutral, relaxed face."
        }
    }

    /// Short label for compact chips.
    public var shortTitle: String {
        switch self {
        case .straight: return "Straight"
        case .left: return "Left"
        case .right: return "Right"
        case .up: return "Up"
        case .down: return "Down"
        case .neutralExpression: return "Neutral"
        }
    }

    public var symbolName: String {
        switch self {
        case .straight: return "person.crop.square"
        case .left: return "arrow.turn.up.left"
        case .right: return "arrow.turn.up.right"
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .neutralExpression: return "face.smiling"
        }
    }

    /// Which head-rotation axis this step exercises.
    public enum Axis: String, Codable, Sendable {
        /// Face the camera; both axes must be near zero.
        case none
        case yaw
        case pitch
    }

    public var axis: Axis {
        switch self {
        case .straight, .neutralExpression: return .none
        case .left, .right: return .yaw
        case .up, .down: return .pitch
        }
    }

    /// True for the second pose of an opposed pair, which must lean the opposite
    /// way to the first.
    public var isOpposite: Bool {
        self == .right || self == .down
    }

    /// How far the head must lean, in radians, for this step to count.
    ///
    /// Deliberately expressed as a magnitude rather than a signed target angle.
    /// Vision's sign convention for `yaw` and `pitch` is not something to guess
    /// at: if it were assumed backwards, the "turn left" step could never be
    /// satisfied no matter how far the user turned. Instead the coordinator
    /// records whichever sign the user produces for the first pose of a pair and
    /// requires the opposite sign for its partner — which is the property that
    /// actually matters, since the point is to capture two distinct profiles.
    public var minimumLean: Double {
        switch axis {
        case .none: return 0
        case .yaw: return 0.22    // ≈ 12.5°, in LandmarkPoseEstimator's units
        case .pitch: return 0.18  // nose-drop proxy units, not an angle
        }
    }

    /// For `.none` steps, how near to the baseline the head must be.
    public var centredTolerance: Double { 0.16 }

    /// How many accepted samples this step requires.
    public var requiredSamples: Int { 3 }
}
