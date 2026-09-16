import ApplicationServices
import Foundation

/// Assisted entry into macOS's own lock-screen password field.
///
/// ## Read this before changing anything here
///
/// On current macOS this provider is expected to report that it cannot act, and
/// that is the correct outcome rather than a bug to work around:
///
/// * `loginwindow` enables a **secure input** context while its password field has
///   focus. Secure event input exists precisely so that no other process can
///   deliver synthetic keystrokes to that field, and it is enforced by the window
///   server, not by TCC.
/// * The lock screen's UI belongs to `loginwindow` running in a different
///   security context. Accessibility trust granted to an app in the user's session
///   does not extend to it, so the accessibility tree is either empty or
///   unwritable.
///
/// FaceUnlock does not attempt to defeat either mechanism. What this type does is
/// implement the interaction *properly* for the case where the OS does permit it,
/// verify every precondition first, and abort loudly otherwise. In particular it
/// never falls back to clicking at screen coordinates, and it never types into a
/// process it has not cryptographically identified as Apple's login window.
///
/// This provider is opt-in. It stays disabled unless the user has explicitly
/// enabled it *and* saved a password.
public actor AccessibilityUnlockProvider: UnlockProvider {
    public nonisolated let identifier = "accessibility"
    public nonisolated let displayName = "Assisted lock-screen entry"
    public nonisolated let safetyRank = 50
    public nonisolated let explanation =
        "Enters your saved password into macOS's own lock-screen field, but only if the system can prove the field belongs to Apple's login window and no secure-input context is active. On current macOS versions this is refused by the system."

    private let validator: any SecurityValidating
    private let credentials: any CredentialStoring
    private let isEnabled: @Sendable () -> Bool

    public init(
        validator: any SecurityValidating,
        credentials: any CredentialStoring,
        isEnabled: @escaping @Sendable () -> Bool
    ) {
        self.validator = validator
        self.credentials = credentials
        self.isEnabled = isEnabled
    }

    public func capability() async -> SessionUnlockCapability {
        guard isEnabled() else { return .unsupported }
        let verification = await validator.verifyLockScreen()
        // Accessibility trust is the only precondition that can be evaluated while
        // the screen is unlocked; the rest are lock-screen specific.
        return verification.accessibilityTrusted ? .limited : .unsupported
    }

    public func canUnlockCurrentState() async -> Bool {
        guard isEnabled() else { return false }
        guard credentials.hasSavedPassword else { return false }
        let verification = await validator.verifyLockScreen()
        guard verification.allowsCredentialEntry else {
            if let reason = verification.refusalReason {
                AppLogger.unlock.notice(
                    "Assisted entry unavailable because \(reason, privacy: .public)"
                )
            }
            return false
        }
        return true
    }

    public func attemptUnlock() async throws {
        guard isEnabled() else { throw FaceUnlockError.unlockUnavailableOnThisSystem }

        // Re-verify immediately before acting. The state could have changed between
        // `canUnlockCurrentState()` and here, and entering a password into the wrong
        // window is the single worst thing this app could do.
        let verification = await validator.verifyLockScreen()
        guard verification.allowsCredentialEntry else {
            let reason = verification.refusalReason ?? "an unknown precondition failed"
            AppLogger.unlock.error("Assisted entry aborted: \(reason, privacy: .public)")
            throw FaceUnlockError.unlockVerificationFailed(reason)
        }

        // The verification already identified the process cryptographically; reusing
        // its pid means there is no window in which a different process could take
        // the foreground between the check and the write.
        guard let pid = verification.frontmostProcessID else {
            throw FaceUnlockError.unlockVerificationFailed("the login window could not be identified")
        }

        guard let field = try secureTextField(inApplicationWithPID: pid) else {
            throw FaceUnlockError.unlockVerificationFailed(
                "the login window did not expose a password field to the accessibility API"
            )
        }

        // Last check before the secret is materialised: if a secure input context
        // has appeared in the meantime, stop without ever reading the Keychain.
        let recheck = await validator.verifyLockScreen()
        guard !recheck.secureInputActive else {
            throw FaceUnlockError.unlockVerificationFailed(
                "a secure input context became active while preparing to authenticate"
            )
        }

        let password = try credentials.loadPasswordForSingleUse()
        let status = AXUIElementSetAttributeValue(
            field, kAXValueAttribute as CFString, password as CFTypeRef
        )
        guard status == .success else {
            throw FaceUnlockError.unlockVerificationFailed(
                "the password field refused the value (AXError \(status.rawValue))"
            )
        }
        try Self.confirm(field: field)
        AppLogger.unlock.notice("Assisted lock-screen entry completed")
    }

    /// Walks the login window's accessibility tree looking for a field with the
    /// secure-text-field subrole.
    ///
    /// The search is bounded and breadth-first: an unbounded walk of a hostile or
    /// unexpected tree could hang the recognition actor.
    private func secureTextField(inApplicationWithPID pid: pid_t) throws -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        var queue: [(element: AXUIElement, depth: Int)] = [(application, 0)]
        var visited = 0
        let maximumDepth = 12
        let maximumNodes = 800

        while !queue.isEmpty {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if visited > maximumNodes { break }

            if depth > 0, isSecureTextField(element) {
                return element
            }
            guard depth < maximumDepth else { continue }

            var childrenValue: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(
                element, kAXChildrenAttribute as CFString, &childrenValue
            )
            guard status == .success, let children = childrenValue as? [AXUIElement] else {
                if status == .apiDisabled {
                    throw FaceUnlockError.accessibilityPermissionRequired
                }
                continue
            }
            for child in children {
                queue.append((child, depth + 1))
            }
        }
        return nil
    }

    private func isSecureTextField(_ element: AXUIElement) -> Bool {
        var subroleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSubroleAttribute as CFString, &subroleValue
        ) == .success, let subrole = subroleValue as? String else { return false }
        return subrole == (kAXSecureTextFieldSubrole as String)
    }

    /// Confirms the field by performing its own confirm action, never by
    /// synthesising a Return keystroke or a click at a screen position.
    private static func confirm(field: AXUIElement) throws {
        let status = AXUIElementPerformAction(field, kAXConfirmAction as CFString)
        guard status == .success else {
            throw FaceUnlockError.unlockVerificationFailed(
                "the password field did not accept the confirm action (AXError \(status.rawValue))"
            )
        }
    }
}
