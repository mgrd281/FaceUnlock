import AppKit
import CoreGraphics
import Foundation

/// Session-level events FaceUnlock reacts to.
public enum LockEvent: String, Equatable, Sendable {
    case screenLocked
    case screenUnlocked
    case screensaverStarted
    case screensaverStopped
    case systemWillSleep
    case systemDidWake
    case screensDidWake
    case screensDidSleep
    case sessionDidResignActive
    case sessionDidBecomeActive
}

public protocol LockStateMonitoring: Sendable {
    /// A stream of session events. Starting a second stream replaces the first.
    func events() -> AsyncStream<LockEvent>
    func isScreenLocked() -> Bool
    func stop()
}

/// Bridges the several different notification sources macOS uses for session
/// state into one ordered stream.
///
/// Sources, and why each one is needed:
/// * `com.apple.screenIsLocked` / `…Unlocked` on the **distributed** notification
///   centre — the only notification that fires for an actual session lock.
/// * `com.apple.screensaver.didstart` / `…didstop` — the screen saver can start
///   without locking, depending on the grace period in Lock Screen settings.
/// * `NSWorkspace.screensDidWake/Sleep` and `didWake/willSleep` — the wake signals
///   used to retry recognition without polling.
/// * `NSWorkspace.sessionDidResignActive` — fast user switching, during which
///   FaceUnlock must not touch the camera at all.
public final class LockStateMonitor: LockStateMonitoring, @unchecked Sendable {
    private static let screenIsLockedKey = "CGSSessionScreenIsLocked"

    private let lock = NSLock()
    private var continuation: AsyncStream<LockEvent>.Continuation?
    private var observers: [NSObjectProtocol] = []

    public init() {}

    deinit {
        removeObservers()
    }

    public func events() -> AsyncStream<LockEvent> {
        stop()
        return AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            installObservers()
            continuation.onTermination = { [weak self] _ in
                self?.removeObservers()
            }
        }
    }

    public func stop() {
        lock.lock()
        let existing = continuation
        continuation = nil
        lock.unlock()
        existing?.finish()
        removeObservers()
    }

    public func isScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session[Self.screenIsLockedKey] as? Bool) ?? false
    }

    private func installObservers() {
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter

        var created: [NSObjectProtocol] = []
        created.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: nil
        ) { [weak self] _ in self?.emit(.screenLocked) })
        created.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: nil
        ) { [weak self] _ in self?.emit(.screenUnlocked) })
        created.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screensaver.didstart"), object: nil, queue: nil
        ) { [weak self] _ in self?.emit(.screensaverStarted) })
        created.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screensaver.didstop"), object: nil, queue: nil
        ) { [weak self] _ in self?.emit(.screensaverStopped) })

        let workspaceEvents: [(NSNotification.Name, LockEvent)] = [
            (NSWorkspace.willSleepNotification, .systemWillSleep),
            (NSWorkspace.didWakeNotification, .systemDidWake),
            (NSWorkspace.screensDidWakeNotification, .screensDidWake),
            (NSWorkspace.screensDidSleepNotification, .screensDidSleep),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionDidResignActive),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionDidBecomeActive)
        ]
        for (name, event) in workspaceEvents {
            created.append(workspace.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.emit(event)
            })
        }

        lock.lock(); observers = created; lock.unlock()
        AppLogger.unlock.notice("Lock state monitor started")
    }

    private func removeObservers() {
        lock.lock()
        let existing = observers
        observers = []
        lock.unlock()
        guard !existing.isEmpty else { return }
        for observer in existing {
            DistributedNotificationCenter.default().removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        AppLogger.unlock.notice("Lock state monitor stopped")
    }

    private func emit(_ event: LockEvent) {
        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        AppLogger.unlock.debug("Session event: \(event.rawValue, privacy: .public)")
        continuation?.yield(event)
    }
}

/// Test double that lets a test drive the event stream directly.
public final class StubLockStateMonitor: LockStateMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<LockEvent>.Continuation?
    private var locked: Bool

    public init(locked: Bool = false) {
        self.locked = locked
    }

    public func events() -> AsyncStream<LockEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            lock.lock(); self.continuation = continuation; lock.unlock()
        }
    }

    public func send(_ event: LockEvent) {
        lock.lock(); let continuation = self.continuation; lock.unlock()
        continuation?.yield(event)
    }

    public func setLocked(_ newValue: Bool) {
        lock.lock(); locked = newValue; lock.unlock()
    }

    public func isScreenLocked() -> Bool {
        lock.lock(); defer { lock.unlock() }; return locked
    }

    public func stop() {
        lock.lock(); let continuation = self.continuation; self.continuation = nil; lock.unlock()
        continuation?.finish()
    }
}
