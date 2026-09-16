import CoreVideo
import Foundation
import Vision
@testable import FaceUnlock

/// A camera that yields a fixed number of synthetic frames.
///
/// The pixel buffers are real `CVPixelBuffer`s so that anything downstream which
/// reads them behaves normally, but nothing about them is a face — the detector
/// and quality stages are faked alongside.
actor FakeCameraManager: CameraManaging {
    private let frameCount: Int
    private let startError: FaceUnlockError?
    private var running = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(frameCount: Int, startError: FaceUnlockError? = nil) {
        self.frameCount = frameCount
        self.startError = startError
    }

    func isRunning() async -> Bool { running }

    func start(frameRate: Double) async throws -> AsyncStream<CameraFrame> {
        if let startError { throw startError }
        startCount += 1
        running = true
        let count = frameCount
        return AsyncStream { continuation in
            for index in 0..<count {
                guard let buffer = Self.makePixelBuffer() else { break }
                continuation.yield(
                    CameraFrame(
                        pixelBuffer: buffer,
                        timestamp: Double(index) * 0.1,
                        sequence: UInt64(index + 1)
                    )
                )
            }
            continuation.finish()
        }
    }

    func stop() async {
        stopCount += 1
        running = false
    }

    static func makePixelBuffer(size: Int = 64) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, size, size, kCVPixelFormatType_32BGRA, nil, &buffer
        )
        return status == kCVReturnSuccess ? buffer : nil
    }
}

/// Always reports exactly one face, centred and upright.
struct FakeFaceDetector: FaceDetecting {
    func detectFaces(in frame: CameraFrame) throws -> [DetectedFace] {
        let rect = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        return [
            DetectedFace(
                pixelRect: CGRect(
                    x: Double(frame.width) * 0.3, y: Double(frame.height) * 0.3,
                    width: Double(frame.width) * 0.4, height: Double(frame.height) * 0.4
                ),
                normalizedRect: rect,
                confidence: 0.95,
                pose: FacePose(),
                landmarks: nil
            )
        ]
    }
}

struct FakeQualityAnalyzer: FaceQualityAnalyzing {
    let acceptable: Bool

    func evaluate(faces: [DetectedFace], frame: CameraFrame) -> FaceQualityVerdict {
        guard acceptable else { return .rejected([.blurry], nil) }
        return .acceptable(
            FaceQuality(
                faceSize: 0.4, luminance: 0.5, sharpness: 0.8,
                landmarkConfidence: 0.9, motion: 0.02, pose: FacePose()
            )
        )
    }

    func reset() {}
}

struct FakeEmbedder: FaceEmbeddingProviding {
    let source = FaceEmbedding.Source.synthetic
    let producerVersion = Fake.producerVersion

    func embedding(for face: DetectedFace, in frame: CameraFrame) throws -> FaceEmbedding {
        Fake.embedding(seed: 1)
    }
}

struct FakeMatcher: FaceMatching {
    let matches: Bool
    let threshold: Double

    func match(_ embedding: FaceEmbedding, against profile: BiometricProfile) -> MatchResult {
        MatchResult(
            score: matches ? threshold + 0.05 : threshold - 0.3,
            threshold: threshold,
            bestSampleScore: matches ? threshold + 0.05 : threshold - 0.3,
            bestPose: .straight
        )
    }
}

/// Reports a constant assessment; the real heuristics are covered separately by
/// `LivenessAnalyzerTests` against synthetic sample sequences.
final class FakeLiveness: LivenessAnalyzing, @unchecked Sendable {
    private let score: Double
    private let disqualifier: String?
    private let lock = NSLock()
    private var recorded = 0

    init(score: Double, disqualifier: String?) {
        self.score = score
        self.disqualifier = disqualifier
    }

    func record(_ sample: LivenessSample) {
        lock.lock(); recorded += 1; lock.unlock()
    }

    func assess(configuration: BiometricProfile.LivenessConfiguration) -> LivenessAssessment {
        lock.lock()
        let sampleCount = recorded
        lock.unlock()
        return LivenessAssessment(
            score: score,
            signals: LivenessSignals(),
            sampleCount: sampleCount,
            disqualifier: disqualifier,
            // Never ask for a challenge: the coordinator's challenge handling is a
            // separate concern from what these tests are checking.
            suggestedChallenge: nil
        )
    }

    func challengeSatisfied(_ challenge: LivenessChallenge) -> Bool { true }

    func reset() {
        lock.lock(); recorded = 0; lock.unlock()
    }
}

actor FakeUnlockCoordinator: UnlockCoordinating {
    private(set) var attemptCount = 0
    var result: Result<UnlockOutcome, FaceUnlockError> = .success(
        UnlockOutcome(
            providerIdentifier: "fake",
            providerName: "Fake provider",
            capability: .supported,
            completedAt: Date()
        )
    )

    func bestAvailableCapability() async -> SessionUnlockCapability { .supported }

    func providerSummaries() async -> [ProviderSummary] { [] }

    func unlock() async throws -> UnlockOutcome {
        attemptCount += 1
        return try result.get()
    }
}
