import Foundation
import UserNotifications

/// The fallback used whenever no automatic provider can act.
///
/// It does the part FaceUnlock genuinely can do at a locked screen — confirm that
/// the enrolled, live user is present — and then hands the last step back to the
/// user with a notification, instead of pretending an unlock happened. On a Mac
/// with Touch ID that last step is a fingerprint; otherwise it is the password.
///
/// This is why `SessionUnlockCapability.limited` exists: it is an honest report,
/// not a degraded mode disguised as success.
public actor ManualConfirmationUnlockProvider: UnlockProvider {
    public nonisolated let identifier = "manual"
    public nonisolated let displayName = "Confirm at the lock screen"
    public nonisolated let safetyRank = 100
    public nonisolated let explanation =
        "Tells you that FaceUnlock recognised you and leaves the final unlock to macOS — a fingerprint on Macs with Touch ID, otherwise your password."

    private let notificationCenter: any UserNotificationPosting

    public init(notificationCenter: any UserNotificationPosting = SystemUserNotificationCenter()) {
        self.notificationCenter = notificationCenter
    }

    public func capability() async -> SessionUnlockCapability { .limited }

    /// Always able to act: there is no state in which telling the user is unsafe.
    public func canUnlockCurrentState() async -> Bool { true }

    public func attemptUnlock() async throws {
        await notificationCenter.post(
            title: "FaceUnlock recognised you",
            body: "macOS needs you to finish unlocking — use Touch ID or your password."
        )
        AppLogger.unlock.notice("Recognition confirmed; manual completion requested")
    }
}

public protocol UserNotificationPosting: Sendable {
    func post(title: String, body: String) async
}

/// Wraps `UNUserNotificationCenter`. Notification authorisation is requested once,
/// lazily, and a refusal is not an error — the menu-bar icon still shows the
/// result.
public struct SystemUserNotificationCenter: UserNotificationPosting {
    public init() {}

    public func post(title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else {
            AppLogger.unlock.notice("Notification authorisation not granted; skipping the alert")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
        } catch {
            AppLogger.unlock.error("Could not post the notification: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Test double.
public final class RecordingNotificationCenter: UserNotificationPosting, @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var posted: [(title: String, body: String)] = []
    public init() {}
    public func post(title: String, body: String) async {
        record(title: title, body: body)
    }

    /// `NSLock.lock()` is marked `noasync`, so the critical section lives in a
    /// synchronous helper rather than inline in the `async` method.
    private func record(title: String, body: String) {
        lock.lock(); defer { lock.unlock() }
        posted.append((title, body))
    }
}
