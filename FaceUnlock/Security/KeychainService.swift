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
///   `errSecMissingEntitlement` (−34018) for every call, so the service probes
///   once at start-up and, only in that case, falls back to the user's login
///   keychain. The fallback is logged and shown in Diagnostics; it is still the
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
    /// True when the data-protection keychain accepted the probe.
    public let usesDataProtectionKeychain: Bool

    public init(service: String = "de.faceunlock.mac", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
        self.usesDataProtectionKeychain = Self.probeDataProtectionKeychain(service: service)
        if !usesDataProtectionKeychain {
            AppLogger.keychain.notice(
                "Data-protection keychain unavailable (unsigned or ad-hoc build); using the login keychain"
            )
        }
    }

    /// Asks the data-protection keychain for an item that does not exist. "Not
    /// found" means the keychain is reachable; "missing entitlement" means this
    /// binary cannot use it at all. Anything else is treated as reachable so a
    /// transient error does not silently downgrade the storage class.
    private static func probeDataProtectionKeychain(service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "probe.\(UUID().uuidString)",
            kSecUseDataProtectionKeychain as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) != missingEntitlementStatus
    }

    private func baseQuery(for item: KeychainItem) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.account,
            kSecAttrSynchronizable as String: false
        ]
        if usesDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    public func setData(_ data: Data, for item: KeychainItem) throws {
        var query = baseQuery(for: item)
        var attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: item.label
        ]
        // Accessibility classes are a data-protection concept; the file-based
        // login keychain rejects or ignores them depending on the OS release.
        if usesDataProtectionKeychain {
            attributes[kSecAttrAccessible as String] = item.accessibility
        }

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            query.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                AppLogger.keychain.error("Keychain add failed (status \(addStatus, privacy: .public))")
                throw FaceUnlockError.keychainFailure(status: addStatus)
            }
        default:
            AppLogger.keychain.error("Keychain update failed (status \(updateStatus, privacy: .public))")
            throw FaceUnlockError.keychainFailure(status: updateStatus)
        }
    }

    public func data(for item: KeychainItem) throws -> Data? {
        var query = baseQuery(for: item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
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

    public func removeItem(_ item: KeychainItem) throws {
        let status = SecItemDelete(baseQuery(for: item) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            AppLogger.keychain.error("Keychain delete failed (status \(status, privacy: .public))")
            throw FaceUnlockError.keychainFailure(status: status)
        }
    }

    public func containsItem(_ item: KeychainItem) throws -> Bool {
        var query = baseQuery(for: item)
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
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
