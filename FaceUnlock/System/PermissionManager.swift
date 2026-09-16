import AVFoundation
import ApplicationServices
import Foundation

public enum PermissionState: String, Equatable, Sendable {
    case notDetermined
    case granted
    case denied
    case restricted

    public var detail: String {
        switch self {
        case .notDetermined: return "Not requested yet"
        case .granted: return "Granted"
        case .denied: return "Denied"
        case .restricted: return "Restricted by this Mac's configuration"
        }
    }

    var compatibilityLevel: CompatibilityCheck.Level {
        switch self {
        case .granted: return .supported
        case .notDetermined: return .attention
        case .denied, .restricted: return .unsupported
        }
    }
}

public protocol PermissionManaging: Sendable {
    func cameraPermissionState() -> PermissionState
    func accessibilityPermissionState() -> PermissionState
    /// Presents the system's own camera prompt. Returns the resulting state.
    func requestCameraAccess() async -> PermissionState
    /// Shows the system's Accessibility prompt. macOS grants this only through
    /// System Settings — the prompt just takes the user there.
    func promptForAccessibility()
}

/// Thin wrapper over the platform permission APIs.
///
/// Nothing here works around TCC. Camera access uses `AVCaptureDevice`'s own
/// request API; Accessibility uses `AXIsProcessTrustedWithOptions`, which can
/// only *ask*. Both are one-shot from the system's perspective: once the user has
/// answered, the app must send them to System Settings rather than re-prompting.
public struct PermissionManager: PermissionManaging {
    public init() {}

    public func cameraPermissionState() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    public func accessibilityPermissionState() -> PermissionState {
        AXIsProcessTrusted() ? .granted : .denied
    }

    public func requestCameraAccess() async -> PermissionState {
        let current = cameraPermissionState()
        guard current == .notDetermined else {
            AppLogger.permissions.notice(
                "Camera permission already decided: \(current.rawValue, privacy: .public)"
            )
            return current
        }
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        let resulting: PermissionState = granted ? .granted : .denied
        AppLogger.permissions.notice(
            "Camera permission request completed: \(resulting.rawValue, privacy: .public)"
        )
        return resulting
    }

    public func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        AppLogger.permissions.notice("Accessibility prompt shown")
    }
}

/// Test double with settable states.
public final class StubPermissionManager: PermissionManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var camera: PermissionState
    private var accessibility: PermissionState
    public private(set) var cameraRequestCount = 0
    public private(set) var accessibilityPromptCount = 0
    /// State the camera moves to when a request is made.
    public var cameraRequestResult: PermissionState = .granted

    public init(camera: PermissionState = .notDetermined, accessibility: PermissionState = .denied) {
        self.camera = camera
        self.accessibility = accessibility
    }

    public func setCamera(_ state: PermissionState) { lock.lock(); camera = state; lock.unlock() }
    public func setAccessibility(_ state: PermissionState) { lock.lock(); accessibility = state; lock.unlock() }

    public func cameraPermissionState() -> PermissionState {
        lock.lock(); defer { lock.unlock() }; return camera
    }

    public func accessibilityPermissionState() -> PermissionState {
        lock.lock(); defer { lock.unlock() }; return accessibility
    }

    public func requestCameraAccess() async -> PermissionState {
        lock.lock()
        cameraRequestCount += 1
        camera = cameraRequestResult
        let result = camera
        lock.unlock()
        return result
    }

    public func promptForAccessibility() {
        lock.lock(); accessibilityPromptCount += 1; lock.unlock()
    }
}
