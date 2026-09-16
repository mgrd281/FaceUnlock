import Foundation

/// A way of completing the unlock workflow once the enrolled user has been
/// recognised and proven live.
///
/// Providers are ordered by `safetyRank`, lowest first, and `UnlockCoordinator`
/// always uses the safest provider that reports it can act. A provider that
/// cannot satisfy every one of its own preconditions must return `false` from
/// `canUnlockCurrentState()` rather than attempting a best-effort unlock.
public protocol UnlockProvider: Sendable {
    /// Stable identifier used in logs and diagnostics.
    var identifier: String { get }
    /// Name shown in the UI.
    var displayName: String { get }
    /// Lower is safer and therefore preferred.
    var safetyRank: Int { get }
    /// What this provider can honestly deliver on this Mac, right now.
    func capability() async -> SessionUnlockCapability
    /// Whether this provider can act on the session's current state.
    func canUnlockCurrentState() async -> Bool
    /// Performs the provider's action. Throws rather than degrading.
    func attemptUnlock() async throws
    /// One sentence explaining what this provider does, for the Settings and
    /// compatibility screens.
    var explanation: String { get }
}

/// Test double with scripted behaviour.
public final class StubUnlockProvider: UnlockProvider, @unchecked Sendable {
    public let identifier: String
    public let displayName: String
    public let safetyRank: Int
    public let explanation: String
    private let lock = NSLock()
    private var _canUnlock: Bool
    private var _capability: SessionUnlockCapability
    public var result: Result<Void, FaceUnlockError> = .success(())
    public private(set) var attemptCount = 0

    public init(
        identifier: String,
        safetyRank: Int,
        canUnlock: Bool,
        capability: SessionUnlockCapability = .supported
    ) {
        self.identifier = identifier
        self.displayName = identifier
        self.safetyRank = safetyRank
        self.explanation = "Test provider."
        self._canUnlock = canUnlock
        self._capability = capability
    }

    public func setCanUnlock(_ newValue: Bool) { lock.lock(); _canUnlock = newValue; lock.unlock() }

    // `NSLock.lock()` is marked `noasync`, so every critical section below lives
    // in a synchronous helper rather than inline in the `async` method.

    public func capability() async -> SessionUnlockCapability { readCapability() }

    public func canUnlockCurrentState() async -> Bool { readCanUnlock() }

    public func attemptUnlock() async throws {
        try recordAttempt().get()
    }

    private func readCapability() -> SessionUnlockCapability {
        lock.lock(); defer { lock.unlock() }
        return _capability
    }

    private func readCanUnlock() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _canUnlock
    }

    private func recordAttempt() -> Result<Void, FaceUnlockError> {
        lock.lock(); defer { lock.unlock() }
        attemptCount += 1
        return result
    }
}
