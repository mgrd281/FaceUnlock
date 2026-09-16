import SwiftUI

/// The Settings window.
public struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    public init() {}

    public var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            RecognitionSettingsView()
                .tabItem { Label("Face Recognition", systemImage: "faceid") }
            SecuritySettingsView()
                .tabItem { Label("Security", systemImage: "lock.shield") }
            PrivacySettingsView()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
            PermissionsSettingsView()
                .tabItem { Label("Permissions", systemImage: "checkmark.shield") }
            DiagnosticsView()
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 640, height: 500)
        .task { await environment.refreshEverything() }
    }
}

/// Shared chrome for a settings pane: a scrolling column with consistent padding.
struct SettingsPane<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Spacing.large) {
                content
            }
            .padding(Design.Spacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
