import Foundation
import IOKit.pwr_mgt

/// The safest provider, and the only one that completes without the user
/// touching the keyboard.
///
/// It works *before* the lock rather than after it. When the screen saver starts —
/// which happens some time before the session actually locks, by whatever grace
/// period the user configured — `RecognitionCoordinator` spends a few seconds of
/// camera time looking for the enrolled user. If it finds them, this provider
/// declares user activity, which wakes the display and resets the idle timer, and
/// takes a short display-sleep assertion to cover the handover. The Mac then
/// behaves exactly as if the user had moved the mouse.
///
/// Both calls are public IOKit power-management APIs, they need no special
/// permission, and they weaken nothing: the assertion carries a timeout and is
/// released as soon as it lapses, when FaceUnlock is paused, and when it quits —
/// at which point macOS locks exactly as it was configured to. FaceUnlock never
/// shortens or lengthens the user's own grace period.
///
/// What it deliberately does not do: once the session is genuinely locked, this
/// provider reports that it cannot act. Nothing here bypasses a lock that has
/// already happened.
public actor PresenceUnlockProvider: UnlockProvider {
    public nonisolated let identifier = "presence"
    public nonisolated let displayName = "Stay unlocked while you are here"
    public nonisolated let safetyRank = 0
    public nonisolated let explanation =
        "When this Mac starts to go idle, FaceUnlock checks whether you are still in front of it and, if you are, resets the idle timer using the power-management assertions macOS offers any app. It does not unlock a Mac that has already locked."

    private let validator: any SecurityValidating
    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var assertionHeld = false
    /// How long the assertion lives. It only has to cover the handover between
    /// declaring user activity and macOS's idle timer restarting, so it is short —
    /// a long assertion would keep the display awake for no reason.
    private let assertionTimeout: TimeInterval = 30

    public init(validator: any SecurityValidating = SecurityValidator()) {
        self.validator = validator
    }

    deinit {
        if assertionHeld {
            IOPMAssertionRelease(assertionID)
        }
    }

    public func capability() async -> SessionUnlockCapability {
        // Power-management assertions are available on every supported macOS.
        .supported
    }

    public func canUnlockCurrentState() async -> Bool {
        // Only meaningful while the session is still unlocked.
        !validator.isScreenLocked()
    }

    public func attemptUnlock() async throws {
        guard !validator.isScreenLocked() else {
            throw FaceUnlockError.unlockVerificationFailed("the session is already locked")
        }
        try declareUserActivity()
        try renewAssertion()
        AppLogger.unlock.notice("Presence confirmed — idle lock deferred")
    }

    /// Releases the assertion so macOS returns to its configured behaviour at once.
    public func release() {
        guard assertionHeld else { return }
        IOPMAssertionRelease(assertionID)
        assertionHeld = false
        AppLogger.unlock.notice("Presence assertion released")
    }

    /// Tells the power management system a user is present, which wakes the
    /// display and resets the idle timer.
    private func declareUserActivity() throws {
        var activityID = IOPMAssertionID(0)
        let status = IOPMAssertionDeclareUserActivity(
            "FaceUnlock recognised the enrolled user" as CFString,
            kIOPMUserActiveLocal,
            &activityID
        )
        guard status == kIOReturnSuccess else {
            throw FaceUnlockError.unlockVerificationFailed(
                "the system did not accept the user-activity declaration (\(status))"
            )
        }
    }

    private func renewAssertion() throws {
        if assertionHeld {
            IOPMAssertionRelease(assertionID)
            assertionHeld = false
        }
        var newID = IOPMAssertionID(0)
        let properties: [String: Any] = [
            kIOPMAssertionTypeKey as String: kIOPMAssertionTypePreventUserIdleDisplaySleep as String,
            kIOPMAssertionNameKey as String: "FaceUnlock — enrolled user present",
            kIOPMAssertionDetailsKey as String: "Released as soon as the user is no longer recognised",
            kIOPMAssertionTimeoutKey as String: assertionTimeout,
            // When the timeout fires the assertion simply ends; macOS resumes its
            // normal idle behaviour rather than staying awake indefinitely.
            kIOPMAssertionTimeoutActionKey as String: kIOPMAssertionTimeoutActionRelease as String,
            kIOPMAssertionLevelKey as String: kIOPMAssertionLevelOn
        ]
        let status = IOPMAssertionCreateWithProperties(properties as CFDictionary, &newID)
        guard status == kIOReturnSuccess else {
            throw FaceUnlockError.unlockVerificationFailed(
                "the system refused the display assertion (\(status))"
            )
        }
        assertionID = newID
        assertionHeld = true
    }
}
