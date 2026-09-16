import XCTest
@testable import FaceUnlock

final class BiometricProfileStoreTests: XCTestCase {
    private var directory = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("faceunlock-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func makeStore() -> (BiometricProfileStore, InMemoryKeychainService) {
        let keychain = InMemoryKeychainService()
        let store = BiometricProfileStore(
            encryption: EncryptionService(keychain: keychain),
            directory: directory
        )
        return (store, keychain)
    }

    func testSaveAndLoadRoundTrip() throws {
        let (store, _) = makeStore()
        let profile = Fake.profile(embeddings: (1...6).map { Fake.embedding(seed: UInt64($0)) })
        XCTAssertFalse(store.hasProfile)
        try store.save(profile)
        XCTAssertTrue(store.hasProfile)

        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.embeddings.count, profile.embeddings.count)
        XCTAssertEqual(loaded.recognitionThreshold, profile.recognitionThreshold)
        XCTAssertEqual(loaded.poseTags, profile.poseTags)
        XCTAssertEqual(loaded.profileVersion, BiometricProfile.currentVersion)
    }

    func testLoadingWithNoProfileReturnsNil() throws {
        let (store, _) = makeStore()
        XCTAssertNil(try store.load())
    }

    /// The file on disk must not contain anything recognisable from the profile.
    func testStoredFileIsEncrypted() throws {
        let (store, _) = makeStore()
        try store.save(Fake.profile(embeddings: [Fake.embedding(seed: 1)]))
        let data = try Data(contentsOf: directory.appendingPathComponent("profile.bin"))
        XCTAssertFalse(data.starts(with: Data("{".utf8)))
        let asText = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(asText.contains("recognitionThreshold"))
        XCTAssertFalse(asText.contains("embeddings"))
    }

    func testFilePermissionsAreOwnerOnly() throws {
        let (store, _) = makeStore()
        try store.save(Fake.profile(embeddings: [Fake.embedding(seed: 1)]))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("profile.bin").path
        )
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.int16Value & 0o777, 0o600)
    }

    func testCorruptedFileIsReportedAsCorrupted() throws {
        let (store, _) = makeStore()
        try store.save(Fake.profile(embeddings: [Fake.embedding(seed: 1)]))
        let url = directory.appendingPathComponent("profile.bin")
        try Data(repeating: 0xAB, count: 256).write(to: url)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? FaceUnlockError, .profileCorrupted)
        }
    }

    func testSavingAnInvalidProfileIsRefused() {
        let (store, _) = makeStore()
        let invalid = BiometricProfile(
            createdAt: Date(), updatedAt: Date(),
            embeddings: [Fake.embedding(seed: 1)],
            poseTags: [],  // mismatched length
            recognitionThreshold: 0.9
        )
        XCTAssertThrowsError(try store.save(invalid))
    }

    func testThresholdOutOfRangeIsInvalid() {
        for threshold in [0.0, 0.4, 1.5, Double.nan] {
            let profile = Fake.profile(embeddings: [Fake.embedding(seed: 1)], threshold: threshold)
            XCTAssertFalse(profile.isStructurallyValid, "threshold \(threshold) must be rejected")
        }
    }

    func testForgetEverythingRemovesFileAndKey() throws {
        let (store, keychain) = makeStore()
        try store.save(Fake.profile(embeddings: [Fake.embedding(seed: 1)]))
        XCTAssertNotNil(try keychain.data(for: .profileEncryptionKey))

        try store.forgetEverything()

        XCTAssertFalse(store.hasProfile)
        XCTAssertNil(try keychain.data(for: .profileEncryptionKey))
        XCTAssertNil(try store.load())
    }

    func testSummaryExposesNoDescriptorValues() throws {
        let profile = Fake.profile(embeddings: (1...3).map { Fake.embedding(seed: UInt64($0)) })
        let summary = profile.summary
        XCTAssertEqual(summary.sampleCount, 3)
        XCTAssertEqual(summary.descriptorDimension, 64)
        XCTAssertEqual(summary.producerVersion, Fake.producerVersion)
    }
}
