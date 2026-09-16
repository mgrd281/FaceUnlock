import SwiftUI

struct SecuritySettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        SettingsPane {
            Card {
                VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                    Text("Protect FaceUnlock itself").font(.headline)
                    Toggle("Require authentication before sensitive changes", isOn: Binding(
                        get: { environment.preferences.protectSettings },
                        set: { environment.preferences.protectSettings = $0 }
                    ))
                    Toggle("Re-authenticate before setting up my face again", isOn: Binding(
                        get: { environment.preferences.reauthenticateBeforeEnrollment },
                        set: { environment.preferences.reauthenticateBeforeEnrollment = $0 }
                    ))
                    let availability = environment.localAuthentication.biometryAvailability()
                    Text(availability.canEvaluate
                         ? "macOS will ask for \(availability.biometryName ?? "your password")."
                         : (availability.unavailableReason ?? "System authentication is unavailable on this Mac."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("This deliberately uses the system's own authentication rather than FaceUnlock's face recognition, so a spoofed face can never authorise changes to FaceUnlock.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                    Text("Saved password").font(.headline)
                    StatusRow(
                        symbolName: environment.credentials.hasSavedPassword ? "key.fill" : "key.slash",
                        tint: environment.credentials.hasSavedPassword ? .green : .secondary,
                        title: environment.credentials.hasSavedPassword
                            ? "A password is stored in the Keychain"
                            : "No password is stored",
                        detail: environment.credentials.hasSavedPassword
                            ? "FaceUnlock cannot display it. You can replace or remove it."
                            : "FaceUnlock works without one."
                    )
                    HStack {
                        Button(environment.credentials.hasSavedPassword ? "Change saved password…" : "Save my password…") {
                            environment.windows.show(.password)
                        }
                        if environment.credentials.hasSavedPassword {
                            Button("Remove saved password…", role: .destructive) {
                                environment.removeSavedPassword()
                            }
                        }
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                    Text("Security diagnostics").font(.headline)
                    ForEach(environment.providerSummaries) { provider in
                        StatusRow(
                            symbolName: provider.availableNow ? "checkmark.circle.fill" : "minus.circle",
                            tint: provider.availableNow ? .green : .secondary,
                            title: provider.displayName,
                            detail: provider.explanation
                        ) {
                            Text(provider.capability.label)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    StatusRow(
                        symbolName: "bolt.shield",
                        tint: environment.unlockCapability == .supported ? .green : .orange,
                        title: "Session unlock capability",
                        detail: environment.unlockCapability.label
                    )
                }
            }
        }
    }
}
