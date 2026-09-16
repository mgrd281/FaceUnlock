import CoreVideo
import XCTest
@testable import FaceUnlock

/// Loads the model that ships inside the app bundle and checks the contract
/// `CoreMLFaceEmbeddingService` relies on. These run on the test host, so they
/// exercise the real compiled `FaceDescriptorModel.mlmodelc`.
final class CoreMLFaceEmbeddingServiceTests: XCTestCase {
    private func makeService() throws -> CoreMLFaceEmbeddingService {
        try XCTUnwrap(
            CoreMLFaceEmbeddingService(bundle: .main),
            "The bundled FaceDescriptorModel did not load — check that the .mlpackage is in Resources/"
        )
    }

    func testBundledModelLoadsAndReportsItsVersion() throws {
        let service = try makeService()
        XCTAssertEqual(service.source, .coreMLModel)
        XCTAssertTrue(service.producerVersion.hasPrefix("CoreML:FaceDescriptorModel@"))
        XCTAssertEqual(service.embeddingDimension, 512)
    }

    func testEmbeddingIsUnitLengthAndFinite() throws {
        let service = try makeService()
        let crop = try XCTUnwrap(CoreMLFaceEmbeddingService.blankCrop())
        let embedding = try service.embedding(forAlignedCrop: crop)
        XCTAssertEqual(embedding.dimension, 512)
        XCTAssertTrue(embedding.values.allSatisfy(\.isFinite))
        let norm = embedding.values.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
        XCTAssertEqual(norm, 1, accuracy: 1e-3)
    }

    func testDifferentInputsProduceDifferentDescriptors() throws {
        let service = try makeService()
        let grey = try XCTUnwrap(CoreMLFaceEmbeddingService.blankCrop())
        let patterned = try XCTUnwrap(CoreMLFaceEmbeddingService.blankCrop())
        CVPixelBufferLockBaseAddress(patterned, [])
        if let base = CVPixelBufferGetBaseAddress(patterned) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(patterned)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for row in 0..<FaceAligner.outputSize {
                for column in 0..<FaceAligner.outputSize {
                    let offset = row * bytesPerRow + column * 4
                    let value: UInt8 = ((row / 8 + column / 8) % 2 == 0) ? 30 : 220
                    bytes[offset] = value
                    bytes[offset + 1] = value
                    bytes[offset + 2] = value
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(patterned, [])

        let a = try service.embedding(forAlignedCrop: grey)
        let b = try service.embedding(forAlignedCrop: patterned)
        XCTAssertLessThan(a.cosineSimilarity(to: b), 0.99)
    }
}
