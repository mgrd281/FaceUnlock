import AppKit
import SwiftUI

/// Presents FaceUnlock's auxiliary windows.
///
/// A menu-bar accessory app has no main window and is not activated by default,
/// so opening a window means creating it, bringing it to the front *and*
/// activating the app. Doing that in one place keeps every entry point — the menu,
/// Settings, first run — behaving identically, and guarantees a window is reused
/// rather than duplicated when it is already open.
@MainActor
public final class WindowPresenter {
    public enum WindowID: String, CaseIterable {
        case onboarding
        case recognitionTest
        case diagnostics
        case password
        case about

        var title: String {
            switch self {
            case .onboarding: return "FaceUnlock Setup"
            case .recognitionTest: return "Test Face Recognition"
            case .diagnostics: return "FaceUnlock Diagnostics"
            case .password: return "Saved Password"
            case .about: return "About FaceUnlock"
            }
        }

        var contentSize: NSSize {
            switch self {
            case .onboarding: return NSSize(width: 820, height: 720)
            case .recognitionTest: return NSSize(width: 720, height: 700)
            case .diagnostics: return NSSize(width: 640, height: 560)
            case .password: return NSSize(width: 580, height: 560)
            case .about: return NSSize(width: 560, height: 520)
            }
        }
    }

    private var controllers: [WindowID: NSWindowController] = [:]
    private weak var environment: AppEnvironment?
    private let notch = NotchPanelController()

    /// Sizes of the surfaces hosted in the notch panel.
    static let assistantPanelSize = CGSize(width: 660, height: 600)
    static let testPanelSize = CGSize(width: 620, height: 640)
    static let overlayPanelSize = CGSize(width: 380, height: 132)

    public init() {}

    public func attach(environment: AppEnvironment) {
        self.environment = environment
    }

    public func show(_ id: WindowID) {
        guard let environment else {
            AppLogger.lifecycle.error("Window requested before the environment was attached")
            return
        }
        // The camera experiences live in the notch panel; everything else is an
        // ordinary window.
        switch id {
        case .onboarding:
            notch.present(client: .assistant, size: Self.assistantPanelSize, activate: true) {
                OnboardingView().environment(environment)
            }
            return
        case .recognitionTest:
            notch.present(client: .test, size: Self.testPanelSize, activate: true) {
                RecognitionTestView().environment(environment)
            }
            return
        default:
            break
        }

        if let existing = controllers[id] {
            NSApp.activate(ignoringOtherApps: true)
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let root = rootView(for: id, environment: environment)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: id.contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = id.title
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.center()
        window.setFrameAutosaveName("de.faceunlock.mac.\(id.rawValue)")

        let controller = NSWindowController(window: window)
        controllers[id] = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    public func close(_ id: WindowID) {
        switch id {
        case .onboarding:
            notch.dismiss(client: .assistant)
        case .recognitionTest:
            notch.dismiss(client: .test)
        default:
            controllers[id]?.close()
            controllers.removeValue(forKey: id)
        }
    }

    // MARK: - Recognition overlay

    /// Shows the small recognition indicator in the notch panel, unless the panel
    /// is already occupied by something the user opened.
    public func showRecognitionOverlay() {
        guard let environment else { return }
        guard notch.currentClient != .overlay else { return }
        notch.present(client: .overlay, size: Self.overlayPanelSize, activate: false) {
            RecognitionOverlayView().environment(environment)
        }
    }

    public func dismissRecognitionOverlay() {
        notch.dismiss(client: .overlay)
    }

    @ViewBuilder
    private func rootView(for id: WindowID, environment: AppEnvironment) -> some View {
        switch id {
        case .onboarding:
            OnboardingView().environment(environment)
        case .recognitionTest:
            RecognitionTestView().environment(environment)
        case .diagnostics:
            DiagnosticsView().environment(environment).frame(minWidth: 620, minHeight: 520)
        case .password:
            PasswordWindowView().environment(environment)
        case .about:
            AboutWindowView().environment(environment)
        }
    }
}
