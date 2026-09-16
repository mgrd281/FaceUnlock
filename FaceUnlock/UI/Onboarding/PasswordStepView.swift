import SwiftUI

/// Saving the account password.
///
/// Presented identically in the assistant and in its own window. Three rules the
/// view enforces: the password is never echoed back after saving, it is validated
/// against the system directory before it is stored, and it can be removed in one
/// click at any time.
struct PasswordStepView: View {
    let environment: AppEnvironment

    @State private var password = ""
    @State private var shortName = NSUserName()
    @State private var isSaving = false
    @State private var savedSuccessfully = false
    @State private var error: FaceUnlockError?

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            StepHeader(
                symbolName: "key.fill",
                title: "Saved password",
                subtitle: "Optional, and on current macOS versions not usable — the honest recommendation is to skip this step."
            )
            .padding(.bottom, Design.Spacing.small)

            Card {
                VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                    StatusRow(
                        symbolName: "questionmark.circle",
                        tint: .secondary,
                        title: "Why FaceUnlock would need this",
                        detail: "Only the assisted lock-screen workflow uses your account password, to type it into macOS's own password field after recognising you. Nothing else in FaceUnlock needs it."
                    )
                    StatusRow(
                        symbolName: "exclamationmark.triangle",
                        tint: .orange,
                        title: "On current macOS this workflow is refused",
                        detail: "macOS puts the lock-screen password field into a secure input mode that no application can type into. FaceUnlock will not pretend otherwise. If you save a password today it will simply sit unused in your Keychain, so the honest recommendation is to skip this step."
                    )
                    StatusRow(
                        symbolName: "lock.shield",
                        tint: .green,
                        title: "How it is stored",
                        detail: "In the macOS Keychain only, marked as non-synchronising and readable only while this Mac is unlocked. Never in preferences, never in a file, never in a log, never sent anywhere."
                    )
                }
            }

            if environment.credentials.hasSavedPassword {
                Card {
                    StatusRow(
                        symbolName: "key.fill",
                        tint: .green,
                        title: "A password is saved",
                        detail: "FaceUnlock cannot show it to you — it can only replace it or remove it."
                    ) {
                        Button("Remove", role: .destructive) {
                            environment.removeSavedPassword()
                        }
                    }
                }
            }

            Toggle(
                "Allow assisted lock-screen entry when macOS permits it",
                isOn: Binding(
                    get: { environment.preferences.allowAssistedLockScreenEntry },
                    set: { environment.preferences.allowAssistedLockScreenEntry = $0 }
                )
            )
            .accessibilityHint("Even when enabled, FaceUnlock refuses unless it can cryptographically verify Apple's login window and no secure-input context is active.")

            Grid(alignment: .leading, horizontalSpacing: Design.Spacing.medium, verticalSpacing: Design.Spacing.small) {
                GridRow {
                    Text("Account name")
                    TextField("Short user name", text: $shortName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                }
                GridRow {
                    Text("Password")
                    SecureField("Your macOS account password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                }
            }

            if let error {
                ErrorBanner(error: error) { self.error = nil }
            }
            if savedSuccessfully {
                Label("Password verified and saved to the Keychain.", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }

            HStack {
                Button(isSaving ? "Checking…" : "Verify and save") { save() }
                    .disabled(password.isEmpty || shortName.isEmpty || isSaving)
                Text("FaceUnlock checks the password with macOS before saving it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func save() {
        isSaving = true
        savedSuccessfully = false
        error = nil
        let credentials = environment.credentials
        let submitted = password
        let name = shortName
        // Clear the field immediately: from here on the value only exists inside
        // the store's own scope.
        password = ""

        Task {
            do {
                try await credentials.validateAndStore(password: submitted, shortName: name)
                savedSuccessfully = true
                await environment.refreshEverything()
            } catch let failure as FaceUnlockError {
                error = failure
            } catch {
                self.error = .credentialValidationFailed
            }
            isSaving = false
        }
    }
}

/// Standalone window wrapper for the same view.
public struct PasswordWindowView: View {
    @Environment(AppEnvironment.self) private var environment

    public init() {}

    public var body: some View {
        ScrollView {
            PasswordStepView(environment: environment)
                .padding(Design.Spacing.large)
        }
        .frame(minWidth: 560, minHeight: 520)
    }
}
