import SwiftUI

struct GeneralSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var environment = environment

        SettingsPane {
            Card {
                VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                    Toggle("Unlock with my face", isOn: Binding(
                        get: { environment.preferences.unlockEnabled },
                        set: { environment.setUnlockEnabled($0) }
                    ))
                    .toggleStyle(.switch)

                    Text(StatusPresenter.headline(for: environment.status))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                    Toggle("Open FaceUnlock at login", isOn: Binding(
                        get: { environment.loginItems.isEnabled() },
                        set: { environment.setLoginItemEnabled($0) }
                    ))
                    Text(environment.loginItems.statusDescription())
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    Toggle("Show FaceUnlock in the Dock", isOn: Binding(
                        get: { environment.preferences.showInDock },
                        set: { environment.setDockVisible($0) }
                    ))
                    Text("When this is off, FaceUnlock lives only in the menu bar and does not appear in the Dock or the app switcher.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    Toggle("Show recognition animation", isOn: Binding(
                        get: { environment.preferences.showRecognitionAnimation },
                        set: { environment.preferences.showRecognitionAnimation = $0 }
                    ))
                    Text("A small indicator near the menu bar while FaceUnlock is looking for you.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                    Toggle("Lock this Mac when I am no longer there", isOn: Binding(
                        get: { environment.preferences.lockWhenAbsent },
                        set: { environment.preferences.lockWhenAbsent = $0 }
                    ))
                    Text("Puts the display to sleep when FaceUnlock stops seeing you. macOS then locks according to your own Lock Screen settings — FaceUnlock does not shorten the grace period you chose.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Lock Screen Settings") {
                        SystemSettingsLinks.open(SystemSettingsLinks.lockScreen)
                    }
                }
            }
        }
    }
}
