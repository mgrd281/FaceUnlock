import Security
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
            // Compared as `String`: `CFString` has no usable `Equatable` conformance.
            XCTAssertEqual(
                item.accessibility as String,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
            )
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

/// The keychain fallback, which destroyed two enrolments before it was found.
///
/// `KeychainService` prefers the data-protection keychain and falls back to the
/// login keychain. These tests pin the two statuses that mean "ask the other
/// one", because conflating them is not a cosmetic bug: it made the app mint a
/// fresh encryption key over the top of the real one.
final class KeychainFallbackTests: XCTestCase {
    /// Records which keychain each operation was aimed at.
    private final class Spy {
        var reads: [Bool] = []
        var deletes: [Bool] = []
    }

    func testAReadFallsBackToTheLoginKeychainWhenTheItemIsNotInDataProtection() {
        // The real failure: the key lives in the login keychain because an
        // earlier run had downgraded. A data-protection read answers
        // `errSecItemNotFound`, which is *not* `errSecMissingEntitlement`, so the
        // fallback never fired and the caller concluded there was no key at all.
        let spy = Spy()
        let status = Self.simulate(readFallback: true, spy: spy) { dataProtection in
            spy.reads.append(dataProtection)
            return dataProtection ? errSecItemNotFound : errSecSuccess
        }
        XCTAssertEqual(status, errSecSuccess, "the login keychain holds the item and must be consulted")
        XCTAssertEqual(spy.reads, [true, false], "both keychains must be tried, in that order")
    }

    func testAGenuinelyAbsentItemIsStillReportedAsNotFound() {
        let spy = Spy()
        let status = Self.simulate(readFallback: true, spy: spy) { dataProtection in
            spy.reads.append(dataProtection)
            return errSecItemNotFound
        }
        XCTAssertEqual(status, errSecItemNotFound)
        XCTAssertEqual(spy.reads, [true, false])
    }

    /// Writes must not fall back merely because nothing was there to overwrite.
    func testAWriteDoesNotFallBackOnNotFound() {
        let spy = Spy()
        let status = Self.simulate(readFallback: false, spy: spy) { dataProtection in
            spy.reads.append(dataProtection)
            return errSecItemNotFound
        }
        XCTAssertEqual(status, errSecItemNotFound)
        XCTAssertEqual(spy.reads, [true], "a write must not be retried against the other keychain")
    }

    /// Mirrors `KeychainService.withKeychain`. The real method is private and
    /// talks to the system keychain, which a unit test must not touch; this
    /// reproduces its decision table so the table itself stays pinned.
    private static func simulate(
        readFallback: Bool,
        spy: Spy,
        _ operation: (Bool) -> OSStatus
    ) -> OSStatus {
        let missingEntitlement: OSStatus = -34018
        let status = operation(true)
        if status == missingEntitlement { return operation(false) }
        if readFallback, status == errSecItemNotFound {
            let fallback = operation(false)
            return fallback == errSecSuccess ? fallback : status
        }
        return status
    }
}
