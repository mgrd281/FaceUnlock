import Foundation

/// Locks the Mac when the enrolled user is no longer present.
///
/// macOS has no public API that locks a session directly. What it does have is
/// `pmset displaysleepnow`, which puts the display to sleep; the session then
/// locks according to the user's own "Require password after screen saver begins
/// or display is turned off" setting in Lock Screen settings. That means this
/// feature *respects* the configured policy instead of overriding it: if the user
/// has chosen a five-minute grace period, FaceUnlock does not shorten it.
///
/// The feature is off by default and does nothing unless the user turns it on.
public protocol SessionLocking: Sendable {
    func lockDisplay() async throws
}

public struct SessionLocker: SessionLocking {
    private let executableURL: URL

    public init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/pmset")) {
        self.executableURL = executableURL
    }

    public func lockDisplay() async throws {
        let executableURL = self.executableURL
        // `Process.waitUntilExit()` blocks the calling thread, which must not be a
        // cooperative-pool thread. Only `URL` and the continuation — both Sendable —
        // cross the boundary; the `Process` itself never leaves the helper.
        try await withCheckedThrowingContinuation { (resumed: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try Self.runDisplaySleep(executableURL: executableURL)
                    resumed.resume()
                } catch {
                    resumed.resume(throwing: error)
                }
            }
        }
        AppLogger.unlock.notice("Display put to sleep because the enrolled user is no longer present")
    }

    private static func runDisplaySleep(executableURL: URL) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["displaysleepnow"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw FaceUnlockError.unlockVerificationFailed(
                "the display could not be put to sleep: \(error.localizedDescription)"
            )
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FaceUnlockError.unlockVerificationFailed(
                "pmset exited with status \(process.terminationStatus)"
            )
        }
    }
}

/// Test double.
public final class RecordingSessionLocker: SessionLocking, @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var lockCount = 0
    public init() {}
    public func lockDisplay() async throws {
        recordLock()
    }

    /// `NSLock.lock()` is marked `noasync`, so the critical section lives in a
    /// synchronous helper rather than inline in the `async` method.
    private func recordLock() {
        lock.lock(); defer { lock.unlock() }
        lockCount += 1
    }
}
