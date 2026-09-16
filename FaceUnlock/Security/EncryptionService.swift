import CryptoKit
import Foundation

/// Authenticated encryption for data written to disk.
///
/// The key is a 256-bit symmetric key generated on first use and kept in the
/// Keychain (`KeychainItem.profileEncryptionKey`). The ciphertext on disk is
/// therefore useless to anyone who copies the container directory without also
/// being able to unlock this Mac's keychain.
public protocol EncryptionServicing: Sendable {
    func encrypt(_ plaintext: Data) throws -> Data
    func decrypt(_ ciphertext: Data) throws -> Data
    /// Destroys the key so that any remaining ciphertext is unrecoverable.
    func destroyKey() throws
}

public struct EncryptionService: EncryptionServicing {
    private let keychain: any KeychainServicing

    public init(keychain: any KeychainServicing) {
        self.keychain = keychain
    }

    public func encrypt(_ plaintext: Data) throws -> Data {
        let key = try loadOrCreateKey()
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw FaceUnlockError.profileCorrupted
        }
        return combined
    }

    public func decrypt(_ ciphertext: Data) throws -> Data {
        guard let key = try loadKey() else {
            // No key means nothing legitimate can be decrypted.
            throw FaceUnlockError.profileCorrupted
        }
        do {
            let box = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(box, using: key)
        } catch {
            AppLogger.security.error("Decryption failed — treating stored data as corrupted")
            throw FaceUnlockError.profileCorrupted
        }
    }

    public func destroyKey() throws {
        try keychain.removeItem(.profileEncryptionKey)
        AppLogger.security.notice("Profile encryption key destroyed")
    }

    private func loadKey() throws -> SymmetricKey? {
        guard let data = try keychain.data(for: .profileEncryptionKey) else { return nil }
        guard data.count == 32 else {
            AppLogger.security.error("Stored encryption key has unexpected length")
            throw FaceUnlockError.profileCorrupted
        }
        return SymmetricKey(data: data)
    }

    private func loadOrCreateKey() throws -> SymmetricKey {
        if let existing = try loadKey() { return existing }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try keychain.setData(data, for: .profileEncryptionKey)
        AppLogger.security.notice("Generated a new profile encryption key")
        return key
    }
}
