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

/// The fallback descriptor, used only when the bundled Core ML network cannot
/// be loaded (see `CoreMLFaceEmbeddingService`). Entirely on-device.
///
/// ## Why it exists
///
/// Apple ships no public face-recognition embedding API. The options were:
///
/// 1. `VNGenerateImageFeaturePrintRequest` — public, on-device, Neural Engine
///    accelerated, no model to bundle and no licence to honour. It is a
///    general-purpose visual descriptor, so it needs a tightly aligned crop and
///    a per-user calibrated threshold to discriminate faces well.
/// 2. A bundled metric-learned Core ML face network — much stronger for
///    identity. FaceUnlock bundles one whose code and weights are MIT licensed
///    (`MODEL.md`), and uses it whenever it loads.
/// 3. Training a network — out of scope for an app of this kind.
///
/// Option 2 is the default. This class is option 1, combined with an explicit
/// geometric descriptor that contributes identity information the general
/// descriptor is weak on. Both halves are L2-normalised separately and then
/// weighted, so the feature print cannot drown out the geometry or vice versa.
/// It is kept so the app still works — with the wider, documented error margin —
/// if the model resource is missing or damaged.
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

/// The bundled, purpose-trained face-descriptor network.
///
/// `FaceDescriptorModel.mlpackage` (see `MODEL.md`) is an InceptionResnetV1
/// trained with a triplet/metric objective on VGGFace2, converted from
/// facenet-pytorch (MIT). Unlike the Vision feature print it is trained to put
/// two pictures of the *same identity* close together and everyone else far
/// away, which is exactly the question FaceUnlock asks. It runs entirely
/// on-device; Core ML picks the Neural Engine on Apple silicon.
///
/// The model's identity (its name and the version string baked into its
/// metadata, or a SHA-256 prefix of the compiled program when no version is
/// present) is recorded in every descriptor's `producerVersion`, so profiles
/// enrolled with one model are never matched against descriptors from another.
///
/// Lookup order:
/// 1. `FaceDescriptorModel.mlmodelc` inside the app bundle (Xcode compiles the
///    `.mlpackage` in `Resources/` into this automatically).
/// 2. `~/Library/Application Support/de.faceunlock.mac/Models/FaceDescriptorModel.mlmodelc`,
///    so a differently licensed or newer model can be dropped in without a rebuild.
///
/// The model must take a 160×160 RGB image and return a single `MLMultiArray`
/// (the bundled one returns a 512-element L2-normalised vector).
public final class CoreMLFaceEmbeddingService: FaceEmbeddingProviding, @unchecked Sendable {
    public static let modelName = "FaceDescriptorModel"

    public let source: FaceEmbedding.Source = .coreMLModel
    public let producerVersion: String
    /// Length of the vector the model produced during the load-time self-test.
    public let embeddingDimension: Int

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
        self.producerVersion = Self.identity(of: mlModel, at: url, fileManager: fileManager)

        // Run one blank crop through the network before accepting it. A model
        // that produces nothing, or a non-finite vector, must never become the
        // descriptor of record — the failure would only surface as "does not
        // recognise" during enrolment.
        guard let probe = Self.blankCrop(),
              let vector = try? Self.run(visionModel, on: probe),
              !vector.isEmpty, vector.allSatisfy(\.isFinite) else {
            AppLogger.recognition.error("The Core ML embedding model failed its self-test and is not used")
            return nil
        }
        self.embeddingDimension = vector.count
        AppLogger.recognition.notice(
            """
            Using the Core ML embedding model \(self.producerVersion, privacy: .public) \
            (\(vector.count, privacy: .public)-d)
            """
        )
    }

    public func embedding(for face: DetectedFace, in frame: CameraFrame) throws -> FaceEmbedding {
        guard let crop = aligner.alignedCrop(for: face, in: frame) else {
            throw FaceUnlockError.embeddingFailed("The face could not be aligned.")
        }
        return try embedding(forAlignedCrop: crop)
    }

    /// Embeds an already aligned 160×160 crop. Exposed so the model can be
    /// exercised without a camera.
    public func embedding(forAlignedCrop crop: CVPixelBuffer) throws -> FaceEmbedding {
        let values = try Self.run(model, on: crop)
        guard values.count == embeddingDimension else {
            throw FaceUnlockError.embeddingFailed(
                "The embedding model returned \(values.count) values, expected \(embeddingDimension)."
            )
        }
        return FaceEmbedding(source: source, producerVersion: producerVersion, values: values)
    }

    private static func run(_ model: VNCoreMLModel, on crop: CVPixelBuffer) throws -> [Float] {
        let request = VNCoreMLRequest(model: model)
        // The crop is already square and face-centred; Vision converts BGRA to the
        // RGB layout the model declares.
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
        return values
    }

    private static func locateModel(bundle: Bundle, fileManager: FileManager) -> URL? {
        if let bundled = bundle.url(forResource: modelName, withExtension: "mlmodelc") {
            return bundled
        }
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let candidate = support
            .appendingPathComponent("de.faceunlock.mac/Models/\(modelName).mlmodelc", isDirectory: true)
        return fileManager.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// `CoreML:<name>@<version>` when the model carries a version string in its
    /// metadata (the bundled one does), otherwise `CoreML:<name>@<sha256 prefix>`.
    /// The version is preferred because Xcode re-compiles the package on every
    /// clean build and the compiled bytes are not stable across Xcode releases,
    /// which would otherwise invalidate profiles for no real change.
    private static func identity(of model: MLModel, at url: URL, fileManager: FileManager) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        let metadata = model.modelDescription.metadata
        if let version = metadata[.versionString] as? String,
           !version.trimmingCharacters(in: .whitespaces).isEmpty {
            return "CoreML:\(name)@\(version)"
        }
        return "CoreML:\(name)@\(digest(of: url, fileManager: fileManager))"
    }

    /// Short SHA-256 prefix over the compiled model's `model.mil`, enough to
    /// distinguish two different models without hashing the whole directory.
    private static func digest(of url: URL, fileManager: FileManager) -> String {
        let candidate = url.appendingPathComponent("model.mil")
        let target = fileManager.fileExists(atPath: candidate.path) ? candidate : url
        guard let data = try? Data(contentsOf: target, options: .mappedIfSafe) else { return "unknown" }
        return ModelDigest.shortHex(of: data)
    }

    /// A mid-grey 160×160 BGRA buffer for the load-time self-test.
    static func blankCrop() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let size = FaceAligner.outputSize
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, size, size, kCVPixelFormatType_32BGRA, nil, &buffer
        )
        guard status == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0x80, CVPixelBufferGetBytesPerRow(buffer) * size)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}
