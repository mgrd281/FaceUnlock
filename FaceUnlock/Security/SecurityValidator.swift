import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Security

/// Preconditions that must all hold before FaceUnlock is allowed to drive any
/// interaction with the system's authentication UI.
///
/// The purpose of this type is to make "we are definitely talking to macOS's own
/// lock screen, in our own session, and nothing is impersonating it" a single,
/// testable decision rather than a scattering of ad-hoc checks.
public struct LockScreenVerification: Equatable, Sendable {
    /// The window server reports this session's screen as locked.
    public var screenIsLocked: Bool
    /// This process belongs to the session that owns the console.
    public var isOnConsoleSession: Bool
    /// A secure input context is active — the system is capturing keystrokes
    /// exclusively, which is typically the password field of `loginwindow`.
    public var secureInputActive: Bool
    /// Bundle identifier of the frontmost application, when one is visible to us.
    public var frontmostBundleIdentifier: String?
    /// Process identifier of that application, carried so that a provider never has
    /// to look the process up a second time and risk acting on a different one.
    public var frontmostProcessID: pid_t?
    /// The frontmost application satisfied an `anchor apple` code requirement for
    /// `com.apple.loginwindow`.
    public var frontmostIsAuthenticLoginWindow: Bool
    /// The process holds Accessibility trust.
    public var accessibilityTrusted: Bool

    public init(
        screenIsLocked: Bool,
        isOnConsoleSession: Bool,
        secureInputActive: Bool,
        frontmostBundleIdentifier: String?,
        frontmostProcessID: pid_t? = nil,
        frontmostIsAuthenticLoginWindow: Bool,
        accessibilityTrusted: Bool
    ) {
        self.screenIsLocked = screenIsLocked
        self.isOnConsoleSession = isOnConsoleSession
        self.secureInputActive = secureInputActive
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
        self.frontmostProcessID = frontmostProcessID
        self.frontmostIsAuthenticLoginWindow = frontmostIsAuthenticLoginWindow
        self.accessibilityTrusted = accessibilityTrusted
    }

    /// The conditions under which credential entry could even be contemplated.
    ///
    /// `secureInputActive` being true is what makes synthetic keystroke delivery
    /// impossible on a current macOS; it is recorded here so that the reason for
    /// refusing is precise rather than a guess. See `KNOWN_LIMITATIONS.md`.
    public var allowsCredentialEntry: Bool {
        screenIsLocked
            && isOnConsoleSession
            && accessibilityTrusted
            && frontmostIsAuthenticLoginWindow
            && !secureInputActive
    }

    /// A precise explanation of the first unmet condition, for logs and diagnostics.
    public var refusalReason: String? {
        if !screenIsLocked { return "the screen is not locked" }
        if !isOnConsoleSession { return "this session does not own the console" }
        if !accessibilityTrusted { return "Accessibility permission is not granted" }
        if !frontmostIsAuthenticLoginWindow {
            let observed = frontmostBundleIdentifier ?? "no visible frontmost application"
            return "the frontmost process is not an Apple-signed login window (\(observed))"
        }
        if secureInputActive {
            return "a secure input context owns the keyboard, so no synthetic input can reach it"
        }
        return nil
    }

    /// Convenience for tests: nothing is satisfied.
    public static let nothingSatisfied = LockScreenVerification(
        screenIsLocked: false,
        isOnConsoleSession: false,
        secureInputActive: false,
        frontmostBundleIdentifier: nil,
        frontmostIsAuthenticLoginWindow: false,
        accessibilityTrusted: false
    )
}

public protocol SecurityValidating: Sendable {
    /// Asynchronous because identifying the frontmost application means touching
    /// AppKit, which is main-actor work. Only `Sendable` values cross back.
    func verifyLockScreen() async -> LockScreenVerification
    func isAccessibilityTrusted() -> Bool
    func isScreenLocked() -> Bool
}

public struct SecurityValidator: SecurityValidating {
    /// Key published in the dictionary returned by `CGSessionCopyCurrentDictionary`.
    private static let screenIsLockedKey = "CGSSessionScreenIsLocked"

    public init() {}

    public func verifyLockScreen() async -> LockScreenVerification {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = (session?[Self.screenIsLockedKey] as? Bool) ?? false
        let onConsole = (session?[kCGSessionOnConsoleKey as String] as? Bool) ?? false

        // `NSRunningApplication` is not `Sendable`, so only the two values that are
        // actually needed are read on the main actor and returned.
        let frontmost: (bundleID: String?, pid: pid_t)? = await MainActor.run {
            NSWorkspace.shared.frontmostApplication.map { ($0.bundleIdentifier, $0.processIdentifier) }
        }

        let authentic: Bool
        if let frontmost, frontmost.bundleID == "com.apple.loginwindow" {
            authentic = processSatisfiesRequirement(
                pid: frontmost.pid,
                requirement: "anchor apple and identifier \"com.apple.loginwindow\""
            )
        } else {
            authentic = false
        }

        return LockScreenVerification(
            screenIsLocked: locked,
            isOnConsoleSession: onConsole,
            secureInputActive: IsSecureEventInputEnabled(),
            frontmostBundleIdentifier: frontmost?.bundleID,
            frontmostProcessID: frontmost?.pid,
            frontmostIsAuthenticLoginWindow: authentic,
            accessibilityTrusted: isAccessibilityTrusted()
        )
    }

    public func isScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session[Self.screenIsLockedKey] as? Bool) ?? false
    }

    public func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Bundle identifiers are trivially forgeable, so identity is confirmed
    /// cryptographically: the running process must satisfy a designated
    /// requirement anchored to Apple's own certificate authority.
    func processSatisfiesRequirement(pid: pid_t, requirement: String) -> Bool {
        var requirementRef: SecRequirement?
        guard SecRequirementCreateWithString(
            requirement as CFString, [], &requirementRef
        ) == errSecSuccess, let requirementRef else {
            AppLogger.security.error("Could not compile the login window code requirement")
            return false
        }

        let attributes = [kSecGuestAttributePid: pid as CFNumber] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else {
            AppLogger.security.error("Could not obtain a code object for the frontmost process")
            return false
        }

        let status = SecCodeCheckValidity(code, [], requirementRef)
        if status != errSecSuccess {
            AppLogger.security.notice(
                "Frontmost process failed the login window requirement (status \(status, privacy: .public))"
            )
        }
        return status == errSecSuccess
    }
}

/// Test double that returns a scripted verification.
public final class StubSecurityValidator: SecurityValidating, @unchecked Sendable {
    private let lock = NSLock()
    private var _verification: LockScreenVerification

    public init(verification: LockScreenVerification) {
        self._verification = verification
    }

    public var verification: LockScreenVerification {
        get { lock.lock(); defer { lock.unlock() }; return _verification }
        set { lock.lock(); _verification = newValue; lock.unlock() }
    }

    public func verifyLockScreen() async -> LockScreenVerification { verification }
    public func isAccessibilityTrusted() -> Bool { verification.accessibilityTrusted }
    public func isScreenLocked() -> Bool { verification.screenIsLocked }
}
