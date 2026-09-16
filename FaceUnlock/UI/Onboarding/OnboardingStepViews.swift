import SwiftUI

struct WelcomeStepView: View {
    var body: some View {
        VStack(spacing: Design.Spacing.section) {
            StepHeader(
                symbolName: "faceid",
                title: "FaceUnlock",
                subtitle: "FaceUnlock uses your Mac's camera to recognise you locally. Your face data stays on this Mac."
            )

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
            .frame(maxWidth: 640)

            Text("The next steps check what this Mac supports, ask for the permissions FaceUnlock needs, and record your face.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
        }
    }
}

struct CompatibilityStepView: View {
    let report: SystemCompatibilityReport?

    var body: some View {
        VStack(spacing: Design.Spacing.section) {
            StepHeader(
                symbolName: "checkmark.seal",
                title: "Compatibility",
                subtitle: "Everything below is measured on this Mac right now. Nothing is assumed."
            )

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
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(check.level.tint)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(check.level.tint.opacity(0.12), in: Capsule())
                            }
                        }
                    }
                }
                .frame(maxWidth: 640)

                if !report.canProceed {
                    Text("FaceUnlock cannot be set up on this Mac until the unsupported items above are resolved.")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
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
        VStack(spacing: Design.Spacing.section) {
            StepHeader(
                symbolName: "camera",
                title: "Camera access",
                subtitle: "FaceUnlock needs the camera to see your face. macOS asks you for permission — FaceUnlock cannot grant it for you."
            )

            Card {
                StatusRow(
                    symbolName: state.symbolName,
                    tint: state.tint,
                    title: "Camera permission",
                    detail: state.detail
                )
            }
            .frame(maxWidth: 560)

            if state == .notDetermined {
                Button {
                    onRequest()
                } label: {
                    Label("Allow Camera Access", systemImage: "camera.fill")
                        .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            } else if state != .granted {
                VStack(spacing: Design.Spacing.small) {
                    Button("Open Camera Settings") {
                        SystemSettingsLinks.open(SystemSettingsLinks.camera)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Text(SystemSettingsLinks.cameraPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("Granted — you can continue.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }
}

struct AccessibilityStepView: View {
    let state: PermissionState
    let onPrompt: () -> Void

    var body: some View {
        VStack(spacing: Design.Spacing.section) {
            StepHeader(
                symbolName: "accessibility",
                title: "Accessibility access",
                subtitle: "FaceUnlock requires Accessibility permission only for the user-approved lock-screen interaction required by the unlock workflow."
            )

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
            .frame(maxWidth: 640)

            HStack(spacing: Design.Spacing.medium) {
                Button("Open Accessibility Settings") {
                    SystemSettingsLinks.open(SystemSettingsLinks.accessibility)
                }
                Button("Ask macOS now", action: onPrompt)
            }
            .controlSize(.large)

            Text(SystemSettingsLinks.accessibilityPath)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct FinishedStepView: View {
    let environment: AppEnvironment

    var body: some View {
        VStack(spacing: Design.Spacing.section) {
            StepHeader(
                symbolName: "checkmark.seal.fill",
                title: "FaceUnlock is set up",
                subtitle: "You can change any of this later in Settings.",
                tint: .green
            )

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
            .frame(maxWidth: 640)
        }
    }

    private var unlockDetail: String {
        switch environment.unlockCapability {
        case .supported:
            return "When this Mac starts to go idle, FaceUnlock checks whether you are there and keeps it awake if you are."
        case .limited:
            return "FaceUnlock recognises you at the lock screen and tells you, but macOS requires you to finish the unlock with Touch ID or your password."
        case .unsupported:
            return "No unlock workflow is available on this Mac."
        }
    }
}
