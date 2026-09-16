import AppKit
import SwiftUI

/// Where the camera housing sits on the built-in display, when there is one.
struct NotchGeometry: Equatable {
    let hasNotch: Bool
    /// Width of the housing, or 0 on a display without one.
    let width: CGFloat
    let menuBarHeight: CGFloat

    static func current(for screen: NSScreen) -> NotchGeometry {
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return NotchGeometry(
                hasNotch: true,
                width: screen.frame.width - left.width - right.width,
                menuBarHeight: top
            )
        }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return NotchGeometry(hasNotch: false, width: 0, menuBarHeight: max(24, menuBar))
    }
}

/// True inside content hosted by the notch panel, so views can adopt its
/// darker, tighter presentation.
private struct NotchPresentationKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var notchPresentation: Bool {
        get { self[NotchPresentationKey.self] }
        set { self[NotchPresentationKey.self] = newValue }
    }
}

/// A borderless panel that hangs from the top edge of the screen, flush with the
/// camera housing on Macs that have one.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Presents SwiftUI content in a panel that extends down from the notch.
///
/// One panel, one occupant at a time. The setup assistant and the recognition
/// test are *foreground* clients that the user opened deliberately; the
/// recognition overlay is a *background* client that must never displace them,
/// only fill the panel when it is otherwise unused.
@MainActor
final class NotchPanelController {
    enum Client: Int, Comparable {
        case overlay = 0
        case test = 1
        case assistant = 2

        static func < (lhs: Client, rhs: Client) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    static let bottomCornerRadius: CGFloat = 26

    private var panel: NotchPanel?
    private(set) var currentClient: Client?
    private var currentSize: CGSize = .zero

    var isPresenting: Bool { currentClient != nil }

    /// Presents `content` for `client`. A lower-priority client cannot displace
    /// a higher-priority one; the call is then a no-op and returns `false`.
    @discardableResult
    func present<Content: View>(client: Client, size: CGSize, activate: Bool, @ViewBuilder content: () -> Content) -> Bool {
        if let currentClient, currentClient > client { return false }

        let hosted = NotchPanelContainer { content() }
            .environment(\.notchPresentation, true)

        let panel = self.panel ?? makePanel()
        self.panel = panel

        let hostingView = NSHostingView(rootView: hosted)
        hostingView.sizingOptions = []
        panel.contentView = hostingView

        let wasVisible = panel.isVisible
        let target = frame(for: size)
        if wasVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            // Start collapsed to the housing's own width so the panel appears to
            // unfold out of it.
            panel.setFrame(collapsedFrame(target: target), display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.34
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 1
            }
        }
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKey()
        }
        currentClient = client
        currentSize = size
        return true
    }

    /// Hides the panel if `client` is the one currently shown.
    func dismiss(client: Client) {
        guard currentClient == client, let panel else { return }
        currentClient = nil
        let target = collapsedFrame(target: panel.frame)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                // Only tear down if nothing else has claimed the panel meanwhile.
                guard self.currentClient == nil, let panel = self.panel else { return }
                panel.orderOut(nil)
                // Dropping the hosting view fires SwiftUI's onDisappear, which is
                // how the assistant releases the camera.
                panel.contentView = nil
            }
        })
    }

    // MARK: - Geometry

    private func makePanel() -> NotchPanel {
        let panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.animationBehavior = .none
        return panel
    }

    private var screen: NSScreen {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func frame(for size: CGSize) -> NSRect {
        let screenFrame = screen.frame
        return NSRect(
            x: (screenFrame.midX - size.width / 2).rounded(),
            y: screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    private func collapsedFrame(target: NSRect) -> NSRect {
        let geometry = NotchGeometry.current(for: screen)
        let width = geometry.hasNotch ? geometry.width : 220
        let height = geometry.menuBarHeight
        return NSRect(
            x: (target.midX - width / 2).rounded(),
            y: target.maxY - height,
            width: width,
            height: height
        )
    }
}

/// Black surface with rounded bottom corners, flush with the top of the screen.
struct NotchPanelContainer<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: NotchPanelController.bottomCornerRadius,
                    bottomTrailingRadius: NotchPanelController.bottomCornerRadius,
                    topTrailingRadius: 0
                )
            )
            .preferredColorScheme(.dark)
            .environment(\.colorScheme, .dark)
            .tint(.green)
    }
}
