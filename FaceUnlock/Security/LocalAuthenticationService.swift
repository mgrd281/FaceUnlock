import Foundation
import LocalAuthentication

/// Gate for FaceUnlock's own sensitive operations (re-enrolment, changing or
/// removing the saved password, viewing the security configuration).
///
/// This is *not* the face pipeline: it deliberately uses the system's own
/// authentication (Touch ID, Apple Watch, or the account password) so that a
/// spoofed face can never authorise changes to FaceUnlock itself.
public protocol LocalAuthenticating: Sendable {
    func biometryAvailability() -> BiometryAvailability
    func authenticate(reason: String) async throws
}

public struct BiometryAvailability: Equatable, Sendable {
    public var canEvaluate: Bool
    /// `"Touch ID"`, `"Apple Watch"`, or `nil` when only the password is available.
    public var biometryName: String?
    public var unavailableReason: String?

    public init(canEvaluate: Bool, biometryName: String?, unavailableReason: String?) {
        self.canEvaluate = canEvaluate
        self.biometryName = biometryName
        self.unavailableReason = unavailableReason
    }
}

public struct LocalAuthenticationService: LocalAuthenticating {
    public init() {}

    public func biometryAvailability() -> BiometryAvailability {
        let context = LAContext()
        var error: NSError?
        let canEvaluate = context.canEvaluatePolicy(.deviceOwnerAuthentication, with: &error)
        let name: String?
        switch context.biometryType {
        case .touchID: name = "Touch ID"
        case .opticID: name = "Optic ID"
        case .faceID: name = "Face ID"
        default: name = nil
        }
        return BiometryAvailability(
            canEvaluate: canEvaluate,
            biometryName: name,
            unavailableReason: canEvaluate ? nil : error?.localizedDescription
        )
    }

    public func authenticate(reason: String) async throws {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        // `.deviceOwnerAuthentication` falls back to the account password when no
        // biometric sensor is present, so a Mac without Touch ID is still covered.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, with: &error) else {
            throw FaceUnlockError.localAuthenticationFailed(
                error?.localizedDescription ?? "Authentication is not available on this Mac."
            )
        }
        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            guard success else {
                throw FaceUnlockError.localAuthenticationFailed("Authentication was declined.")
            }
        } catch let authError as LAError where authError.code == .userCancel {
            throw FaceUnlockError.cancelled
        } catch let authError as FaceUnlockError {
            throw authError
        } catch {
            throw FaceUnlockError.localAuthenticationFailed(error.localizedDescription)
        }
    }
}

/// Test double that records calls and returns a configured outcome.
public final class StubLocalAuthenticationService: LocalAuthenticating, @unchecked Sendable {
    private let lock = NSLock()
    public var result: Result<Void, FaceUnlockError> = .success(())
    public private(set) var reasons: [String] = []
    public var availability = BiometryAvailability(
        canEvaluate: true, biometryName: "Touch ID", unavailableReason: nil
    )

    public init() {}

    public func biometryAvailability() -> BiometryAvailability { availability }

    public func authenticate(reason: String) async throws {
        lock.lock(); reasons.append(reason); lock.unlock()
        try result.get()
    }
}
