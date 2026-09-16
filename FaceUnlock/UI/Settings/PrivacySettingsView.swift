import SwiftUI

struct PrivacySettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        SettingsPane {
            Text("Your privacy").font(.title2.weight(.semibold))

            Card {
                VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                    StatusRow(symbolName: "camera", tint: .green,
                              title: "Camera processing happens on this Mac",
                              detail: "Frames are analysed in memory and discarded. None are written to disk.")
                    StatusRow(symbolName: "cpu", tint: .green,
                              title: "Face recognition happens on this Mac",
                              detail: "Vision and Core ML run entirely on-device, on the Neural Engine where one is present.")
                    StatusRow(symbolName: "icloud.slash", tint: .green,
                              title: "No biometric data is uploaded",
                              detail: "There is no server, no face database and no sync.")
                    StatusRow(symbolName: "key.slash", tint: .green,
                              title: "No password is uploaded",
                              detail: "A saved password stays in this Mac's Keychain.")
                    StatusRow(symbolName: "person.crop.circle.badge.xmark", tint: .green,
                              title: "No account is required",
                              detail: "FaceUnlock has no sign-in.")
                    StatusRow(symbolName: "chart.bar.xaxis", tint: .green,
                              title: "No advertising or analytics code",
                              detail: "None is linked into the app at all.")
                }
            }

            Card {
                VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                    Text("What is stored").font(.headline)
                    if let summary = environment.profileSummary {
                        StatusRow(
                            symbolName: "person.crop.square",
                            tint: .green,
                            title: "Face profile",
                            detail: "\(summary.sampleCount) descriptors of \(summary.descriptorDimension) values, encrypted with a key held in the Keychain. Created \(summary.createdAt.formatted(date: .abbreviated, time: .shortened)), updated \(summary.updatedAt.formatted(date: .abbreviated, time: .shortened))."
                        ) {
                            Button("Forget my face", role: .destructive) { environment.forgetFace() }
                        }
                    } else {
                        StatusRow(symbolName: "person.crop.square.badge.xmark", tint: .secondary,
                                  title: "Face profile", detail: "None stored.")
                    }
                    StatusRow(
                        symbolName: environment.credentials.hasSavedPassword ? "key.fill" : "key.slash",
                        tint: environment.credentials.hasSavedPassword ? .orange : .green,
                        title: "Stored credential",
                        detail: environment.credentials.hasSavedPassword
                            ? "One account password is in the Keychain."
                            : "None stored."
                    )
                }
            }

            Card {
                VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                    Text("Network").font(.headline)
                    Toggle("Check for updates", isOn: Binding(
                        get: { environment.preferences.automaticUpdateChecks },
                        set: { environment.preferences.automaticUpdateChecks = $0 }
                    ))
                    Text("The only network request FaceUnlock ever makes. It is an unauthenticated download of a version file with no identifier attached, and it is isolated from everything else: a recognition failure can never cause a network request.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    Toggle("Share anonymous usage statistics", isOn: Binding(
                        get: { environment.preferences.analyticsEnabled },
                        set: { environment.preferences.analyticsEnabled = $0 }
                    ))
                    .disabled(true)
                    Text("Off, and not implemented. FaceUnlock ships with no analytics backend, so there is nothing this switch could send. It is shown, disabled, so you can see for yourself that it is off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
