import Foundation

/// Persistence for the enrolled biometric profile.
public protocol BiometricProfileStoring: Sendable {
    func load() throws -> BiometricProfile?
    func save(_ profile: BiometricProfile) throws
    /// Removes the profile, its encryption key and any temporary enrolment data.
    func forgetEverything() throws
    var hasProfile: Bool { get }
}

/// Encrypted, file-backed profile storage.
///
/// Layout: `~/Library/Application Support/de.faceunlock.mac/profile.bin`, holding
/// AES-GCM ciphertext of the JSON encoding of `BiometricProfile`. The file is
/// created with `0600` and the containing directory with `0700`.
public final class BiometricProfileStore: BiometricProfileStoring, @unchecked Sendable {
    private let directory: URL
    private let fileURL: URL
    private let encryption: any EncryptionServicing
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(
        encryption: any EncryptionServicing,
        fileManager: FileManager = .default,
        directory: URL? = nil
    ) {
        self.encryption = encryption
        self.fileManager = fileManager
        if let directory {
            self.directory = directory
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.directory = base.appendingPathComponent("de.faceunlock.mac", isDirectory: true)
        }
        self.fileURL = self.directory.appendingPathComponent("profile.bin", isDirectory: false)
    }

    public var hasProfile: Bool {
        fileManager.fileExists(atPath: fileURL.path)
    }

    public func load() throws -> BiometricProfile? {
        lock.lock(); defer { lock.unlock() }
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let ciphertext = try Data(contentsOf: fileURL)
        let plaintext = try encryption.decrypt(ciphertext)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let profile: BiometricProfile
        do {
            profile = try decoder.decode(BiometricProfile.self, from: plaintext)
        } catch {
            AppLogger.security.error("Stored profile could not be decoded")
            throw FaceUnlockError.profileCorrupted
        }
        guard profile.isStructurallyValid else {
            AppLogger.security.error("Stored profile failed structural validation")
            throw FaceUnlockError.profileCorrupted
        }
        return profile
    }

    public func save(_ profile: BiometricProfile) throws {
        guard profile.isStructurallyValid else {
            throw FaceUnlockError.profileCorrupted
        }
        lock.lock(); defer { lock.unlock() }
        try createDirectoryIfNeeded()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(profile)
        let ciphertext = try encryption.encrypt(plaintext)
        // `.completeFileProtection` is a no-op on macOS; POSIX permissions and the
        // encryption key in the Keychain are what actually protect the file.
        try ciphertext.write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        AppLogger.security.notice(
            "Saved biometric profile (\(profile.embeddings.count, privacy: .public) descriptors)"
        )
    }

    public func forgetEverything() throws {
        lock.lock(); defer { lock.unlock() }
        if fileManager.fileExists(atPath: fileURL.path) {
            try overwriteThenRemove(fileURL)
        }
        let scratch = directory.appendingPathComponent("enrollment-scratch", isDirectory: true)
        if fileManager.fileExists(atPath: scratch.path) {
            try fileManager.removeItem(at: scratch)
        }
        try encryption.destroyKey()
        AppLogger.security.notice("Biometric profile and encryption key removed")
    }

    /// Overwrites the ciphertext before unlinking. On a copy-on-write filesystem
    /// such as APFS this does not guarantee the old blocks are gone — the real
    /// protection is destroying the key, which this is paired with.
    private func overwriteThenRemove(_ url: URL) throws {
        if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? Int, size > 0 {
            let zeroes = Data(count: size)
            try? zeroes.write(to: url, options: [])
        }
        try fileManager.removeItem(at: url)
    }

    private func createDirectoryIfNeeded() throws {
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}

/// Test double; keeps a profile in memory only.
public final class InMemoryProfileStore: BiometricProfileStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var profile: BiometricProfile?
    public var injectedLoadFailure: FaceUnlockError?

    public init(profile: BiometricProfile? = nil) {
        self.profile = profile
    }

    public var hasProfile: Bool {
        lock.lock(); defer { lock.unlock() }
        return profile != nil
    }

    public func load() throws -> BiometricProfile? {
        if let injectedLoadFailure { throw injectedLoadFailure }
        lock.lock(); defer { lock.unlock() }
        return profile
    }

    public func save(_ profile: BiometricProfile) throws {
        guard profile.isStructurallyValid else { throw FaceUnlockError.profileCorrupted }
        lock.lock(); defer { lock.unlock() }
        self.profile = profile
    }

    public func forgetEverything() throws {
        lock.lock(); defer { lock.unlock() }
        profile = nil
    }
}
