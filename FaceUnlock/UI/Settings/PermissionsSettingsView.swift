import SwiftUI

struct PermissionsSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        SettingsPane {
            Card {
                VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                    let camera = environment.permissions.cameraPermissionState()
                    StatusRow(
                        symbolName: camera.symbolName,
                        tint: camera.tint,
                        title: "Camera",
                        detail: camera.detail
                    ) {
                        Button("Open Settings") {
                            SystemSettingsLinks.open(SystemSettingsLinks.camera)
                        }
                    }
                    Text("Required. FaceUnlock cannot see you without it.")
                        .font(.caption).foregroundStyle(.secondary)

                    Divider()

                    let accessibility = environment.permissions.accessibilityPermissionState()
                    StatusRow(
                        symbolName: accessibility.symbolName,
                        tint: accessibility.tint,
                        title: "Accessibility",
                        detail: accessibility.detail
                    ) {
                        Button("Open Settings") {
                            SystemSettingsLinks.open(SystemSettingsLinks.accessibility)
                        }
                    }
                    Text("Optional, and only used by the assisted lock-screen workflow. FaceUnlock never requests it for anything else and works fully without it.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    StatusRow(
                        symbolName: environment.loginItems.isEnabled() ? "checkmark.circle.fill" : "circle",
                        tint: environment.loginItems.isEnabled() ? .green : .secondary,
                        title: "Open at login",
                        detail: environment.loginItems.statusDescription()
                    ) {
                        Button("Open Settings") {
                            SystemSettingsLinks.open(SystemSettingsLinks.loginItems)
                        }
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: Design.Spacing.small) {
                    Text("If a permission is revoked while FaceUnlock is running").font(.headline)
                    Text("FaceUnlock notices at the next attempt, stops using the feature that needed it and says so in the menu bar. It does not re-prompt you repeatedly — macOS only allows one prompt per permission, after which the decision belongs to System Settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Re-check now") {
                        Task { await environment.refreshEverything() }
                    }
                }
            }
        }
    }
}
