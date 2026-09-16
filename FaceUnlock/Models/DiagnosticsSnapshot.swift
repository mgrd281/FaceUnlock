import Foundation

/// Everything the Diagnostics pane shows, and everything "Export Diagnostics"
/// writes out.
///
/// The type is the privacy boundary: if a value is not a field here, it cannot
/// reach an export. Deliberately absent — the saved password, any descriptor or
/// component of one, any image, any Keychain payload, the user's name, and the
/// machine's serial number or hardware UUID.
public struct DiagnosticsSnapshot: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var appVersion: String
    public var buildNumber: String
    public var osVersion: String
    public var hardwareArchitecture: String
    public var hardwareModel: String
    public var cameraDetected: Bool
    public var cameraIsBuiltIn: Bool
    public var cameraPermission: String
    public var accessibilityPermission: String
    public var loginItemStatus: String
    public var recognitionEngine: String
    public var descriptorDimension: Int
    public var profileSampleCount: Int
    public var profileCreatedAt: Date?
    public var profileUpdatedAt: Date?
    public var recognitionThreshold: Double
    public var sensitivityPreset: String
    public var livenessMode: String
    public var lastRecognitionResult: String?
    public var lastRecognitionAt: Date?
    public var lastError: String?
    public var lastErrorAt: Date?
    public var averageRecognitionLatency: TimeInterval?
    public var attemptSummary: String
    public var unlockCapability: String
    public var unlockProviders: [ProviderLine]
    public var credentialStored: Bool
    /// Which keychain holds the secrets: the data-protection keychain (signed
    /// builds) or the login keychain (ad-hoc builds). Never the contents.
    public var keychainClass: String = "data-protection"
    public var analyticsEnabled: Bool
    public var networkUsage: String

    public struct ProviderLine: Codable, Equatable, Sendable {
        public var identifier: String
        public var capability: String
        public var availableNow: Bool
    }

    /// A plain-text rendering suitable for pasting into a support message.
    public func plainText() -> String {
        let formatter = ISO8601DateFormatter()
        func date(_ value: Date?) -> String {
            value.map(formatter.string(from:)) ?? "—"
        }
        var lines: [String] = []
        lines.append("FaceUnlock diagnostics")
        lines.append("Generated: \(formatter.string(from: generatedAt))")
        lines.append("")
        lines.append("Application \(appVersion) (\(buildNumber))")
        lines.append("macOS \(osVersion) on \(hardwareModel) (\(hardwareArchitecture))")
        lines.append("")
        lines.append("Camera detected: \(cameraDetected ? (cameraIsBuiltIn ? "yes, built-in" : "yes, external") : "no")")
        lines.append("Camera permission: \(cameraPermission)")
        lines.append("Accessibility permission: \(accessibilityPermission)")
        lines.append("Open at login: \(loginItemStatus)")
        lines.append("")
        lines.append("Recognition engine: \(recognitionEngine)")
        lines.append("Descriptor dimension: \(descriptorDimension)")
        lines.append("Enrolled samples: \(profileSampleCount)")
        lines.append("Profile created: \(date(profileCreatedAt))")
        lines.append("Profile updated: \(date(profileUpdatedAt))")
        lines.append(String(format: "Recognition threshold: %.4f", recognitionThreshold))
        lines.append("Sensitivity: \(sensitivityPreset)")
        lines.append("Liveness mode: \(livenessMode)")
        lines.append("")
        lines.append("Last result: \(lastRecognitionResult ?? "—") at \(date(lastRecognitionAt))")
        lines.append("Last error: \(lastError ?? "—") at \(date(lastErrorAt))")
        lines.append(
            "Average latency: " +
            (averageRecognitionLatency.map { String(format: "%.2f s", $0) } ?? "—")
        )
        lines.append("Attempts: \(attemptSummary)")
        lines.append("")
        lines.append("Unlock capability: \(unlockCapability)")
        for provider in unlockProviders {
            lines.append("  • \(provider.identifier): \(provider.capability), available now: \(provider.availableNow)")
        }
        lines.append("")
        lines.append("Password stored in Keychain: \(credentialStored ? "yes" : "no")")
        lines.append("Keychain class: \(keychainClass)")
        lines.append("Analytics: \(analyticsEnabled ? "enabled" : "disabled")")
        lines.append("Network: \(networkUsage)")
        lines.append("")
        lines.append("This export contains no biometric data, no password and no image data.")
        return lines.joined(separator: "\n")
    }
}
