import Foundation
@testable import FaceUnlock

/// Deterministic fake descriptors.
///
/// The whole matching layer is built against `FaceEmbedding`, so the test suite
/// never needs a camera or a face image: it synthesises vectors with a known
/// angular relationship and checks the maths and the policy around it.
enum Fake {
    static let producerVersion = "test.v1"

    /// A reproducible pseudo-random unit vector.
    static func embedding(seed: UInt64, dimension: Int = 64) -> FaceEmbedding {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var values: [Float] = []
        values.reserveCapacity(dimension)
        for _ in 0..<dimension {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let normalized = Double(state >> 11) / Double(UInt64(1) << 53)
            values.append(Float(normalized * 2 - 1))
        }
        return FaceEmbedding(source: .synthetic, producerVersion: producerVersion, values: values)
    }

    /// A vector rotated away from `base` so that the cosine similarity is
    /// approximately `cos(angle)`.
    static func embedding(near base: FaceEmbedding, angle: Double, seed: UInt64 = 99) -> FaceEmbedding {
        let noise = embedding(seed: seed, dimension: base.dimension)
        // Gram-Schmidt: make the noise orthogonal to the base, then mix by angle.
        let dot = base.cosineSimilarity(to: noise)
        var orthogonal = [Float](repeating: 0, count: base.dimension)
        for index in 0..<base.dimension {
            orthogonal[index] = noise.values[index] - Float(dot) * base.values[index]
        }
        let normalizedOrthogonal = FaceEmbedding.l2Normalized(orthogonal)
        var mixed = [Float](repeating: 0, count: base.dimension)
        for index in 0..<base.dimension {
            mixed[index] = Float(cos(angle)) * base.values[index]
                + Float(sin(angle)) * normalizedOrthogonal[index]
        }
        return FaceEmbedding(source: .synthetic, producerVersion: producerVersion, values: mixed)
    }

    static func profile(
        embeddings: [FaceEmbedding],
        threshold: Double = 0.88,
        metric: SimilarityMetric = .cosine,
        preset: SensitivityPreset = .balanced
    ) -> BiometricProfile {
        BiometricProfile(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            embeddings: embeddings,
            poseTags: Array(repeating: EnrollmentPose.straight, count: embeddings.count),
            recognitionThreshold: threshold,
            metric: metric,
            livenessConfiguration: .default,
            calibratedFor: preset
        )
    }

    /// A sequence of samples that looks like a live person: the head drifts, the
    /// eyes blink, pixels change a little each frame and there is no panel texture.
    static func liveSamples(count: Int = 16) -> [LivenessSample] {
        (0..<count).map { index in
            let phase = Double(index)
            // A blink in the middle of the window.
            let eyeRatio: Double = (index == 7 || index == 8) ? 0.11 : 0.29
            return LivenessSample(
                timestamp: phase * 0.1,
                sequence: UInt64(index + 1),
                pose: FacePose(
                    yaw: sin(phase / 3) * 0.09,
                    pitch: cos(phase / 4) * 0.03,
                    roll: sin(phase / 5) * 0.02
                ),
                eyeAspectRatio: eyeRatio,
                // Tracks yaw the way a real 3D head does.
                noseEyeRatio: 1.0 + sin(phase / 3) * 0.09 * 0.6,
                frameDifference: index == 0 ? -1 : 0.030,
                highFrequencyRatio: 0.18
            )
        }
    }

    /// A printed photograph held in front of the camera: it moves a little, but
    /// the geometry does not change with yaw and the eyes never close.
    static func photoSamples(count: Int = 16) -> [LivenessSample] {
        (0..<count).map { index in
            let phase = Double(index)
            return LivenessSample(
                timestamp: phase * 0.1,
                sequence: UInt64(index + 1),
                pose: FacePose(yaw: sin(phase / 3) * 0.09, pitch: 0, roll: 0),
                eyeAspectRatio: 0.29,
                noseEyeRatio: 1.0,
                frameDifference: index == 0 ? -1 : 0.006,
                highFrequencyRatio: 0.20
            )
        }
    }

    /// A replay on a phone or tablet: the panel's pixel grid shows up as strong
    /// high-frequency content.
    static func screenReplaySamples(count: Int = 16) -> [LivenessSample] {
        liveSamples(count: count).map { sample in
            var copy = sample
            copy.highFrequencyRatio = 0.85
            copy.noseEyeRatio = 1.0
            return copy
        }
    }

    /// A stalled or looped feed: identical pixels frame after frame.
    static func frozenSamples(count: Int = 16) -> [LivenessSample] {
        // The subexpressions are annotated rather than inferred: two optional
        // Doubles and a ternary of integer literals in one call is enough to
        // push the type checker past its budget.
        (0..<count).map { index -> LivenessSample in
            let timestamp: TimeInterval = Double(index) * 0.1
            let eyeAspectRatio: Double? = 0.29
            let noseEyeRatio: Double? = 1.0
            let frameDifference: Double = index == 0 ? -1 : 0
            return LivenessSample(
                timestamp: timestamp,
                sequence: UInt64(index + 1),
                pose: FacePose(),
                eyeAspectRatio: eyeAspectRatio,
                noseEyeRatio: noseEyeRatio,
                frameDifference: frameDifference,
                highFrequencyRatio: 0.2
            )
        }
    }

    static func grid(size: Int = 8, generator: (Int, Int) -> Float) -> GrayscaleGrid {
        var values: [Float] = []
        for y in 0..<size {
            for x in 0..<size {
                values.append(generator(x, y))
            }
        }
        return GrayscaleGrid(width: size, height: size, values: values)
    }
}
