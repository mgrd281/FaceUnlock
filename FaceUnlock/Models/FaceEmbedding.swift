import Foundation

/// A fixed-length, L2-normalised descriptor of one face crop.
///
/// FaceUnlock stores descriptors, never imagery. A descriptor is not reversible
/// into a photograph, but it is still biometric data, so it is encrypted at rest
/// (see `EncryptionService`).
public struct FaceEmbedding: Equatable, Codable, Sendable {
    /// Which descriptor producer generated `values`. Descriptors from different
    /// producers are never comparable, so the tag is part of the stored data.
    public enum Source: String, Codable, Sendable {
        case visionFeaturePrint
        case coreMLModel
        case synthetic  // tests only
    }

    public let source: Source
    /// Identifier of the exact producer revision, e.g. `"VNFeaturePrint.r2+geometry.v1"`.
    public let producerVersion: String
    public let values: [Float]

    public init(source: Source, producerVersion: String, values: [Float]) {
        self.source = source
        self.producerVersion = producerVersion
        self.values = Self.l2Normalized(values)
    }

    /// Creates an embedding without renormalising — used when values are known
    /// to be unit length already (decoding a stored profile).
    public init(source: Source, producerVersion: String, preNormalizedValues: [Float]) {
        self.source = source
        self.producerVersion = producerVersion
        self.values = preNormalizedValues
    }

    public var dimension: Int { values.count }

    /// True when two embeddings come from the same producer and have equal length.
    public func isComparable(with other: FaceEmbedding) -> Bool {
        source == other.source
            && producerVersion == other.producerVersion
            && dimension == other.dimension
            && dimension > 0
    }

    /// Cosine similarity in `-1...1`. Both operands are unit length, so this is a
    /// plain dot product.
    public func cosineSimilarity(to other: FaceEmbedding) -> Double {
        guard isComparable(with: other) else { return -1 }
        var sum: Double = 0
        for index in 0..<values.count {
            sum += Double(values[index]) * Double(other.values[index])
        }
        return min(1, max(-1, sum))
    }

    /// Euclidean distance between the unit vectors, in `0...2`.
    public func normalizedEuclideanDistance(to other: FaceEmbedding) -> Double {
        guard isComparable(with: other) else { return .infinity }
        var sum: Double = 0
        for index in 0..<values.count {
            let delta = Double(values[index]) - Double(other.values[index])
            sum += delta * delta
        }
        return sum.squareRoot()
    }

    static func l2Normalized(_ values: [Float]) -> [Float] {
        var sumOfSquares: Double = 0
        for value in values { sumOfSquares += Double(value) * Double(value) }
        let norm = sumOfSquares.squareRoot()
        // A zero vector cannot be normalised; returning it unchanged keeps the
        // comparison functions well defined (similarity 0 against anything).
        guard norm > 1e-9 else { return values }
        return values.map { Float(Double($0) / norm) }
    }
}

/// The similarity metric used when matching. Exposed for tests and diagnostics,
/// not as a user-facing setting.
public enum SimilarityMetric: String, Codable, Sendable, CaseIterable {
    case cosine
    case normalizedEuclidean

    /// Returns a score in `0...1` where larger is more similar, so thresholds
    /// read the same way regardless of the metric.
    public func score(_ lhs: FaceEmbedding, _ rhs: FaceEmbedding) -> Double {
        switch self {
        case .cosine:
            return (lhs.cosineSimilarity(to: rhs) + 1) / 2
        case .normalizedEuclidean:
            let distance = lhs.normalizedEuclideanDistance(to: rhs)
            guard distance.isFinite else { return 0 }
            return max(0, 1 - distance / 2)
        }
    }
}
