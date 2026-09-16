import AppKit
import SwiftUI

/// Application lifecycle.
///
/// SwiftUI owns the menu-bar scene and Settings; this delegate exists for what it
/// cannot express: the activation policy (menu-bar app versus Dock app), the
/// first-run assistant, and an orderly shutdown that releases the camera and the
/// presence assertion.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public var environment: AppEnvironment?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Default to accessory: FaceUnlock is a menu-bar app unless the user has
        // asked for a Dock icon.
        NSApp.setActivationPolicy(
            environment?.preferences.showInDock == true ? .regular : .accessory
        )

        guard let environment else { return }
        Task { @MainActor in
            await environment.start()
            if !environment.preferences.hasCompletedOnboarding {
                environment.windows.show(.onboarding)
            }
        }
    }

    /// Shuts down asynchronously and then lets termination proceed.
    ///
    /// The camera session and the power assertion are torn down here rather than
    /// in `applicationWillTerminate`, because that method runs on the main thread
    /// and waiting there for main-actor work to finish would deadlock. AppKit's
    /// `terminateLater` reply is the supported way to do asynchronous cleanup.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let environment else { return .terminateNow }
        Task { @MainActor in
            await environment.shutdown()
            AppLogger.lifecycle.notice("FaceUnlock shutdown complete")
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Reopening from the Dock shows the assistant rather than nothing at all.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { environment?.windows.show(.onboarding) }
        return true
    }
}
