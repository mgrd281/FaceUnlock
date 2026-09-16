import AppKit
import Foundation

/// Deep links into the System Settings privacy panes.
///
/// These `x-apple.systempreferences:` URLs are the documented way for an app to
/// send the user to the right pane; they open Settings, they do not change any
/// setting. If a URL cannot be opened, the caller shows the path in text instead.
public enum SystemSettingsLinks {
    public static let camera = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
    )
    public static let accessibility = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )
    public static let loginItems = URL(
        string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    )
    public static let lockScreen = URL(
        string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension"
    )

    /// Human-readable fallback shown when the deep link is unavailable.
    public static let cameraPath = "System Settings › Privacy & Security › Camera"
    public static let accessibilityPath = "System Settings › Privacy & Security › Accessibility"
    public static let loginItemsPath = "System Settings › General › Login Items & Extensions"

    @MainActor
    @discardableResult
    public static func open(_ url: URL?) -> Bool {
        guard let url else { return false }
        return NSWorkspace.shared.open(url)
    }
}
