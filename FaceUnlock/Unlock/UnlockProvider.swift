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

    public func capability() async -> SessionUnlockCapability {
        lock.lock(); defer { lock.unlock() }; return _capability
    }

    public func canUnlockCurrentState() async -> Bool {
        lock.lock(); defer { lock.unlock() }; return _canUnlock
    }

    public func attemptUnlock() async throws {
        lock.lock(); attemptCount += 1; let result = self.result; lock.unlock()
        try result.get()
    }
}
