import Foundation
import Security

/// Abstraction over the Keychain so that everything above it can be unit tested
/// without touching the real login keychain.
public protocol KeychainServicing: Sendable {
    func setData(_ data: Data, for item: KeychainItem) throws
    func data(for item: KeychainItem) throws -> Data?
    func removeItem(_ item: KeychainItem) throws
    func containsItem(_ item: KeychainItem) throws -> Bool
}

/// The complete set of secrets FaceUnlock may store. Enumerating them here keeps
/// every Keychain write auditable from one file.
public enum KeychainItem: String, CaseIterable, Sendable {
    /// Symmetric key protecting the biometric profile on disk.
    case profileEncryptionKey = "profile-encryption-key"
    /// The user's macOS account password, stored only when the user explicitly
    /// opts in to a workflow that needs it.
    case accountPassword = "account-password"
    /// Optional master password guarding FaceUnlock's own sensitive settings.
    case settingsMasterPassword = "settings-master-password"

    var account: String { rawValue }

    /// Secrets that must only ever be readable while the machine is unlocked and
    /// must never sync to another device or to iCloud.
    var accessibility: CFString { kSecAttrAccessibleWhenUnlockedThisDeviceOnly }

    /// Human-readable label shown in Keychain Access.
    var label: String {
        switch self {
        case .profileEncryptionKey: return "FaceUnlock — face profile encryption key"
        case .accountPassword: return "FaceUnlock — saved account password"
        case .settingsMasterPassword: return "FaceUnlock — settings master password"
        }
    }
}

/// Generic-password backed Keychain storage.
///
/// Notes on the design:
/// * `kSecUseDataProtectionKeychain` is set so items land in the data-protection
///   keychain, which supports the same access-control semantics as on iOS and is
///   not exported by ordinary keychain dumps of the file-based login keychain.
///   The data-protection keychain is only available to code that carries an
///   application identifier, i.e. a build signed with a development team or a
///   Developer ID. An ad-hoc signed build (Xcode with no team selected) gets
///   `errSecMissingEntitlement` (−34018). The first call that hits that status
///   switches the service — for the rest of the process, and only in that
///   case — to the user's login keychain. The fallback is logged and shown in Diagnostics; it is still the
///   Keychain — encrypted at rest, ACL-bound to this app — just without the
///   per-item accessibility class. See SECURITY.md.
/// * `kSecAttrSynchronizable` is explicitly false: biometric material and account
///   credentials must never leave this Mac.
public struct KeychainService: KeychainServicing {
    /// `errSecMissingEntitlement`: the data-protection keychain refused the caller
    /// because the binary carries no application identifier.
    static let missingEntitlementStatus: OSStatus = -34018

    private let service: String
    private let accessGroup: String?
    /// Flips to false the first time the data-protection keychain answers
    /// `errSecMissingEntitlement`; every later call goes to the login keychain.
    /// Shared by copies of this value type so the decision is made once.
    private let dataProtectionAvailable = Atomic<Bool>(true)

    public init(service: String = "de.faceunlock.mac", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    /// True while the data-protection keychain is being used.
    public var usesDataProtectionKeychain: Bool { dataProtectionAvailable.value }

    private func baseQuery(for item: KeychainItem, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.account,
            kSecAttrSynchronizable as String: false
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    /// Runs `operation` against the data-protection keychain and, when that
    /// cannot answer, once more against the login keychain.
    ///
    /// Two statuses mean "ask the other keychain", and conflating them cost real
    /// data:
    ///
    /// - `errSecMissingEntitlement` — this build cannot use the data-protection
    ///   keychain at all. The downgrade sticks for the life of the process.
    /// - `errSecItemNotFound` on a *read* — the data-protection keychain works,
    ///   but the item was written by an earlier run that had already downgraded,
    ///   so it lives in the login keychain. This must **not** mark data
    ///   protection unavailable; it only means "look in the other one too".
    ///
    /// Before this distinction existed, a read returned `errSecItemNotFound` and
    /// the caller concluded the encryption key did not exist. The next
    /// enrolment then minted a fresh key and overwrote the real one, silently
    /// destroying every profile enrolled before it — which presented as a
    /// profile that was "corrupt" at launch and mysteriously fine later in the
    /// same session, once some write had triggered the downgrade.
    private func withKeychain(
        readFallback: Bool = false,
        _ operation: (_ dataProtection: Bool) -> OSStatus
    ) -> OSStatus {
        guard dataProtectionAvailable.value else { return operation(false) }
        let status = operation(true)

        if status == Self.missingEntitlementStatus {
            dataProtectionAvailable.value = false
            AppLogger.keychain.notice(
                "Data-protection keychain unavailable (unsigned or ad-hoc build); using the login keychain"
            )
            return operation(false)
        }

        if readFallback, status == errSecItemNotFound {
            let fallback = operation(false)
            if fallback == errSecSuccess {
                AppLogger.keychain.notice(
                    "Item found in the login keychain rather than the data-protection keychain"
                )
                return fallback
            }
            return status
        }

        return status
    }

    public func setData(_ data: Data, for item: KeychainItem) throws {
        let status = withKeychain { dataProtection in
            var query = baseQuery(for: item, dataProtection: dataProtection)
            var attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrLabel as String: item.label
            ]
            // Accessibility classes are a data-protection concept; the file-based
            // login keychain rejects or ignores them depending on the OS release.
            if dataProtection {
                attributes[kSecAttrAccessible as String] = item.accessibility
            }
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecItemNotFound else { return updateStatus }
            query.merge(attributes) { _, new in new }
            return SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            AppLogger.keychain.error("Keychain write failed (status \(status, privacy: .public))")
            throw FaceUnlockError.keychainFailure(status: status)
        }
    }

    public func data(for item: KeychainItem) throws -> Data? {
        var result: CFTypeRef?
        let status = withKeychain(readFallback: true) { dataProtection in
            var query = baseQuery(for: item, dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            result = nil
            return SecItemCopyMatching(query as CFDictionary, &result)
        }
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            AppLogger.keychain.error("Keychain read failed (status \(status, privacy: .public))")
            throw FaceUnlockError.keychainFailure(status: status)
        }
    }

    /// Deletes from **both** keychains, always.
    ///
    /// A copy can exist in either — the data-protection keychain when this build
    /// can use it, the login keychain when an earlier run had downgraded — and
    /// deleting from only one leaves the other behind. That is not a tidiness
    /// problem: `EncryptionService.destroyKey()` promises that any remaining
    /// ciphertext becomes unrecoverable, and a surviving copy of the key breaks
    /// that promise outright. Neither keychain reporting `errSecItemNotFound` is
    /// an error here; between them, the item is gone.
    public func removeItem(_ item: KeychainItem) throws {
        var firstFailure: OSStatus?
        for dataProtection in [true, false] {
            if dataProtection && !dataProtectionAvailable.value { continue }
            let status = SecItemDelete(
                baseQuery(for: item, dataProtection: dataProtection) as CFDictionary)
            switch status {
            case errSecSuccess, errSecItemNotFound, Self.missingEntitlementStatus:
                continue
            default:
                AppLogger.keychain.error(
                    "Keychain delete failed (status \(status, privacy: .public))")
                if firstFailure == nil { firstFailure = status }
            }
        }
        if let firstFailure {
            throw FaceUnlockError.keychainFailure(status: firstFailure)
        }
    }

    public func containsItem(_ item: KeychainItem) throws -> Bool {
        let status = withKeychain(readFallback: true) { dataProtection in
            var query = baseQuery(for: item, dataProtection: dataProtection)
            query[kSecReturnData as String] = false
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            return SecItemCopyMatching(query as CFDictionary, nil)
        }
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw FaceUnlockError.keychainFailure(status: status)
        }
    }
}

/// In-memory stand-in used by the test suite and by SwiftUI previews. Never
/// referenced from shipping code paths.
public final class InMemoryKeychainService: KeychainServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [KeychainItem: Data] = [:]
    /// When set, every operation throws this error — used to exercise failure paths.
    public var injectedFailure: FaceUnlockError?

    public init() {}

    public func setData(_ data: Data, for item: KeychainItem) throws {
        if let injectedFailure { throw injectedFailure }
        lock.lock(); defer { lock.unlock() }
        storage[item] = data
    }

    public func data(for item: KeychainItem) throws -> Data? {
        if let injectedFailure { throw injectedFailure }
        lock.lock(); defer { lock.unlock() }
        return storage[item]
    }

    public func removeItem(_ item: KeychainItem) throws {
        if let injectedFailure { throw injectedFailure }
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: item)
    }

    public func containsItem(_ item: KeychainItem) throws -> Bool {
        if let injectedFailure { throw injectedFailure }
        lock.lock(); defer { lock.unlock() }
        return storage[item] != nil
    }
}
