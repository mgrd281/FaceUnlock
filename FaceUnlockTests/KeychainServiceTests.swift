import XCTest
@testable import FaceUnlock

final class KeychainServiceTests: XCTestCase {
    func testRoundTrip() throws {
        let keychain = InMemoryKeychainService()
        let payload = Data("not-a-real-secret".utf8)
        XCTAssertFalse(try keychain.containsItem(.accountPassword))
        try keychain.setData(payload, for: .accountPassword)
        XCTAssertTrue(try keychain.containsItem(.accountPassword))
        XCTAssertEqual(try keychain.data(for: .accountPassword), payload)
        try keychain.removeItem(.accountPassword)
        XCTAssertNil(try keychain.data(for: .accountPassword))
    }

    func testItemsAreIndependent() throws {
        let keychain = InMemoryKeychainService()
        try keychain.setData(Data([1]), for: .accountPassword)
        try keychain.setData(Data([2]), for: .profileEncryptionKey)
        try keychain.removeItem(.accountPassword)
        XCTAssertNil(try keychain.data(for: .accountPassword))
        XCTAssertEqual(try keychain.data(for: .profileEncryptionKey), Data([2]))
    }

    func testRemovingAMissingItemIsNotAnError() throws {
        let keychain = InMemoryKeychainService()
        XCTAssertNoThrow(try keychain.removeItem(.settingsMasterPassword))
    }

    func testFailuresPropagate() {
        let keychain = InMemoryKeychainService()
        keychain.injectedFailure = .keychainFailure(status: -25_300)
        XCTAssertThrowsError(try keychain.data(for: .accountPassword)) { error in
            XCTAssertEqual(error as? FaceUnlockError, .keychainFailure(status: -25_300))
        }
    }

    /// Every stored item must be device-local and non-syncing.
    func testAllItemsUseDeviceOnlyAccessibility() {
        for item in KeychainItem.allCases {
            XCTAssertEqual(item.accessibility, kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
            XCTAssertFalse(item.label.isEmpty)
        }
    }

    // MARK: Encryption

    func testEncryptionRoundTrip() throws {
        let service = EncryptionService(keychain: InMemoryKeychainService())
        let plaintext = Data("face descriptors would go here".utf8)
        let ciphertext = try service.encrypt(plaintext)
        XCTAssertNotEqual(ciphertext, plaintext)
        XCTAssertEqual(try service.decrypt(ciphertext), plaintext)
    }

    func testCiphertextDiffersEachTime() throws {
        let service = EncryptionService(keychain: InMemoryKeychainService())
        let plaintext = Data(repeating: 7, count: 128)
        let first = try service.encrypt(plaintext)
        let second = try service.encrypt(plaintext)
        XCTAssertNotEqual(first, second, "AES-GCM must use a fresh nonce per message")
    }

    func testTamperedCiphertextIsRejected() throws {
        let service = EncryptionService(keychain: InMemoryKeychainService())
        var ciphertext = try service.encrypt(Data("payload".utf8))
        ciphertext[ciphertext.count - 1] ^= 0xFF
        XCTAssertThrowsError(try service.decrypt(ciphertext)) { error in
            XCTAssertEqual(error as? FaceUnlockError, .profileCorrupted)
        }
    }

    func testDestroyingTheKeyMakesCiphertextUnreadable() throws {
        let keychain = InMemoryKeychainService()
        let service = EncryptionService(keychain: keychain)
        let ciphertext = try service.encrypt(Data("payload".utf8))
        try service.destroyKey()
        XCTAssertNil(try keychain.data(for: .profileEncryptionKey))
        XCTAssertThrowsError(try service.decrypt(ciphertext))
    }
}
