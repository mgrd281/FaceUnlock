import AppKit
import SwiftUI

/// Application lifecycle.
///
/// SwiftUI owns the menu-bar scene and Settings; this delegate exists for what it
/// cannot express: the activation policy (menu-bar app versus Dock app), starting
/// and stopping the coordinator around the app's own lifetime, and releasing the
/// camera and the presence assertion on the way out.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public var environment: AppEnvironment?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        guard let environment else { return }
        NSApp.setActivationPolicy(environment.preferences.showInDock ? .regular : .accessory)

        Task { @MainActor in
            await environment.start()
            if !environment.preferences.hasCompletedOnboarding {
                environment.windows.show(.onboarding)
            }
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        guard let environment else { return }
        // Bounded shutdown: the camera and the power assertion must be released,
        // but quitting must not hang if something is stuck.
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            await environment.shutdown()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
        AppLogger.lifecycle.notice("FaceUnlock terminated")
    }

    /// Reopening from the Dock shows the assistant rather than nothing at all.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { environment?.windows.show(.onboarding) }
        return true
    }
}
