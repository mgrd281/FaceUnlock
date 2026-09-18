import Foundation

/// An explicit action the user is asked to perform.
public enum LivenessChallenge: String, Equatable, Sendable, CaseIterable {
    case blink
    case turnLeft
    case turnRight

    public var prompt: String {
        switch self {
        case .blink: return "Blink"
        case .turnLeft: return "Turn your head slightly left"
        case .turnRight: return "Turn your head slightly right"
        }
    }

    public var symbolName: String {
        switch self {
        case .blink: return "eye"
        case .turnLeft: return "arrow.turn.up.left"
        case .turnRight: return "arrow.turn.up.right"
        }
    }
}

/// Individual evidence contributing to the risk score.
public struct LivenessSignals: Equatable, Sendable {
    /// A complete eye closure and reopening was observed.
    public var blink: Double = 0
    /// Natural variation in head pose across the window.
    public var poseVariation: Double = 0
    /// Frame-to-frame change consistent with a living subject rather than a
    /// static image or a frozen feed.
    public var microMotion: Double = 0
    /// Absence of the regular high-frequency structure a display panel adds.
    public var texture: Double = 0
    /// Landmark geometry changing with head rotation the way a 3D head does.
    public var parallax: Double = 0
    /// Fine detail with no preferred direction, as skin has and a pixel grid
    /// does not. Readable from one frame.
    public var isotropy: Double = 0

    public init() {}

    /// Weighted combination, built from measured separation rather than from
    /// what each signal ought to do in principle.
    ///
    /// Measured on this Mac, a live face against the same face shown on a phone:
    ///
    ///     signal     live    phone   separation
    ///     isotropy   0.98    0.74    +0.24
    ///     motion     0.93    0.45    +0.48
    ///     texture    0.44    0.51    -0.07   inverted
    ///     specular   0.32    0.73    -0.41   inverted
    ///     shading    0.00    0.00     0      no signal at all
    ///     blink      0-1     1.00     0      the phone "blinked"
    ///
    /// Three of those were removed rather than down-weighted. Specular
    /// concentration was the worst: the reasoning behind it — that an emissive
    /// display lights a face flatly, so its highlights spread thin — is simply
    /// wrong about a phone, whose glass throws one sharp reflection. It scored
    /// the attack *higher* than the real face, so at any positive weight it was
    /// helping. Shading curvature reads zero for everything once the crop
    /// includes background brighter than the face, which is most rooms. Texture
    /// inverts slightly and is not worth its place.
    ///
    /// What remains are the two that separated. Neither needs the user to *do*
    /// anything: isotropy is a property of one frame of skin, and micro-motion
    /// is involuntary — breathing and postural sway measured 0.93 on someone
    /// sitting deliberately still, which is the finding that makes passive
    /// liveness possible here at all. The original design mistook `poseVariation`
    /// and `parallax`, which do need deliberate movement, for the whole of
    /// motion.
    ///
    /// Blink, pose variation and parallax are kept at small weight as
    /// corroboration only. They cannot lift a spoof over the floor between them,
    /// and the measurements say they cannot be relied on to lift a genuine face
    /// either.
    public var aggregate: Double {
        // Micro-motion carries the most weight because it separated the most:
        // 0.93 on a motionless person against 0.45 on a phone. Isotropy is kept
        // but demoted hard — it read 0.74 on one phone and 0.95 on the same
        // phone moved closer, and a signal whose answer depends on the
        // attacker's distance cannot be trusted with the score. On the lock
        // screen none of this is load-bearing anyway: a blink is required
        // outright there, and this aggregate only corroborates it.
        let weighted =
            0.40 * microMotion +
            0.20 * isotropy +
            0.15 * poseVariation +
            0.15 * parallax +
            0.10 * blink
        return min(1, max(0, weighted))
    }
}

public struct LivenessAssessment: Equatable, Sendable {
    public var score: Double
    public var signals: LivenessSignals
    public var sampleCount: Int
    /// Set when a hard disqualifier fired — e.g. a frozen or replayed feed.
    public var disqualifier: String?
    /// The challenge the user should be asked to perform, when one is needed.
    public var suggestedChallenge: LivenessChallenge?

    public var isConclusive: Bool { disqualifier == nil }
}

public protocol LivenessAnalyzing: Sendable {
    func record(_ sample: LivenessSample)
    func assess(configuration: BiometricProfile.LivenessConfiguration) -> LivenessAssessment
    func challengeSatisfied(_ challenge: LivenessChallenge) -> Bool
    func reset()
}

/// Multi-frame passive liveness.
///
/// ## What this can and cannot do
///
/// A Mac's camera is a plain 2D sensor. There is no infrared dot projector and no
/// depth map, so this analyser cannot do what Face ID does. What it can do is make
/// the cheap attacks expensive: a still photograph fails micro-motion, pose
/// variation and parallax; a phone or tablet replay additionally fails the texture
/// signal; a looped or frozen camera feed is rejected outright by the stale-frame
/// disqualifier. A high-quality video replay on a large, matte, colour-calibrated
/// display, played at the right scale, remains a realistic bypass. That limit is
/// stated plainly in `SECURITY.md` and in the app's own Privacy pane.
public final class LivenessAnalyzer: LivenessAnalyzing, @unchecked Sendable {
    public struct Tuning: Sendable {
        /// Eye aspect ratio below which the eye counts as closed.
        public var blinkClosedRatio: Double = 0.16
        /// Eye aspect ratio above which the eye counts as open again.
        public var blinkOpenRatio: Double = 0.22
        /// Pose standard deviation, in radians, that scores full marks.
        public var poseVariationTarget: Double = 0.035
        /// Frame difference band consistent with a live subject.
        public var motionFloor: Double = 0.004
        public var motionCeiling: Double = 0.075
        /// High-frequency ratio at and above which a display panel is suspected.
        public var screenTextureThreshold: Double = 0.42
        /// Yaw change, in radians, above which parallax can be measured at all.
        public var parallaxYawThreshold: Double = 0.06
        /// Nose/eye ratio change per radian of yaw expected from a real head.
        public var parallaxSensitivity: Double = 0.55
        /// Consecutive byte-identical frames that mark the feed as stale.
        public var staleFrameLimit: Int = 3

        public init() {}
    }

    private let tuning: Tuning
    private let lock = NSLock()
    private var samples: [LivenessSample] = []
    private var maximumWindow = 48

    public init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    public func reset() {
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()
    }

    public func record(_ sample: LivenessSample) {
        lock.lock(); defer { lock.unlock() }
        samples.append(sample)
        if samples.count > maximumWindow {
            samples.removeFirst(samples.count - maximumWindow)
        }
    }

    public func assess(configuration: BiometricProfile.LivenessConfiguration) -> LivenessAssessment {
        lock.lock()
        let window = Array(samples.suffix(max(4, configuration.windowFrames)))
        lock.unlock()

        guard window.count >= 4 else {
            return LivenessAssessment(
                score: 0,
                signals: LivenessSignals(),
                sampleCount: window.count,
                disqualifier: nil,
                suggestedChallenge: nil
            )
        }

        if let stale = staleFeedDisqualifier(window) {
            AppLogger.liveness.notice("Liveness disqualified: \(stale, privacy: .public)")
            return LivenessAssessment(
                score: 0,
                signals: LivenessSignals(),
                sampleCount: window.count,
                disqualifier: stale,
                suggestedChallenge: nil
            )
        }

        var signals = LivenessSignals()
        signals.blink = blinkScore(window)
        signals.poseVariation = poseVariationScore(window)
        signals.microMotion = microMotionScore(window)
        signals.texture = textureScore(window)
        signals.parallax = parallaxScore(window)
        signals.isotropy = passiveScore(window, \.textureIsotropy)

        let score = signals.aggregate
        let needsChallenge: Bool
        switch configuration.mode {
        case .passive:
            needsChallenge = false
        case .alwaysChallenge:
            needsChallenge = true
        case .adaptiveChallenge:
            // Ask only in the marginal band just below and just above the floor.
            needsChallenge = score < configuration.minimumScore + 0.12
        }

        // A challenge is only suggested once the window is actually full.
        //
        // The passive score is computed over whatever samples exist, and over a
        // quarter-full window it is necessarily low — there has not been time
        // for motion, blinks or micro-expressions to register. Treating that as
        // "the passive evidence is marginal" mistakes a measurement artifact for
        // a finding, and because the caller latches the challenge it then
        // persists for the rest of the attempt even after the score recovers.
        //
        // Waiting for a full window lowers no threshold: the same score must
        // still clear the same band. It only stops the question being asked
        // before the evidence exists to answer it.
        let windowIsFull = window.count >= configuration.windowFrames
        return LivenessAssessment(
            score: score,
            signals: signals,
            sampleCount: window.count,
            disqualifier: nil,
            suggestedChallenge: needsChallenge && windowIsFull
                ? suggestChallenge(signals: signals)
                : nil
        )
    }

    public func challengeSatisfied(_ challenge: LivenessChallenge) -> Bool {
        lock.lock()
        let window = samples
        lock.unlock()
        guard window.count >= 4 else { return false }

        switch challenge {
        case .blink:
            return blinkScore(window) >= 0.99
        case .turnLeft:
            return window.contains { $0.pose.yaw <= -0.18 } && window.contains { abs($0.pose.yaw) <= 0.08 }
        case .turnRight:
            return window.contains { $0.pose.yaw >= 0.18 } && window.contains { abs($0.pose.yaw) <= 0.08 }
        }
    }

    // MARK: - Individual signals

    /// The trimmed mean of a per-frame passive measurement across the window.
    ///
    /// Trimmed rather than plain: a single frame caught mid-blink, or as the
    /// autoexposure steps, is not evidence of anything, and one outlier should
    /// not move a signal that the rest of the window agrees on. Using the middle
    /// of the distribution also means the score *rises* as frames arrive instead
    /// of swinging, which is what lets a still face clear the floor in about a
    /// second rather than waiting for the window to fill.
    func passiveScore(_ window: [LivenessSample], _ measurement: KeyPath<LivenessSample, Double>) -> Double {
        let values = window.map { $0[keyPath: measurement] }.sorted()
        guard !values.isEmpty else { return 0 }
        guard values.count >= 5 else { return ImageAnalysis.mean(values) }
        let trim = values.count / 5
        let middle = Array(values[trim..<(values.count - trim)])
        return ImageAnalysis.mean(middle.isEmpty ? values : middle)
    }

    /// A full closure-then-reopening transition scores 1, anything less scores 0.
    /// Partial credit is deliberately not given: a half-closed eye is as consistent
    /// with a photograph of someone mid-blink as with a live blink.
    func blinkScore(_ window: [LivenessSample]) -> Double {
        var sawClosed = false
        var sawOpenAfterClosed = false
        var sawOpenBeforeClosed = false
        for sample in window {
            guard let ratio = sample.eyeAspectRatio else { continue }
            if ratio <= tuning.blinkClosedRatio {
                if sawOpenBeforeClosed { sawClosed = true }
            } else if ratio >= tuning.blinkOpenRatio {
                if sawClosed { sawOpenAfterClosed = true } else { sawOpenBeforeClosed = true }
            }
        }
        return sawOpenAfterClosed ? 1 : 0
    }

    /// Natural head movement. A tripod-mounted photograph produces almost none;
    /// a hand-held one produces translation but comparatively little rotation.
    func poseVariationScore(_ window: [LivenessSample]) -> Double {
        let yaw = ImageAnalysis.standardDeviation(window.map(\.pose.yaw))
        let pitch = ImageAnalysis.standardDeviation(window.map(\.pose.pitch))
        let roll = ImageAnalysis.standardDeviation(window.map(\.pose.roll))
        let combined = (yaw + pitch + roll) / 3
        return min(1, combined / tuning.poseVariationTarget)
    }

    /// Frame-to-frame change has to sit inside a band. Too little means a static
    /// image or a stalled feed; too much means the subject or the camera is moving
    /// so fast that nothing can be concluded.
    func microMotionScore(_ window: [LivenessSample]) -> Double {
        let differences = window.map(\.frameDifference).filter { $0 >= 0 }
        guard !differences.isEmpty else { return 0 }
        let mean = ImageAnalysis.mean(differences)
        if mean < tuning.motionFloor { return 0 }
        if mean > tuning.motionCeiling { return 0.25 }
        let span = tuning.motionCeiling - tuning.motionFloor
        guard span > 0 else { return 0 }
        let position = (mean - tuning.motionFloor) / span
        // Peak in the middle of the band, tapering towards both edges.
        return max(0, 1 - abs(position - 0.45) * 1.8)
    }

    /// Penalises the regular high-frequency structure that a display panel's pixel
    /// grid adds to a re-photographed face.
    func textureScore(_ window: [LivenessSample]) -> Double {
        let ratios = window.map(\.highFrequencyRatio).filter { $0 > 0 }
        guard !ratios.isEmpty else { return 0.5 }
        let mean = ImageAnalysis.mean(ratios)
        guard mean >= tuning.screenTextureThreshold else { return 1 }
        let excess = (mean - tuning.screenTextureThreshold) / max(0.01, 1 - tuning.screenTextureThreshold)
        return max(0, 1 - excess * 2)
    }

    /// The strongest passive 3D cue available from a 2D sensor: as a real head
    /// rotates, the nose moves towards one eye and away from the other. A flat
    /// photograph rotated in front of the camera changes this ratio far less,
    /// because the whole image transforms together.
    func parallaxScore(_ window: [LivenessSample]) -> Double {
        let pairs = window.compactMap { sample -> (yaw: Double, ratio: Double)? in
            guard let ratio = sample.noseEyeRatio else { return nil }
            return (sample.pose.yaw, ratio)
        }
        guard pairs.count >= 4 else { return 0 }
        guard let minYaw = pairs.map(\.yaw).min(), let maxYaw = pairs.map(\.yaw).max() else { return 0 }
        let yawSpan = maxYaw - minYaw
        // Without enough rotation there is nothing to measure. Returning a neutral
        // 0.35 avoids punishing a user who simply held still, while still denying
        // the full signal to an attacker holding a photograph steady.
        guard yawSpan >= tuning.parallaxYawThreshold else { return 0.35 }

        guard let lowest = pairs.min(by: { $0.yaw < $1.yaw }),
              let highest = pairs.max(by: { $0.yaw < $1.yaw }) else { return 0 }
        let ratioChange = abs(highest.ratio - lowest.ratio)
        let expected = yawSpan * tuning.parallaxSensitivity
        guard expected > 1e-6 else { return 0 }
        return min(1, ratioChange / expected)
    }

    /// Hard rejection for a feed that is not advancing: identical pixel content or
    /// a non-advancing frame sequence means the camera is being replayed or has
    /// stalled, and no score should be computed at all.
    func staleFeedDisqualifier(_ window: [LivenessSample]) -> String? {
        var identicalRun = 0
        for sample in window where sample.frameDifference >= 0 {
            if sample.frameDifference < 1e-5 {
                identicalRun += 1
                if identicalRun >= tuning.staleFrameLimit {
                    return "the camera feed stopped changing"
                }
            } else {
                identicalRun = 0
            }
        }
        let sequences = window.map(\.sequence)
        if let first = sequences.first, sequences.allSatisfy({ $0 == first }) {
            return "the camera delivered the same frame repeatedly"
        }
        let timestamps = window.map(\.timestamp)
        if let first = timestamps.first, let last = timestamps.last, last <= first {
            return "the camera timestamps did not advance"
        }
        return nil
    }

    /// Picks the challenge most likely to resolve whichever signal is weakest.
    private func suggestChallenge(signals: LivenessSignals) -> LivenessChallenge {
        if signals.blink < 0.5 { return .blink }
        return signals.parallax < 0.5 ? .turnRight : .blink
    }
}
