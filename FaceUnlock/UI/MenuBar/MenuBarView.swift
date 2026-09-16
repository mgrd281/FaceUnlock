import SwiftUI

/// The menu-bar panel.
///
/// `MenuBarExtra` in `.window` style, so the panel is a real SwiftUI view: a
/// status header, a primary switch, and grouped rows with a fixed icon column and
/// real switch controls. Every row is a focusable control, so the panel is
/// keyboard-navigable and reads correctly under VoiceOver.
public struct MenuBarView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openSettings) private var openSettings

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            errorBanner
            primaryToggle
            faceActions
            behaviourToggles
            pauseControls
            utilityActions
        }
        .padding(Design.Spacing.small)
        .frame(width: Design.menuWidth)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: Design.Spacing.medium) {
            Image(systemName: StatusPresenter.symbolName(for: environment.status))
                .font(.system(size: 30, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(headerTint)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("FaceUnlock").font(.headline)
                Text(StatusPresenter.headline(for: environment.status))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Design.Spacing.small)
        .padding(.vertical, Design.Spacing.small)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(StatusPresenter.accessibilityDescription(for: environment.status))
    }

    private var headerTint: Color {
        switch environment.status {
        case .ready, .recognized, .unlocked: return .green
        default: return StatusPresenter.tint(for: environment.status)
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let error = environment.presentedError {
            ErrorBanner(error: error) { environment.presentedError = nil }
                .padding(.horizontal, Design.Spacing.tight)
                .padding(.bottom, Design.Spacing.tight)
        }
    }

    @ViewBuilder
    private var primaryToggle: some View {
        MenuDivider()
        MenuToggleRow(
            title: "Unlock with my face",
            symbol: "faceid",
            isOn: Binding(
                get: { environment.preferences.unlockEnabled },
                set: { environment.setUnlockEnabled($0) }
            ),
            prominent: true
        )
        .accessibilityHint("Turns face recognition for unlocking on or off.")
    }

    @ViewBuilder
    private var faceActions: some View {
        MenuDivider()
        MenuActionRow(title: "Set up my face again…", symbol: "person.crop.square") {
            environment.windows.show(.onboarding)
        }
        MenuActionRow(title: "Test face recognition…", symbol: "viewfinder") {
            environment.windows.show(.recognitionTest)
        }
        MenuActionRow(
            title: environment.credentials.hasSavedPassword ? "Change saved password…" : "Save my password…",
            symbol: "key"
        ) {
            environment.windows.show(.password)
        }
        if environment.credentials.hasSavedPassword {
            MenuActionRow(title: "Remove saved password…", symbol: "key.slash") {
                environment.removeSavedPassword()
            }
        }
        MenuToggleRow(
            title: "Protect FaceUnlock settings",
            symbol: "lock.shield",
            isOn: Binding(
                get: { environment.preferences.protectSettings },
                set: { environment.preferences.protectSettings = $0 }
            )
        )
        .accessibilityHint("Requires Touch ID or your password before changing sensitive settings.")
    }

    @ViewBuilder
    private var behaviourToggles: some View {
        MenuDivider()
        MenuToggleRow(
            title: "Show recognition animation",
            symbol: "sparkles",
            isOn: Binding(
                get: { environment.preferences.showRecognitionAnimation },
                set: { environment.preferences.showRecognitionAnimation = $0 }
            )
        )
        MenuToggleRow(
            title: "Show FaceUnlock in the Dock",
            symbol: "dock.rectangle",
            isOn: Binding(
                get: { environment.preferences.showInDock },
                set: { environment.setDockVisible($0) }
            )
        )
        MenuToggleRow(
            title: "Open FaceUnlock at login",
            symbol: "power",
            isOn: Binding(
                get: { environment.loginItems.isEnabled() },
                set: { environment.setLoginItemEnabled($0) }
            )
        )
    }

    @ViewBuilder
    private var pauseControls: some View {
        MenuDivider()
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
                MenuRowLabel(title: "Pause FaceUnlock", symbol: "pause.circle", trailingSymbol: "chevron.right")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
    }

    @ViewBuilder
    private var utilityActions: some View {
        MenuDivider()
        MenuActionRow(title: "Settings…", symbol: "gearshape") { openSettings() }
        MenuActionRow(title: "Check for updates…", symbol: "arrow.triangle.2.circlepath") {
            environment.checkForUpdates()
        }
        if let result = environment.lastUpdateCheck {
            Text(Self.describe(result))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Design.Spacing.medium)
                .padding(.bottom, Design.Spacing.tight)
        }
        MenuActionRow(title: "Diagnostics…", symbol: "stethoscope") {
            environment.windows.show(.diagnostics)
        }
        MenuActionRow(title: "About FaceUnlock", symbol: "info.circle") {
            environment.windows.show(.about)
        }
        MenuDivider()
        MenuActionRow(title: "Forget my face", symbol: "trash", tint: .red) {
            environment.forgetFace()
        }
        MenuActionRow(title: "Quit FaceUnlock", symbol: "xmark.circle") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
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

// MARK: - Rows

/// A thin separator with the panel's own vertical rhythm.
struct MenuDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, Design.Spacing.tight)
            .padding(.vertical, Design.Spacing.tight)
    }
}

/// Icon column plus title, shared by action rows and the pause menu label.
struct MenuRowLabel: View {
    let title: String
    let symbol: String
    var tint: Color = .primary
    var trailingSymbol: String?

    var body: some View {
        HStack(spacing: Design.Spacing.small + 2) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(tint == .primary ? Color.secondary : tint)
                .frame(width: 20)
            Text(title)
                .foregroundStyle(tint)
            Spacer(minLength: 0)
            if let trailingSymbol {
                Image(systemName: trailingSymbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, Design.Spacing.small)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

/// A single tappable row with a hover highlight.
struct MenuActionRow: View {
    let title: String
    let symbol: String
    var tint: Color = .primary
    let action: () -> Void

    @State private var isHovering = false

    init(title: String, symbol: String, tint: Color = .primary, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            MenuRowLabel(title: title, symbol: symbol, tint: tint)
                .background(
                    RoundedRectangle(cornerRadius: Design.Radius.control)
                        .fill(isHovering ? Color.primary.opacity(0.08) : .clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// A row whose trailing control is a real switch.
struct MenuToggleRow: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool
    var prominent: Bool = false

    var body: some View {
        HStack(spacing: Design.Spacing.small + 2) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(prominent ? Color.accentColor : Color.secondary)
                .frame(width: 20)
            Text(title)
                .font(prominent ? .body.weight(.semibold) : .body)
            Spacer(minLength: Design.Spacing.small)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(prominent ? .regular : .small)
        }
        .padding(.horizontal, Design.Spacing.small)
        .padding(.vertical, prominent ? 6 : 3)
    }
}
