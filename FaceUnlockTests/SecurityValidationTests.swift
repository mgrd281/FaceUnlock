import XCTest
@testable import FaceUnlock

final class SecurityValidationTests: XCTestCase {
    private func verification(
        locked: Bool = true,
        onConsole: Bool = true,
        secureInput: Bool = false,
        bundleID: String? = "com.apple.loginwindow",
        authentic: Bool = true,
        accessibility: Bool = true
    ) -> LockScreenVerification {
        LockScreenVerification(
            screenIsLocked: locked,
            isOnConsoleSession: onConsole,
            secureInputActive: secureInput,
            frontmostBundleIdentifier: bundleID,
            frontmostIsAuthenticLoginWindow: authentic,
            accessibilityTrusted: accessibility
        )
    }

    func testAllConditionsMustHold() {
        XCTAssertTrue(verification().allowsCredentialEntry)
        XCTAssertNil(verification().refusalReason)
    }

    func testEverySingleFailedConditionRefuses() {
        let cases: [(String, LockScreenVerification)] = [
            ("unlocked screen", verification(locked: false)),
            ("not on console", verification(onConsole: false)),
            ("secure input active", verification(secureInput: true)),
            ("unverified frontmost process", verification(authentic: false)),
            ("no accessibility trust", verification(accessibility: false))
        ]
        for (name, subject) in cases {
            XCTAssertFalse(subject.allowsCredentialEntry, "\(name) must refuse")
            XCTAssertNotNil(subject.refusalReason, "\(name) must explain itself")
        }
    }

    /// A process merely *claiming* to be the login window is not enough; the
    /// cryptographic check is what decides.
    func testBundleIdentifierAloneIsNotTrusted() {
        let impostor = verification(bundleID: "com.apple.loginwindow", authentic: false)
        XCTAssertFalse(impostor.allowsCredentialEntry)
        XCTAssertEqual(
            impostor.refusalReason,
            "the frontmost process is not an Apple-signed login window (com.apple.loginwindow)"
        )
    }

    func testRefusalReasonsAreOrderedMostFundamentalFirst() {
        let everythingWrong = verification(
            locked: false, onConsole: false, secureInput: true, authentic: false, accessibility: false
        )
        XCTAssertEqual(everythingWrong.refusalReason, "the screen is not locked")
    }

    func testSecureInputIsTheLastGate() {
        XCTAssertEqual(
            verification(secureInput: true).refusalReason,
            "a secure input context owns the keyboard, so no synthetic input can reach it"
        )
    }

    // MARK: Provider behaviour

    func testAccessibilityProviderRefusesWhenSecureInputIsActive() async {
        let validator = StubSecurityValidator(verification: verification(secureInput: true))
        let credentials = StubCredentialStore(hasPassword: true)
        let provider = AccessibilityUnlockProvider(
            validator: validator, credentials: credentials, isEnabled: { true }
        )
        let canUnlock = await provider.canUnlockCurrentState()
        XCTAssertFalse(canUnlock)

        do {
            try await provider.attemptUnlock()
            XCTFail("the provider must not attempt entry")
        } catch let error as FaceUnlockError {
            guard case .unlockVerificationFailed = error else {
                return XCTFail("unexpected error \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(credentials.readCount, 0, "the password must never be read")
    }

    func testAccessibilityProviderRefusesWithoutASavedPassword() async {
        let validator = StubSecurityValidator(verification: verification())
        let provider = AccessibilityUnlockProvider(
            validator: validator,
            credentials: StubCredentialStore(hasPassword: false),
            isEnabled: { true }
        )
        let canUnlock = await provider.canUnlockCurrentState()
        XCTAssertFalse(canUnlock)
    }

    func testAccessibilityProviderStaysOffWhenNotOptedIn() async {
        let validator = StubSecurityValidator(verification: verification())
        let provider = AccessibilityUnlockProvider(
            validator: validator,
            credentials: StubCredentialStore(hasPassword: true),
            isEnabled: { false }
        )
        let canUnlock = await provider.canUnlockCurrentState()
        let capability = await provider.capability()
        XCTAssertFalse(canUnlock)
        XCTAssertEqual(capability, .unsupported)
    }

    func testPresenceProviderOnlyActsWhileUnlocked() async {
        let unlocked = StubSecurityValidator(verification: verification(locked: false))
        let locked = StubSecurityValidator(verification: verification(locked: true))
        let whileUnlocked = await PresenceUnlockProvider(validator: unlocked).canUnlockCurrentState()
        let whileLocked = await PresenceUnlockProvider(validator: locked).canUnlockCurrentState()
        XCTAssertTrue(whileUnlocked)
        XCTAssertFalse(whileLocked, "a locked session must never be handled by the presence provider")
    }

    func testPresenceProviderRefusesToActOnALockedSession() async {
        let provider = PresenceUnlockProvider(
            validator: StubSecurityValidator(verification: verification(locked: true))
        )
        do {
            try await provider.attemptUnlock()
            XCTFail("expected a refusal")
        } catch let error as FaceUnlockError {
            XCTAssertEqual(error, .unlockVerificationFailed("the session is already locked"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testManualProviderAlwaysReportsLimited() async {
        let notifications = RecordingNotificationCenter()
        let provider = ManualConfirmationUnlockProvider(notificationCenter: notifications)
        let capability = await provider.capability()
        XCTAssertEqual(capability, .limited)
        try? await provider.attemptUnlock()
        // Suppressed while the lock-screen work is unfinished: it fired on every
        // recognised face, including during lock-screen challenges it had no
        // part in. Asserting zero keeps its return a deliberate act rather than
        // something that creeps back.
        XCTAssertEqual(notifications.posted.count, 0)
    }
}

/// Credential store double that counts every read of the secret.
final class StubCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    private(set) var readCount = 0

    init(hasPassword: Bool) {
        self.stored = hasPassword ? "correct horse battery staple" : nil
    }

    var hasSavedPassword: Bool { lock.lock(); defer { lock.unlock() }; return stored != nil }

    func validateAndStore(password: String, shortName: String) async throws {
        store(password)
    }

    /// `NSLock.lock()` is marked `noasync`, so the critical section lives in a
    /// synchronous helper rather than inline in the `async` method.
    private func store(_ password: String) {
        lock.lock(); defer { lock.unlock() }
        stored = password
    }

    func removePassword() throws { lock.lock(); stored = nil; lock.unlock() }

    func loadPasswordForSingleUse() throws -> String {
        lock.lock()
        readCount += 1
        let value = stored
        lock.unlock()
        guard let value else { throw FaceUnlockError.credentialMissing }
        return value
    }
}
