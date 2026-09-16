import SwiftUI

@main
struct FaceUnlockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment: AppEnvironment

    init() {
        // The delegate needs the environment before `applicationDidFinishLaunching`
        // runs, and the adaptor's value already exists by the time `init` executes.
        let environment = AppEnvironment()
        _environment = State(initialValue: environment)
        appDelegate.environment = environment
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(environment)
        } label: {
            // The icon tracks the state and carries the same description VoiceOver
            // reads out, so the menu bar itself is the status indicator.
            Image(systemName: StatusPresenter.symbolName(for: environment.status))
                .accessibilityLabel(StatusPresenter.accessibilityDescription(for: environment.status))
                // Belt and braces: `AppEnvironment.start()` is idempotent, so running
                // it here as well as from the delegate guarantees the coordinator is
                // running even if the delegate is attached late.
                .task { await environment.start() }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(environment)
        }
    }
}
