import CoreML
import CoreVideo
import Foundation
import Vision

public protocol FaceEmbeddingProviding: Sendable {
    /// Identifier stored alongside every descriptor. Changing the pipeline must
    /// change this string so that old profiles are never compared against new
    /// descriptors.
    var producerVersion: String { get }
    var source: FaceEmbedding.Source { get }
    func embedding(for face: DetectedFace, in frame: CameraFrame) throws -> FaceEmbedding
}

/// The default, entirely on-device descriptor.
///
/// ## Why this design
///
/// Apple ships no public face-recognition embedding API. The options were:
///
/// 1. `VNGenerateImageFeaturePrintRequest` — public, on-device, Neural Engine
///    accelerated, no model to bundle and no licence to honour. It is a
///    general-purpose visual descriptor, so it needs a tightly aligned crop and
///    a per-user calibrated threshold to discriminate faces well.
/// 2. A bundled third-party Core ML face network (ArcFace, FaceNet …) — much
///    stronger for identity, but redistribution licences vary and a bundled model
///    cannot be shipped without checking each one. FaceUnlock therefore supports
///    loading such a model but does not bundle one; see `CoreMLFaceEmbeddingService`.
/// 3. Training a network — out of scope for an app of this kind.
///
/// Option 1 was chosen as the default, combined with an explicit geometric
/// descriptor that contributes identity information the general descriptor is
/// weak on. Both halves are L2-normalised separately and then weighted, so the
/// feature print cannot drown out the geometry or vice versa.
public final class VisionFaceEmbeddingService: FaceEmbeddingProviding, @unchecked Sendable {
    public let source: FaceEmbedding.Source = .visionFeaturePrint
    public let producerVersion = "VNFeaturePrint.r2+geometry.v1"

    /// Relative weight of the feature print against the geometry descriptor.
    private let featurePrintWeight: Float = 0.72
    private let geometryWeight: Float = 0.28

    private let aligner: FaceAligner

    public init(aligner: FaceAligner = FaceAligner()) {
        self.aligner = aligner
    }

    public func embedding(for face: DetectedFace, in frame: CameraFrame) throws -> FaceEmbedding {
        guard let crop = aligner.alignedCrop(for: face, in: frame) else {
            throw FaceUnlockError.embeddingFailed("The face could not be aligned.")
        }
        let featurePrint = try featurePrintValues(for: crop)
        guard let landmarks = face.landmarks,
              let geometry = FaceGeometryDescriptor.descriptor(for: landmarks) else {
            throw FaceUnlockError.embeddingFailed("Not enough facial landmarks were visible.")
        }

        let normalizedPrint = FaceEmbedding.l2Normalized(featurePrint).map { $0 * featurePrintWeight }
        let normalizedGeometry = FaceEmbedding.l2Normalized(geometry).map { $0 * geometryWeight }
        return FaceEmbedding(
            source: source,
            producerVersion: producerVersion,
            values: normalizedPrint + normalizedGeometry
        )
    }

    private func featurePrintValues(for pixelBuffer: CVPixelBuffer) throws -> [Float] {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw FaceUnlockError.embeddingFailed("Feature print request failed: \(error.localizedDescription)")
        }
        guard let observation = request.results?.first as? VNFeaturePrintObservation else {
            throw FaceUnlockError.embeddingFailed("The feature print request returned no result.")
        }
        return try Self.floatValues(from: observation)
    }

    /// Vision may hand back either `Float` or `Double` elements depending on the
    /// revision, so both are handled rather than assumed.
    static func floatValues(from observation: VNFeaturePrintObservation) throws -> [Float] {
        let data = observation.data
        let count = observation.elementCount
        guard count > 0 else {
            throw FaceUnlockError.embeddingFailed("The feature print was empty.")
        }
        switch observation.elementType {
        case .float:
            guard data.count >= count * MemoryLayout<Float>.size else {
                throw FaceUnlockError.embeddingFailed("The feature print was truncated.")
            }
            return data.withUnsafeBytes { raw in
                Array(UnsafeBufferPointer(start: raw.bindMemory(to: Float.self).baseAddress, count: count))
            }
        case .double:
            guard data.count >= count * MemoryLayout<Double>.size else {
                throw FaceUnlockError.embeddingFailed("The feature print was truncated.")
            }
            return data.withUnsafeBytes { raw in
                let buffer = UnsafeBufferPointer(start: raw.bindMemory(to: Double.self).baseAddress, count: count)
                return buffer.map { Float($0) }
            }
        default:
            throw FaceUnlockError.embeddingFailed("Unsupported feature print element type.")
        }
    }
}

/// Optional drop-in for a purpose-trained Core ML face embedding model.
///
/// No model is bundled with FaceUnlock: doing so would mean redistributing
/// third-party weights whose licences differ and would have to be audited one by
/// one. Instead, if a compiled model is present the app uses it and records its
/// identity (file name plus SHA-256 of the compiled bundle) in the descriptor's
/// `producerVersion`, so profiles enrolled with one model are never matched
/// against descriptors from another.
///
/// Expected location, in order:
/// 1. `FaceEmbedding.mlmodelc` inside the app bundle's resources.
/// 2. `~/Library/Application Support/de.faceunlock.mac/Models/FaceEmbedding.mlmodelc`.
///
/// The model must take a 160×160 BGRA image and return a single `MLMultiArray`.
public final class CoreMLFaceEmbeddingService: FaceEmbeddingProviding, @unchecked Sendable {
    public let source: FaceEmbedding.Source = .coreMLModel
    public let producerVersion: String

    private let model: VNCoreMLModel
    private let aligner: FaceAligner

    public init?(aligner: FaceAligner = FaceAligner(), bundle: Bundle = .main, fileManager: FileManager = .default) {
        guard let url = Self.locateModel(bundle: bundle, fileManager: fileManager) else { return nil }
        let configuration = MLModelConfiguration()
        // `.all` lets Core ML pick the Neural Engine on Apple silicon and fall back
        // to the GPU or CPU elsewhere.
        configuration.computeUnits = .all
        guard let mlModel = try? MLModel(contentsOf: url, configuration: configuration),
              let visionModel = try? VNCoreMLModel(for: mlModel) else {
            AppLogger.recognition.error("A Core ML embedding model was present but could not be loaded")
            return nil
        }
        self.model = visionModel
        self.aligner = aligner
        self.producerVersion = "CoreML:\(url.lastPathComponent)@\(Self.digest(of: url, fileManager: fileManager))"
        AppLogger.recognition.notice(
            "Using the Core ML embedding model \(self.producerVersion, privacy: .public)"
        )
    }

    public func embedding(for face: DetectedFace, in frame: CameraFrame) throws -> FaceEmbedding {
        guard let crop = aligner.alignedCrop(for: face, in: frame) else {
            throw FaceUnlockError.embeddingFailed("The face could not be aligned.")
        }
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: crop, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw FaceUnlockError.embeddingFailed("The embedding model failed: \(error.localizedDescription)")
        }
        guard let observation = request.results?.first as? VNCoreMLFeatureValueObservation,
              let multiArray = observation.featureValue.multiArrayValue else {
            throw FaceUnlockError.embeddingFailed("The embedding model returned no vector.")
        }
        var values = [Float](repeating: 0, count: multiArray.count)
        for index in 0..<multiArray.count {
            values[index] = multiArray[index].floatValue
        }
        return FaceEmbedding(source: source, producerVersion: producerVersion, values: values)
    }

    private static func locateModel(bundle: Bundle, fileManager: FileManager) -> URL? {
        if let bundled = bundle.url(forResource: "FaceEmbedding", withExtension: "mlmodelc") {
            return bundled
        }
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let candidate = support
            .appendingPathComponent("de.faceunlock.mac/Models/FaceEmbedding.mlmodelc", isDirectory: true)
        return fileManager.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Short SHA-256 prefix over the compiled model's `model.mil`, enough to
    /// distinguish two different models without hashing the whole directory.
    private static func digest(of url: URL, fileManager: FileManager) -> String {
        let candidate = url.appendingPathComponent("model.mil")
        let target = fileManager.fileExists(atPath: candidate.path) ? candidate : url
        guard let data = try? Data(contentsOf: target, options: .mappedIfSafe) else { return "unknown" }
        return ModelDigest.shortHex(of: data)
    }
}
