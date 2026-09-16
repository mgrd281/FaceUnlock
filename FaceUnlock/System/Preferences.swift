import Foundation
import Observation

/// Non-secret user preferences.
///
/// Everything in this type is safe to keep in `UserDefaults`: it contains no
/// credentials, no biometric material and nothing that, if edited by hand, could
/// weaken recognition beyond the clamped ranges enforced by
/// `RecognitionSettings.sanitized()`.
@MainActor
@Observable
public final class Preferences {
    private enum Key {
        static let unlockEnabled = "unlockEnabled"
        static let showInDock = "showInDock"
        static let showRecognitionAnimation = "showRecognitionAnimation"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let protectSettings = "protectSettingsWithSystemAuthentication"
        static let reauthenticateBeforeEnrollment = "reauthenticateBeforeEnrollment"
        static let analyticsEnabled = "analyticsEnabled"
        static let automaticUpdateChecks = "automaticUpdateChecks"
        static let recognitionSettings = "recognitionSettings"
        static let pausedUntil = "pausedUntil"
        static let lockWhenAbsent = "lockWhenAbsent"
        static let allowAssistedLockScreenEntry = "allowAssistedLockScreenEntry"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.unlockEnabled: true,
            Key.showInDock: false,
            Key.showRecognitionAnimation: true,
            Key.hasCompletedOnboarding: false,
            Key.protectSettings: true,
            Key.reauthenticateBeforeEnrollment: true,
            // Analytics are off by default and FaceUnlock ships without any
            // analytics backend at all — see PRIVACY.md.
            Key.analyticsEnabled: false,
            Key.automaticUpdateChecks: false,
            Key.lockWhenAbsent: false,
            // Assisted lock-screen entry is opt-in and stays off until the user
            // reads what it does and turns it on.
            Key.allowAssistedLockScreenEntry: false
        ])
        self.unlockEnabled = defaults.bool(forKey: Key.unlockEnabled)
        self.showInDock = defaults.bool(forKey: Key.showInDock)
        self.showRecognitionAnimation = defaults.bool(forKey: Key.showRecognitionAnimation)
        self.hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
        self.protectSettings = defaults.bool(forKey: Key.protectSettings)
        self.reauthenticateBeforeEnrollment = defaults.bool(forKey: Key.reauthenticateBeforeEnrollment)
        self.analyticsEnabled = defaults.bool(forKey: Key.analyticsEnabled)
        self.automaticUpdateChecks = defaults.bool(forKey: Key.automaticUpdateChecks)
        self.lockWhenAbsent = defaults.bool(forKey: Key.lockWhenAbsent)
        self.allowAssistedLockScreenEntry = defaults.bool(forKey: Key.allowAssistedLockScreenEntry)
        self.pausedUntil = defaults.object(forKey: Key.pausedUntil) as? Date
        self.recognitionSettings = Self.decodeSettings(from: defaults)
    }

    public var unlockEnabled: Bool { didSet { defaults.set(unlockEnabled, forKey: Key.unlockEnabled) } }
    public var showInDock: Bool { didSet { defaults.set(showInDock, forKey: Key.showInDock) } }
    public var showRecognitionAnimation: Bool {
        didSet { defaults.set(showRecognitionAnimation, forKey: Key.showRecognitionAnimation) }
    }
    public var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }
    public var protectSettings: Bool { didSet { defaults.set(protectSettings, forKey: Key.protectSettings) } }
    public var reauthenticateBeforeEnrollment: Bool {
        didSet { defaults.set(reauthenticateBeforeEnrollment, forKey: Key.reauthenticateBeforeEnrollment) }
    }
    public var analyticsEnabled: Bool { didSet { defaults.set(analyticsEnabled, forKey: Key.analyticsEnabled) } }
    public var automaticUpdateChecks: Bool {
        didSet { defaults.set(automaticUpdateChecks, forKey: Key.automaticUpdateChecks) }
    }
    public var lockWhenAbsent: Bool { didSet { defaults.set(lockWhenAbsent, forKey: Key.lockWhenAbsent) } }
    public var allowAssistedLockScreenEntry: Bool {
        didSet { defaults.set(allowAssistedLockScreenEntry, forKey: Key.allowAssistedLockScreenEntry) }
    }

    /// `nil` means not paused; a date in the past is treated as not paused.
    public var pausedUntil: Date? {
        didSet {
            if let pausedUntil {
                defaults.set(pausedUntil, forKey: Key.pausedUntil)
            } else {
                defaults.removeObject(forKey: Key.pausedUntil)
            }
        }
    }

    public var recognitionSettings: RecognitionSettings {
        didSet {
            let sanitized = recognitionSettings.sanitized()
            if let data = try? JSONEncoder().encode(sanitized) {
                defaults.set(data, forKey: Key.recognitionSettings)
            }
        }
    }

    /// True when FaceUnlock is paused right now.
    public var isPaused: Bool {
        guard let pausedUntil else { return false }
        return pausedUntil > Date()
    }

    /// Pauses indefinitely (`nil`) or until a point in time.
    public func pause(until date: Date?) {
        pausedUntil = date ?? Date.distantFuture
    }

    public func resume() {
        pausedUntil = nil
    }

    // MARK: - Thread-safe readers
    //
    // `UserDefaults` is safe to read from any thread, so background `@Sendable`
    // closures use these instead of hopping to the main actor.

    public static func assistedLockScreenEntryIsEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: Key.allowAssistedLockScreenEntry)
    }

    public static func automaticUpdateChecksAreEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: Key.automaticUpdateChecks)
    }

    private static func decodeSettings(from defaults: UserDefaults) -> RecognitionSettings {
        guard let data = defaults.data(forKey: Key.recognitionSettings),
              let decoded = try? JSONDecoder().decode(RecognitionSettings.self, from: data) else {
            return .default
        }
        return decoded.sanitized()
    }
}
