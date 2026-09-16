import Foundation
import OpenDirectory

/// Storage and validation for the macOS account password.
///
/// The password is only ever needed by an unlock provider that types it into the
/// system's own authentication UI. It is stored in the Keychain and nowhere else:
/// never in `UserDefaults`, never in a plist, never in a log line, never in an
/// exported diagnostics bundle. It is write-only from the UI's point of view —
/// once saved there is no code path that renders it back on screen.
public protocol CredentialStoring: Sendable {
    var hasSavedPassword: Bool { get }
    /// Validates the password against the local directory node, then stores it.
    func validateAndStore(password: String, shortName: String) async throws
    /// Removes the saved password immediately.
    func removePassword() throws
    /// Retrieves the password for a single authorised use.
    func withPassword<T: Sendable>(_ body: (String) async throws -> T) async throws -> T
}

public struct CredentialStore: CredentialStoring {
    private let keychain: any KeychainServicing
    private let validator: any AccountPasswordValidating

    public init(keychain: any KeychainServicing, validator: any AccountPasswordValidating = OpenDirectoryPasswordValidator()) {
        self.keychain = keychain
        self.validator = validator
    }

    public var hasSavedPassword: Bool {
        (try? keychain.containsItem(.accountPassword)) ?? false
    }

    public func validateAndStore(password: String, shortName: String) async throws {
        guard !password.isEmpty else { throw FaceUnlockError.credentialValidationFailed }
        let isValid = try await validator.verify(password: password, shortName: shortName)
        guard isValid else {
            AppLogger.keychain.notice("Account password validation rejected the supplied password")
            throw FaceUnlockError.credentialValidationFailed
        }
        guard let data = password.data(using: .utf8) else {
            throw FaceUnlockError.credentialValidationFailed
        }
        try keychain.setData(data, for: .accountPassword)
        AppLogger.keychain.notice("Account password stored in the Keychain")
    }

    public func removePassword() throws {
        try keychain.removeItem(.accountPassword)
        AppLogger.keychain.notice("Saved account password removed")
    }

    public func withPassword<T: Sendable>(_ body: (String) async throws -> T) async throws -> T {
        guard var data = try keychain.data(for: .accountPassword) else {
            throw FaceUnlockError.credentialMissing
        }
        defer {
            // Best-effort scrubbing of the heap copy. Swift `String` may still hold
            // an internal copy; this limits, but cannot eliminate, the window.
            data.resetBytes(in: 0..<data.count)
        }
        guard let password = String(data: data, encoding: .utf8) else {
            throw FaceUnlockError.credentialMissing
        }
        return try await body(password)
    }
}

/// Validation of an account password against the system directory.
public protocol AccountPasswordValidating: Sendable {
    func verify(password: String, shortName: String) async throws -> Bool
}

/// Uses OpenDirectory's `verifyPassword`, the same public mechanism `dscl` uses.
///
/// Caveat worth knowing: repeated failures count towards the account's password
/// policy, exactly as they would at the login window, so the UI validates only
/// when the user presses Save rather than on every keystroke.
public struct OpenDirectoryPasswordValidator: AccountPasswordValidating {
    public init() {}

    public func verify(password: String, shortName: String) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            // OpenDirectory is synchronous and can block; keep it off the main actor.
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let session = ODSession.default()
                    let node = try ODNode(session: session, type: ODNodeType(kODNodeTypeAuthentication))
                    let record = try node.record(
                        withRecordType: kODRecordTypeUsers,
                        name: shortName,
                        attributes: nil
                    )
                    try record.verifyPassword(password)
                    continuation.resume(returning: true)
                } catch let error as NSError where error.domain == ODFrameworkErrorDomain {
                    // A credentials error is a legitimate "wrong password", not a failure
                    // of the validation mechanism itself.
                    if error.code == Int(kODErrorCredentialsInvalid.rawValue) {
                        continuation.resume(returning: false)
                    } else {
                        AppLogger.keychain.error(
                            "OpenDirectory verification error (code \(error.code, privacy: .public))"
                        )
                        continuation.resume(returning: false)
                    }
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }
}

/// Test double for password validation.
public struct StubPasswordValidator: AccountPasswordValidating {
    public let expected: String
    public init(expected: String) { self.expected = expected }
    public func verify(password: String, shortName: String) async throws -> Bool {
        password == expected
    }
}
