import AVFoundation
import Foundation

/// A single line in the first-run compatibility report.
public struct CompatibilityCheck: Identifiable, Equatable, Sendable {
    public enum Level: String, Equatable, Sendable {
        case supported
        case attention
        case unsupported

        public var symbolName: String {
            switch self {
            case .supported: return "checkmark.circle.fill"
            case .attention: return "exclamationmark.triangle.fill"
            case .unsupported: return "xmark.octagon.fill"
            }
        }

        public var label: String {
            switch self {
            case .supported: return "Supported"
            case .attention: return "Attention"
            case .unsupported: return "Unsupported"
            }
        }
    }

    public var id: String { title }
    public var title: String
    public var detail: String
    public var level: Level

    public init(title: String, detail: String, level: Level) {
        self.title = title
        self.detail = detail
        self.level = level
    }
}

/// How much of the unlock story this Mac can actually deliver.
///
/// The three values are reported honestly: FaceUnlock never claims `supported`
/// for a workflow that macOS does not permit. See `KNOWN_LIMITATIONS.md`.
public enum SessionUnlockCapability: String, Equatable, Sendable {
    /// A provider can complete the unlock without the user touching the keyboard.
    case supported
    /// FaceUnlock can keep the session from locking while you are present and can
    /// confirm your identity, but the final unlock step needs you.
    case limited
    /// Nothing in the unlock workflow is available.
    case unsupported

    public var label: String {
        switch self {
        case .supported: return "Supported"
        case .limited: return "Limited"
        case .unsupported: return "Unsupported"
        }
    }
}

public struct SystemCompatibilityReport: Equatable, Sendable {
    public var osVersion: String
    public var isAppleSilicon: Bool
    public var hardwareModel: String
    public var meetsMinimumOS: Bool
    public var hasInternalCamera: Bool
    public var hasAnyCamera: Bool
    public var cameraPermission: PermissionState
    public var accessibilityPermission: PermissionState
    public var loginItemAvailable: Bool
    public var keychainAvailable: Bool
    public var unlockCapability: SessionUnlockCapability

    public var checks: [CompatibilityCheck] {
        [
            CompatibilityCheck(
                title: "macOS",
                detail: meetsMinimumOS
                    ? "macOS \(osVersion)"
                    : "macOS \(osVersion) — FaceUnlock needs macOS \(SystemCompatibility.minimumOSDescription) or later",
                level: meetsMinimumOS ? .supported : .unsupported
            ),
            CompatibilityCheck(
                title: "Apple silicon",
                detail: isAppleSilicon
                    ? "\(hardwareModel) — the Neural Engine will be used for recognition"
                    : "\(hardwareModel) — recognition runs on the CPU and GPU and will use more power",
                level: isAppleSilicon ? .supported : .attention
            ),
            CompatibilityCheck(
                title: "Camera",
                detail: cameraDetail,
                level: hasAnyCamera ? (hasInternalCamera ? .supported : .attention) : .unsupported
            ),
            CompatibilityCheck(
                title: "Camera permission",
                detail: cameraPermission.detail,
                level: cameraPermission.compatibilityLevel
            ),
            CompatibilityCheck(
                title: "Accessibility permission",
                detail: accessibilityPermission == .granted
                    ? "Granted"
                    : "Not granted — only needed for the assisted unlock workflow",
                level: accessibilityPermission == .granted ? .supported : .attention
            ),
            CompatibilityCheck(
                title: "Open at login",
                detail: loginItemAvailable
                    ? "Available"
                    : "Unavailable — register FaceUnlock manually in Login Items",
                level: loginItemAvailable ? .supported : .attention
            ),
            CompatibilityCheck(
                title: "Secure storage",
                detail: keychainAvailable ? "Keychain is available" : "Keychain could not be reached",
                level: keychainAvailable ? .supported : .unsupported
            ),
            CompatibilityCheck(
                title: "Session unlock",
                detail: unlockCapabilityDetail,
                level: unlockCapabilityLevel
            )
        ]
    }

    private var cameraDetail: String {
        if hasInternalCamera { return "Built-in camera detected" }
        if hasAnyCamera { return "Only an external camera was found" }
        return "No camera was found"
    }

    private var unlockCapabilityDetail: String {
        switch unlockCapability {
        case .supported:
            return "A provider on this Mac can complete the unlock for you"
        case .limited:
            return "FaceUnlock can recognise you and keep the session open, but macOS requires you to complete the unlock at the lock screen"
        case .unsupported:
            return "No supported unlock workflow is available on this Mac"
        }
    }

    private var unlockCapabilityLevel: CompatibilityCheck.Level {
        switch unlockCapability {
        case .supported: return .supported
        case .limited: return .attention
        case .unsupported: return .unsupported
        }
    }

    /// True when nothing blocks setting FaceUnlock up at all.
    public var canProceed: Bool {
        meetsMinimumOS && hasAnyCamera && keychainAvailable
    }
}

/// Gathers the facts shown in the compatibility report.
public struct SystemCompatibility: Sendable {
    public static let minimumOSMajor = 14
    public static let minimumOSDescription = "14.0"

    private let permissions: any PermissionManaging
    private let loginItems: any LoginItemManaging
    private let keychain: any KeychainServicing
    private let cameraDiscovery: @Sendable () -> [CameraDevice]
    private let unlockCapabilityProvider: @Sendable () -> SessionUnlockCapability

    public init(
        permissions: any PermissionManaging,
        loginItems: any LoginItemManaging,
        keychain: any KeychainServicing,
        cameraDiscovery: @escaping @Sendable () -> [CameraDevice] = { CameraDiscovery.availableCameras() },
        unlockCapabilityProvider: @escaping @Sendable () -> SessionUnlockCapability
    ) {
        self.permissions = permissions
        self.loginItems = loginItems
        self.keychain = keychain
        self.cameraDiscovery = cameraDiscovery
        self.unlockCapabilityProvider = unlockCapabilityProvider
    }

    public func makeReport() -> SystemCompatibilityReport {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let cameras = cameraDiscovery()
        return SystemCompatibilityReport(
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            isAppleSilicon: Self.isAppleSilicon,
            hardwareModel: Self.hardwareModel,
            meetsMinimumOS: version.majorVersion >= Self.minimumOSMajor,
            hasInternalCamera: cameras.contains { $0.isBuiltIn },
            hasAnyCamera: !cameras.isEmpty,
            cameraPermission: permissions.cameraPermissionState(),
            accessibilityPermission: permissions.accessibilityPermissionState(),
            loginItemAvailable: loginItems.isAvailable,
            keychainAvailable: Self.probeKeychain(keychain),
            unlockCapability: unlockCapabilityProvider()
        )
    }

    /// Reads the CPU architecture rather than trusting a compile-time flag, so a
    /// Rosetta-translated build still reports the truth about the hardware.
    public static var isAppleSilicon: Bool {
        var size = 0
        guard sysctlbyname("hw.optional.arm64", nil, &size, nil, 0) == 0, size > 0 else {
            return false
        }
        var value: Int32 = 0
        var valueSize = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.optional.arm64", &value, &valueSize, nil, 0) == 0 else {
            return false
        }
        return value == 1
    }

    public static var hardwareModel: String {
        sysctlString("hw.model") ?? "Unknown Mac"
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Writes and removes a throwaway item to confirm the keychain is reachable.
    private static func probeKeychain(_ keychain: any KeychainServicing) -> Bool {
        do {
            _ = try keychain.containsItem(.profileEncryptionKey)
            return true
        } catch {
            return false
        }
    }
}
