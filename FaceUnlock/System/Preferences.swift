import Foundation
import Observation

/// `UserDefaults` keys.
///
/// Declared at file scope rather than nested inside `Preferences` so that it is
/// unambiguously free of the class's `@MainActor` isolation and can be read from
/// the `nonisolated` static accessors below.
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

/// Non-secret user preferences, persisted to `UserDefaults`.
///
/// Everything here is safe to keep in `UserDefaults`: no credentials, no
/// biometric material, and nothing that — if edited by hand — could weaken
/// recognition beyond the ranges `RecognitionSettings.sanitized()` clamps to. The
/// recognition threshold itself deliberately lives inside the encrypted profile,
/// not here.
///
/// Each property is written manually rather than with `didSet`, because
/// `@Observable` synthesises accessors and a stored property cannot have both
/// accessors and observers. `access(keyPath:)` and `withMutation(keyPath:)` are
/// the documented way to take part in observation by hand.
@MainActor
@Observable
public final class Preferences {
    @ObservationIgnored private let defaults: UserDefaults

    @ObservationIgnored private var storedUnlockEnabled: Bool
    @ObservationIgnored private var storedShowInDock: Bool
    @ObservationIgnored private var storedShowRecognitionAnimation: Bool
    @ObservationIgnored private var storedHasCompletedOnboarding: Bool
    @ObservationIgnored private var storedProtectSettings: Bool
    @ObservationIgnored private var storedReauthenticateBeforeEnrollment: Bool
    @ObservationIgnored private var storedAnalyticsEnabled: Bool
    @ObservationIgnored private var storedAutomaticUpdateChecks: Bool
    @ObservationIgnored private var storedLockWhenAbsent: Bool
    @ObservationIgnored private var storedAllowAssistedLockScreenEntry: Bool
    @ObservationIgnored private var storedPausedUntil: Date?
    @ObservationIgnored private var storedRecognitionSettings: RecognitionSettings

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.unlockEnabled: true,
            Key.showInDock: false,
            Key.showRecognitionAnimation: true,
            Key.hasCompletedOnboarding: false,
            Key.protectSettings: true,
            Key.reauthenticateBeforeEnrollment: true,
            // Analytics default to off, and FaceUnlock ships with no analytics
            // backend at all — see PRIVACY.md.
            Key.analyticsEnabled: false,
            // The only network access the app can make, also off by default.
            Key.automaticUpdateChecks: false,
            Key.lockWhenAbsent: false,
            // Assisted lock-screen entry is opt-in and stays off until the user
            // has read what it does.
            Key.allowAssistedLockScreenEntry: false
        ])
        self.storedUnlockEnabled = defaults.bool(forKey: Key.unlockEnabled)
        self.storedShowInDock = defaults.bool(forKey: Key.showInDock)
        self.storedShowRecognitionAnimation = defaults.bool(forKey: Key.showRecognitionAnimation)
        self.storedHasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
        self.storedProtectSettings = defaults.bool(forKey: Key.protectSettings)
        self.storedReauthenticateBeforeEnrollment = defaults.bool(forKey: Key.reauthenticateBeforeEnrollment)
        self.storedAnalyticsEnabled = defaults.bool(forKey: Key.analyticsEnabled)
        self.storedAutomaticUpdateChecks = defaults.bool(forKey: Key.automaticUpdateChecks)
        self.storedLockWhenAbsent = defaults.bool(forKey: Key.lockWhenAbsent)
        self.storedAllowAssistedLockScreenEntry = defaults.bool(forKey: Key.allowAssistedLockScreenEntry)
        self.storedPausedUntil = defaults.object(forKey: Key.pausedUntil) as? Date
        self.storedRecognitionSettings = Self.decodeSettings(from: defaults)
    }

    public var unlockEnabled: Bool {
        get { access(keyPath: \.unlockEnabled); return storedUnlockEnabled }
        set { set(newValue, &storedUnlockEnabled, Key.unlockEnabled, \.unlockEnabled) }
    }

    public var showInDock: Bool {
        get { access(keyPath: \.showInDock); return storedShowInDock }
        set { set(newValue, &storedShowInDock, Key.showInDock, \.showInDock) }
    }

    public var showRecognitionAnimation: Bool {
        get { access(keyPath: \.showRecognitionAnimation); return storedShowRecognitionAnimation }
        set {
            set(newValue, &storedShowRecognitionAnimation, Key.showRecognitionAnimation, \.showRecognitionAnimation)
        }
    }

    public var hasCompletedOnboarding: Bool {
        get { access(keyPath: \.hasCompletedOnboarding); return storedHasCompletedOnboarding }
        set { set(newValue, &storedHasCompletedOnboarding, Key.hasCompletedOnboarding, \.hasCompletedOnboarding) }
    }

    public var protectSettings: Bool {
        get { access(keyPath: \.protectSettings); return storedProtectSettings }
        set { set(newValue, &storedProtectSettings, Key.protectSettings, \.protectSettings) }
    }

    public var reauthenticateBeforeEnrollment: Bool {
        get { access(keyPath: \.reauthenticateBeforeEnrollment); return storedReauthenticateBeforeEnrollment }
        set {
            set(
                newValue, &storedReauthenticateBeforeEnrollment,
                Key.reauthenticateBeforeEnrollment, \.reauthenticateBeforeEnrollment
            )
        }
    }

    public var analyticsEnabled: Bool {
        get { access(keyPath: \.analyticsEnabled); return storedAnalyticsEnabled }
        set { set(newValue, &storedAnalyticsEnabled, Key.analyticsEnabled, \.analyticsEnabled) }
    }

    public var automaticUpdateChecks: Bool {
        get { access(keyPath: \.automaticUpdateChecks); return storedAutomaticUpdateChecks }
        set { set(newValue, &storedAutomaticUpdateChecks, Key.automaticUpdateChecks, \.automaticUpdateChecks) }
    }

    public var lockWhenAbsent: Bool {
        get { access(keyPath: \.lockWhenAbsent); return storedLockWhenAbsent }
        set { set(newValue, &storedLockWhenAbsent, Key.lockWhenAbsent, \.lockWhenAbsent) }
    }

    public var allowAssistedLockScreenEntry: Bool {
        get { access(keyPath: \.allowAssistedLockScreenEntry); return storedAllowAssistedLockScreenEntry }
        set {
            set(
                newValue, &storedAllowAssistedLockScreenEntry,
                Key.allowAssistedLockScreenEntry, \.allowAssistedLockScreenEntry
            )
        }
    }

    /// `nil` means not paused. A date in the past is treated as not paused.
    public var pausedUntil: Date? {
        get { access(keyPath: \.pausedUntil); return storedPausedUntil }
        set {
            withMutation(keyPath: \.pausedUntil) { storedPausedUntil = newValue }
            if let newValue {
                defaults.set(newValue, forKey: Key.pausedUntil)
            } else {
                defaults.removeObject(forKey: Key.pausedUntil)
            }
        }
    }

    public var recognitionSettings: RecognitionSettings {
        get { access(keyPath: \.recognitionSettings); return storedRecognitionSettings }
        set {
            let sanitized = newValue.sanitized()
            withMutation(keyPath: \.recognitionSettings) { storedRecognitionSettings = sanitized }
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

    /// Shared write path: publish the change to observers, then persist it.
    private func set(
        _ newValue: Bool,
        _ storage: inout Bool,
        _ key: String,
        _ keyPath: KeyPath<Preferences, Bool>
    ) {
        withMutation(keyPath: keyPath) { storage = newValue }
        defaults.set(newValue, forKey: key)
    }

    // MARK: - Thread-safe readers
    //
    // `UserDefaults` is safe to read from any thread, so background `@Sendable`
    // closures use these instead of hopping to the main actor.

    /// `nonisolated` on purpose: members of a `@MainActor` type are main-actor
    /// isolated by default, including statics, and these are called from
    /// background `@Sendable` closures.
    public nonisolated static func assistedLockScreenEntryIsEnabled(
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.bool(forKey: Key.allowAssistedLockScreenEntry)
    }

    public nonisolated static func automaticUpdateChecksAreEnabled(
        defaults: UserDefaults = .standard
    ) -> Bool {
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
