import SwiftUI

struct AboutView: View {
    @Environment(AppEnvironment.self) private var environment

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    var body: some View {
        SettingsPane {
            HStack(spacing: Design.Spacing.medium) {
                Image(systemName: "faceid")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Design.Spacing.tight) {
                    Text("FaceUnlock").font(.largeTitle.weight(.semibold))
                    Text("Version \(version)").foregroundStyle(.secondary)
                    Text("de.faceunlock.mac").font(.caption).foregroundStyle(.secondary)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                    Text("What FaceUnlock is").font(.headline)
                    Text("A local face-recognition helper for macOS. It recognises you with this Mac's camera, entirely on-device, and uses that to keep your session open while you are present and to confirm your identity at the lock screen.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("What it is not").font(.headline)
                    Text("It is not Face ID and does not claim to be. Face ID authenticates against a depth map produced by dedicated infrared hardware and is backed by the Secure Enclave. A Mac's camera is a plain 2D sensor, so FaceUnlock's spoof resistance comes from software heuristics alone and is meaningfully weaker.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("FaceUnlock never bypasses macOS security. FileVault pre-boot authentication, the login window after a restart or logout, and Gatekeeper are untouched — and cannot be touched by an app like this one.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: Design.Spacing.small) {
                    Text("Recognition engine").font(.headline)
                    Text(environment.progress.status.identifier == "notConfigured"
                         ? "No profile enrolled yet."
                         : StatusPresenter.headline(for: environment.status))
                        .foregroundStyle(.secondary)
                    Text("FaceUnlock is an original implementation. It uses no third-party trademarks, icons, models or assets.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Standalone About window.
public struct AboutWindowView: View {
    public init() {}
    public var body: some View {
        AboutView().frame(width: 560, height: 520)
    }
}
