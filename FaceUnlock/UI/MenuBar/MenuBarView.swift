import SwiftUI

/// The menu-bar panel.
///
/// `MenuBarExtra` is used in `.window` style so the panel can be a real SwiftUI
/// view with a status header, a primary toggle and grouped actions, rather than a
/// flat `NSMenu`. Every row is a focusable control, so the whole panel is
/// keyboard-navigable and reads correctly under VoiceOver.
public struct MenuBarView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openSettings) private var openSettings

    public init() {}

    public var body: some View {
        // Split into named sections rather than one long column: a SwiftUI
        // `ViewBuilder` takes at most ten children, and named sections read better
        // than a wall of rows in any case.
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            header
            errorBanner
            primaryToggle
            faceActions
            behaviourToggles
            pauseControls
            utilityActions
        }
        .padding(Design.Spacing.medium)
        .frame(width: Design.menuWidth)
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let error = environment.presentedError {
            ErrorBanner(error: error) { environment.presentedError = nil }
        }
    }

    private var primaryToggle: some View {
        Toggle(isOn: Binding(
            get: { environment.preferences.unlockEnabled },
            set: { environment.setUnlockEnabled($0) }
        )) {
            Text("Unlock with my face")
        }
        .toggleStyle(.switch)
        .accessibilityHint("Turns face recognition for unlocking on or off.")
    }

    @ViewBuilder
    private var faceActions: some View {
        Divider()
        MenuActionRow(title: "Set up my face again…", symbol: "person.crop.square") {
            environment.windows.show(.onboarding)
        }
        MenuActionRow(title: "Test face recognition…", symbol: "viewfinder") {
            environment.windows.show(.recognitionTest)
        }
        MenuActionRow(
            title: environment.credentials.hasSavedPassword
                ? "Change saved password…"
                : "Save my password…",
            symbol: "key"
        ) {
            environment.windows.show(.password)
        }
        if environment.credentials.hasSavedPassword {
            MenuActionRow(title: "Remove saved password…", symbol: "key.slash") {
                environment.removeSavedPassword()
            }
        }
        MenuActionRow(title: "Show setup assistant…", symbol: "wand.and.stars") {
            environment.windows.show(.onboarding)
        }
    }

    @ViewBuilder
    private var behaviourToggles: some View {
        Divider()
        Group {
            Toggle("Protect FaceUnlock settings…", isOn: Binding(
                get: { environment.preferences.protectSettings },
                set: { environment.preferences.protectSettings = $0 }
            ))
            .accessibilityHint("Requires Touch ID or your password before changing sensitive settings.")

            Toggle("Open FaceUnlock at login", isOn: Binding(
                get: { environment.loginItems.isEnabled() },
                set: { environment.setLoginItemEnabled($0) }
            ))

            Toggle("Show FaceUnlock in Dock", isOn: Binding(
                get: { environment.preferences.showInDock },
                set: { environment.setDockVisible($0) }
            ))

            Toggle("Show recognition animation", isOn: Binding(
                get: { environment.preferences.showRecognitionAnimation },
                set: { environment.preferences.showRecognitionAnimation = $0 }
            ))
        }
        .toggleStyle(.checkbox)
    }

    @ViewBuilder
    private var utilityActions: some View {
        Divider()
        MenuActionRow(title: "Settings…", symbol: "gearshape") { openSettings() }
        MenuActionRow(title: "Check for updates…", symbol: "arrow.down.circle") {
            environment.checkForUpdates()
        }
        MenuActionRow(title: "Diagnostics…", symbol: "stethoscope") {
            environment.windows.show(.diagnostics)
        }
        MenuActionRow(title: "About FaceUnlock", symbol: "info.circle") {
            environment.windows.show(.about)
        }
        MenuActionRow(title: "Forget my face", symbol: "trash", role: .destructive) {
            environment.forgetFace()
        }
        Divider()
        MenuActionRow(title: "Quit FaceUnlock", symbol: "power") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
        if let result = environment.lastUpdateCheck {
            Text(Self.describe(result))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Design.Spacing.small) {
            Image(systemName: StatusPresenter.symbolName(for: environment.status))
                .font(.title2)
                .foregroundStyle(StatusPresenter.tint(for: environment.status))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("FaceUnlock").font(.headline)
                Text(StatusPresenter.headline(for: environment.status))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(StatusPresenter.accessibilityDescription(for: environment.status))
    }

    @ViewBuilder
    private var pauseControls: some View {
        Divider()
        if environment.preferences.isPaused {
            MenuActionRow(title: "Resume FaceUnlock", symbol: "play.circle") {
                environment.resume()
            }
        } else {
            Menu {
                Button("For 15 minutes") { environment.pause(for: 15 * 60) }
                Button("For 1 hour") { environment.pause(for: 60 * 60) }
                Button("Until I turn it back on") { environment.pause(for: nil) }
            } label: {
                Label("Pause FaceUnlock", systemImage: "pause.circle")
            }
            .menuStyle(.borderlessButton)
        }
    }

    private static func describe(_ result: UpdateCheckResult) -> String {
        switch result {
        case let .upToDate(version): return "FaceUnlock \(version) is up to date."
        case let .updateAvailable(version, _, _): return "FaceUnlock \(version) is available."
        case let .failed(message): return message
        case .disabled: return "Update checks are switched off in Settings."
        }
    }
}

/// A single tappable row in the menu panel.
struct MenuActionRow: View {
    let title: String
    let symbol: String
    var role: ButtonRole?
    let action: () -> Void

    init(title: String, symbol: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}
