import Foundation
import Security

/// Reports whether the lock screen itself can complete an unlock.
///
/// This provider is deliberately inert. Every other provider in the chain acts
/// *on* the session; this one describes a path where the session acts on us —
/// SecurityAgent asks the broker, the broker asks `IdentityService`, and
/// SecurityAgent completes the unlock. FaceUnlock is the answerer, not the
/// actor, so `canUnlockCurrentState()` is always `false`: there is nothing for
/// the coordinator to drive, and claiming otherwise would put a provider in the
/// chain that reports a success it did not cause.
///
/// It exists so that the capability shown throughout the UI is the truth. With
/// the components installed and the rule composed, full unlock genuinely is
/// available, and `SessionUnlockCapability.supported` finally means something on
/// this Mac. Without them it reports `unsupported`, like everything else in
/// `KNOWN_LIMITATIONS.md` §1.
public actor LockScreenUnlockProvider: UnlockProvider {
    public nonisolated let identifier = "lock-screen"
    public nonisolated let displayName = "Lock screen"
    /// Below `AccessibilityUnlockProvider` (50) because it drives nothing and
    /// synthesises nothing; above `PresenceUnlockProvider` (0) because never
    /// locking at all remains safer than unlocking.
    public nonisolated let safetyRank = 25
    public nonisolated let explanation = """
        Answers the lock screen when macOS asks whether you are there. The unlock \
        is completed by macOS itself, and your password stays available as a \
        separate branch of the same rule.
        """

    /// The sub-rule `install.sh --enable-lock-screen` adds to
    /// `system.login.screensaver`.
    static let faceRuleName = "de.faceunlock.screensaver"
    static let screensaverRight = "system.login.screensaver"

    private let broker: BrokerClient
    private let ruleReader: @Sendable () -> Bool

    public init(
        broker: BrokerClient,
        ruleReader: @escaping @Sendable () -> Bool = LockScreenUnlockProvider.faceBranchIsInstalled
    ) {
        self.broker = broker
        self.ruleReader = ruleReader
    }

    public func capability() async -> SessionUnlockCapability {
        guard ruleReader() else { return .unsupported }
        guard case .available = await broker.checkAvailability() else { return .unsupported }
        return .supported
    }

    /// Always `false`. See the type's documentation: the lock screen drives this
    /// path, and a provider that cannot satisfy its own preconditions must
    /// refuse rather than attempt a best-effort unlock.
    public func canUnlockCurrentState() async -> Bool { false }

    public func attemptUnlock() async throws {
        throw FaceUnlockError.unlockUnavailableOnThisSystem
    }

    /// Whether the face branch is present in the live authorization database.
    ///
    /// `AuthorizationRightGet` reads the right directly, so this costs no
    /// subprocess and cannot be fooled by a stale copy of the rule on disk.
    public static func faceBranchIsInstalled() -> Bool {
        var definition: CFDictionary?
        let status = screensaverRight.withCString { AuthorizationRightGet($0, &definition) }
        guard status == errAuthorizationSuccess,
              let rule = definition as? [String: Any]
        else { return false }

        if let branches = rule["rule"] as? [String] {
            return branches.contains(faceRuleName)
        }
        if let single = rule["rule"] as? String {
            return single == faceRuleName
        }
        return false
    }
}
