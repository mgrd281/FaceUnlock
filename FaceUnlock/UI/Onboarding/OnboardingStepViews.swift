import SwiftUI

struct WelcomeStepView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.large) {
            Label("FaceUnlock", systemImage: "faceid")
                .font(.largeTitle.weight(.semibold))
                .labelStyle(.titleAndIcon)

            Text("FaceUnlock uses your Mac's camera to recognise you locally.\nYour face data stays on this Mac.")
                .font(.title3)
                .fixedSize(horizontal: false, vertical: true)

            Card {
                VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                    StatusRow(
                        symbolName: "lock.laptopcomputer",
                        tint: .green,
                        title: "Everything happens on this Mac",
                        detail: "Camera frames, recognition and the stored face profile never leave this computer."
                    )
                    StatusRow(
                        symbolName: "hand.raised",
                        tint: .green,
                        title: "Nothing is uploaded",
                        detail: "No cloud account, no face database, no analytics, no advertising code."
                    )
                    StatusRow(
                        symbolName: "exclamationmark.shield",
                        tint: .orange,
                        title: "This is not Face ID",
                        detail: "A Mac camera has no depth sensor, so FaceUnlock cannot match the hardware-backed security of Apple's Face ID. It is convenience with real, but limited, spoof resistance."
                    )
                }
            }

            Text("The next steps check what this Mac supports, ask for the permissions FaceUnlock needs, and record your face.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct CompatibilityStepView: View {
    let report: SystemCompatibilityReport?

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            Text("FaceUnlock Compatibility").font(.title2.weight(.semibold))
            Text("Everything below is measured on this Mac right now. Nothing is assumed.")
                .foregroundStyle(.secondary)

            if let report {
                Card {
                    VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                        ForEach(report.checks) { check in
                            StatusRow(
                                symbolName: check.level.symbolName,
                                tint: check.level.tint,
                                title: check.title,
                                detail: check.detail
                            ) {
                                Text(check.level.label)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(check.level.tint)
                            }
                        }
                    }
                }
                if !report.canProceed {
                    Text("FaceUnlock cannot be set up on this Mac until the unsupported items above are resolved.")
                        .foregroundStyle(.red)
                }
            } else {
                ProgressView("Checking this Mac…")
            }
        }
    }
}

struct CameraPermissionStepView: View {
    let state: PermissionState
    let onRequest: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            Text("Camera access").font(.title2.weight(.semibold))
            Text("FaceUnlock needs the camera to see your face. macOS asks you for permission — FaceUnlock cannot grant it for you.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Card {
                StatusRow(
                    symbolName: state.symbolName,
                    tint: state.tint,
                    title: "Camera permission",
                    detail: state.detail
                )
            }

            HStack {
                if state == .notDetermined {
                    Button("Allow Camera Access", action: onRequest)
                        .keyboardShortcut(.defaultAction)
                } else if state != .granted {
                    Button("Open Camera Settings") {
                        SystemSettingsLinks.open(SystemSettingsLinks.camera)
                    }
                    Text(SystemSettingsLinks.cameraPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct AccessibilityStepView: View {
    let state: PermissionState
    let onPrompt: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            Text("Accessibility access").font(.title2.weight(.semibold))
            Text("FaceUnlock requires Accessibility permission only for the user-approved lock-screen interaction required by the unlock workflow.")
                .fixedSize(horizontal: false, vertical: true)

            Card {
                VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                    StatusRow(
                        symbolName: state.symbolName,
                        tint: state.tint,
                        title: "Accessibility permission",
                        detail: state.detail
                    )
                    StatusRow(
                        symbolName: "info.circle",
                        tint: .secondary,
                        title: "This step is optional",
                        detail: "FaceUnlock works without it. On current macOS versions the lock screen refuses assisted entry anyway, because macOS puts the password field into a secure input mode that no app can type into. FaceUnlock reports that honestly instead of working around it."
                    )
                }
            }

            HStack {
                Button("Open Accessibility Settings") {
                    SystemSettingsLinks.open(SystemSettingsLinks.accessibility)
                }
                Button("Ask macOS now", action: onPrompt)
                Text(SystemSettingsLinks.accessibilityPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct FinishedStepView: View {
    let environment: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.large) {
            Label("FaceUnlock is set up", systemImage: "checkmark.seal")
                .font(.title.weight(.semibold))
                .foregroundStyle(.green)

            Card {
                VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                    if let summary = environment.profileSummary {
                        StatusRow(
                            symbolName: "person.crop.square",
                            tint: .green,
                            title: "Face profile stored",
                            detail: "\(summary.sampleCount) descriptors, encrypted on this Mac. Created \(summary.createdAt.formatted(date: .abbreviated, time: .shortened))."
                        )
                    }
                    StatusRow(
                        symbolName: "bolt.shield",
                        tint: environment.unlockCapability == .supported ? .green : .orange,
                        title: "Unlock capability: \(environment.unlockCapability.label)",
                        detail: unlockDetail
                    )
                    StatusRow(
                        symbolName: "power",
                        tint: environment.loginItems.isEnabled() ? .green : .orange,
                        title: "Open at login",
                        detail: environment.loginItems.statusDescription()
                    )
                }
            }

            Text("You can change any of this later in Settings.")
                .foregroundStyle(.secondary)
        }
    }

    private var unlockDetail: String {
        switch environment.unlockCapability {
        case .supported:
            return "FaceUnlock can keep this Mac from locking while it recognises you."
        case .limited:
            return "FaceUnlock recognises you at the lock screen and tells you, but macOS requires you to finish the unlock with Touch ID or your password."
        case .unsupported:
            return "No unlock workflow is available on this Mac."
        }
    }
}
