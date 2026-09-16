import XCTest
@testable import FaceUnlock

final class CredentialStoreTests: XCTestCase {
    private func makeStore(expected: String) -> (CredentialStore, InMemoryKeychainService) {
        let keychain = InMemoryKeychainService()
        let store = CredentialStore(
            keychain: keychain,
            validator: StubPasswordValidator(expected: expected)
        )
        return (store, keychain)
    }

    func testAValidPasswordIsStored() async throws {
        let (store, keychain) = makeStore(expected: "hunter2")
        XCTAssertFalse(store.hasSavedPassword)
        try await store.validateAndStore(password: "hunter2", shortName: "tester")
        XCTAssertTrue(store.hasSavedPassword)
        XCTAssertNotNil(try keychain.data(for: .accountPassword))
    }

    func testAnIncorrectPasswordIsNeverStored() async {
        let (store, keychain) = makeStore(expected: "hunter2")
        do {
            try await store.validateAndStore(password: "wrong", shortName: "tester")
            XCTFail("expected validation to fail")
        } catch let error as FaceUnlockError {
            XCTAssertEqual(error, .credentialValidationFailed)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertFalse(store.hasSavedPassword)
        XCTAssertNil(try? keychain.data(for: .accountPassword))
    }

    func testAnEmptyPasswordIsRefusedWithoutTouchingTheDirectory() async {
        let (store, _) = makeStore(expected: "")
        do {
            try await store.validateAndStore(password: "", shortName: "tester")
            XCTFail("expected a refusal")
        } catch let error as FaceUnlockError {
            XCTAssertEqual(error, .credentialValidationFailed)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testRetrievingTheStoredPassword() async throws {
        let (store, _) = makeStore(expected: "hunter2")
        try await store.validateAndStore(password: "hunter2", shortName: "tester")
        let seen = try store.loadPasswordForSingleUse()
        XCTAssertEqual(seen, "hunter2")
    }

    func testRetrievingWithoutAStoredPasswordThrows() {
        let (store, _) = makeStore(expected: "hunter2")
        do {
            _ = try store.loadPasswordForSingleUse()
            XCTFail("expected credentialMissing")
        } catch let error as FaceUnlockError {
            XCTAssertEqual(error, .credentialMissing)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testRemovalIsImmediate() async throws {
        let (store, keychain) = makeStore(expected: "hunter2")
        try await store.validateAndStore(password: "hunter2", shortName: "tester")
        try store.removePassword()
        XCTAssertFalse(store.hasSavedPassword)
        XCTAssertNil(try keychain.data(for: .accountPassword))
    }

    func testRemovingWhenNothingIsStoredIsHarmless() {
        let (store, _) = makeStore(expected: "x")
        XCTAssertNoThrow(try store.removePassword())
    }
}
