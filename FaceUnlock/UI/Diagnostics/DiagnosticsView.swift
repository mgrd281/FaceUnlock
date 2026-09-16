import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Privacy-safe diagnostics.
///
/// Everything shown here comes from `DiagnosticsSnapshot`, which is the only type
/// allowed to leave the app. It cannot carry a password, an image, or any part of
/// a descriptor, because it has no field that could hold one.
public struct DiagnosticsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var snapshot: DiagnosticsSnapshot?
    @State private var exportMessage: String?

    public init() {}

    public var body: some View {
        SettingsPane {
            HStack {
                Text("Diagnostics").font(.title2.weight(.semibold))
                Spacer()
                Button("Refresh") { Task { await reload() } }
                Button("Export Diagnostics…") { export() }
                    .disabled(snapshot == nil)
            }

            if let message = exportMessage {
                Label(message, systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.green)
            }

            if let snapshot {
                Card {
                    VStack(alignment: .leading, spacing: Design.Spacing.small) {
                        Text("System").font(.headline)
                        DiagnosticsRow("macOS", snapshot.osVersion)
                        DiagnosticsRow("Hardware", "\(snapshot.hardwareModel) (\(snapshot.hardwareArchitecture))")
                        DiagnosticsRow("FaceUnlock", "\(snapshot.appVersion) (\(snapshot.buildNumber))")
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: Design.Spacing.small) {
                        Text("Permissions and devices").font(.headline)
                        DiagnosticsRow("Camera detected", snapshot.cameraDetected ? (snapshot.cameraIsBuiltIn ? "Yes, built-in" : "Yes, external") : "No")
                        DiagnosticsRow("Camera permission", snapshot.cameraPermission)
                        DiagnosticsRow("Accessibility permission", snapshot.accessibilityPermission)
                        DiagnosticsRow("Open at login", snapshot.loginItemStatus)
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: Design.Spacing.small) {
                        Text("Recognition").font(.headline)
                        Group {
                            DiagnosticsRow("Engine", snapshot.recognitionEngine)
                            DiagnosticsRow("Descriptor dimension", "\(snapshot.descriptorDimension)")
                            DiagnosticsRow("Enrolled samples", "\(snapshot.profileSampleCount)")
                            DiagnosticsRow("Threshold", String(format: "%.4f", snapshot.recognitionThreshold))
                            DiagnosticsRow("Sensitivity", snapshot.sensitivityPreset)
                            DiagnosticsRow("Liveness mode", snapshot.livenessMode)
                        }
                        Group {
                            DiagnosticsRow("Last result", snapshot.lastRecognitionResult ?? "—")
                            DiagnosticsRow("Last error", snapshot.lastError ?? "—")
                            DiagnosticsRow(
                                "Average latency",
                                snapshot.averageRecognitionLatency.map { String(format: "%.2f s", $0) } ?? "—"
                            )
                            DiagnosticsRow("Attempts", snapshot.attemptSummary)
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: Design.Spacing.small) {
                        Text("Unlock").font(.headline)
                        DiagnosticsRow("Capability", snapshot.unlockCapability)
                        ForEach(snapshot.unlockProviders, id: \.identifier) { provider in
                            DiagnosticsRow(
                                provider.identifier,
                                "\(provider.capability), available now: \(provider.availableNow ? "yes" : "no")"
                            )
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: Design.Spacing.small) {
                        Text("Privacy").font(.headline)
                        DiagnosticsRow("Password stored", snapshot.credentialStored ? "Yes" : "No")
                        DiagnosticsRow("Analytics", snapshot.analyticsEnabled ? "Enabled" : "Disabled")
                        DiagnosticsRow("Network", snapshot.networkUsage)
                        Text("Exports never include your password, any face descriptor, any image, or any Keychain contents.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                ProgressView("Collecting diagnostics…")
            }
        }
        .task { await reload() }
    }

    private func reload() async {
        snapshot = await environment.makeDiagnosticsSnapshot()
    }

    private func export() {
        guard let snapshot else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "FaceUnlock-Diagnostics.txt"
        panel.message = "This file contains no biometric data, no password and no image data."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try snapshot.plainText().write(to: url, atomically: true, encoding: .utf8)
            exportMessage = "Saved to \(url.lastPathComponent)."
        } catch {
            exportMessage = nil
            environment.presentedError = .keychainFailure(status: -1)
        }
    }
}

struct DiagnosticsRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: Design.Spacing.medium)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}
