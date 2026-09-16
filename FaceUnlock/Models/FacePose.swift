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

    /// The pose the sample is expected to land near, in radians.
    public var targetPose: FacePose {
        switch self {
        case .straight, .neutralExpression: return FacePose()
        case .left: return FacePose(yaw: -0.30)
        case .right: return FacePose(yaw: 0.30)
        case .up: return FacePose(pitch: 0.22)
        case .down: return FacePose(pitch: -0.22)
        }
    }

    /// How far the measured pose may deviate from `targetPose` and still count.
    public var tolerance: Double { 0.22 }

    /// How many accepted samples this step requires.
    public var requiredSamples: Int { 3 }
}
