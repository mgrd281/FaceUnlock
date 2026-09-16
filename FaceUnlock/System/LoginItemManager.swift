import Foundation
import ServiceManagement

public protocol LoginItemManaging: Sendable {
    var isAvailable: Bool { get }
    func isEnabled() -> Bool
    func setEnabled(_ enabled: Bool) throws
    /// Human-readable description of the current registration, for Diagnostics.
    func statusDescription() -> String
}

/// Launch-at-login via `SMAppService`, the supported replacement for the
/// deprecated `SMLoginItemSetEnabled` and for writing into `LaunchAgents`.
///
/// Registration can land in a "requires approval" state if the user has
/// previously disabled the item in System Settings; that is reported rather than
/// worked around.
public struct LoginItemManager: LoginItemManaging {
    public init() {}

    public var isAvailable: Bool { true }

    public func isEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    public func setEnabled(_ enabled: Bool) throws {
        do {
            if enabled {
                guard SMAppService.mainApp.status != .enabled else { return }
                try SMAppService.mainApp.register()
                AppLogger.lifecycle.notice("Registered FaceUnlock as a login item")
            } else {
                guard SMAppService.mainApp.status != .notRegistered else { return }
                try SMAppService.mainApp.unregister()
                AppLogger.lifecycle.notice("Removed FaceUnlock from login items")
            }
        } catch {
            AppLogger.lifecycle.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
            throw FaceUnlockError.loginItemRegistrationFailed(error.localizedDescription)
        }
    }

    public func statusDescription() -> String {
        switch SMAppService.mainApp.status {
        case .enabled: return "Enabled"
        case .notRegistered: return "Not registered"
        case .requiresApproval: return "Waiting for approval in \(SystemSettingsLinks.loginItemsPath)"
        case .notFound: return "Not found"
        @unknown default: return "Unknown"
        }
    }
}

/// Test double.
public final class StubLoginItemManager: LoginItemManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var enabled: Bool
    public var isAvailable: Bool = true
    public var injectedFailure: FaceUnlockError?

    public init(enabled: Bool = false) { self.enabled = enabled }

    public func isEnabled() -> Bool { lock.lock(); defer { lock.unlock() }; return enabled }

    public func setEnabled(_ newValue: Bool) throws {
        if let injectedFailure { throw injectedFailure }
        lock.lock(); enabled = newValue; lock.unlock()
    }

    public func statusDescription() -> String { isEnabled() ? "Enabled" : "Not registered" }
}
