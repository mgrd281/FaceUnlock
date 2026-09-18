import AppKit
import Foundation
import Observation

/// Composition root and the single object SwiftUI views observe.
///
/// Every dependency is created here and injected downwards through protocols, so
/// the whole app can be assembled against test doubles. Nothing below this type
/// reaches for a singleton.
@MainActor
@Observable
public final class AppEnvironment {
    // MARK: Stored services

    public let preferences: Preferences
    public let permissions: any PermissionManaging
    public let loginItems: any LoginItemManaging
    public let localAuthentication: any LocalAuthenticating
    public let credentials: any CredentialStoring
    public let profileStore: any BiometricProfileStoring
    public let updateChecker: any UpdateChecking
    public let sessionLocker: any SessionLocking
    /// Owns every auxiliary window so the menu, Settings and first run all open
    /// the same instance.
    public let windows = WindowPresenter()

    let keychain: any KeychainServicing
    let camera: any CameraManaging
    let detector: any FaceDetecting
    let qualityAnalyzer: any FaceQualityAnalyzing
    let embedder: any FaceEmbeddingProviding
    let matcher: any FaceMatching
    let livenessAnalyzer: any LivenessAnalyzing
    let recognitionCoordinator: RecognitionCoordinator
    let unlockCoordinator: UnlockCoordinator
    let presenceProvider: PresenceUnlockProvider
    let brokerClient: BrokerClient
    let identityService: IdentityService
    let lockMonitor: any LockStateMonitoring

    // MARK: Observable state

    public private(set) var status: AppStatus = .notConfigured
    public private(set) var progress: RecognitionProgress = RecognitionProgress(status: .notConfigured)
    public private(set) var compatibility: SystemCompatibilityReport?
    /// Mirrored here rather than read through `permissions` on demand: a plain
    /// function call is invisible to SwiftUI's observation, so the UI would never
    /// react to the user answering a system permission prompt.
    public private(set) var cameraPermission: PermissionState = .notDetermined
    public private(set) var accessibilityPermission: PermissionState = .denied
    public private(set) var providerSummaries: [ProviderSummary] = []
    public private(set) var unlockCapability: SessionUnlockCapability = .unsupported
    public private(set) var statistics = RecognitionStatistics()
    public private(set) var profileSummary: BiometricProfile.Summary?
    /// True when a profile is stored but was enrolled by a different descriptor
    /// pipeline than the one now running. It cannot be scored; the only remedy
    /// is to enrol again.
    public private(set) var profileNeedsReenrollment = false
    private var hasAnnouncedIncompatibleProfile = false
    public private(set) var lastUpdateCheck: UpdateCheckResult?
    /// Surfaced to the UI as a dismissible banner rather than a modal alert.
    public var presentedError: FaceUnlockError?

    private var statusTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var hasStarted = false
    private var compatibilityBuilder: SystemCompatibility?
    /// Mirrors of main-actor state that background `@Sendable` closures need.
    private let capabilityMirror = Atomic<SessionUnlockCapability>(.unsupported)

    // MARK: Init

    public init(
        preferences: Preferences = Preferences(),
        keychain: (any KeychainServicing)? = nil,
        permissions: any PermissionManaging = PermissionManager(),
        loginItems: any LoginItemManaging = LoginItemManager(),
        localAuthentication: any LocalAuthenticating = LocalAuthenticationService(),
        camera: (any CameraManaging)? = nil,
        lockMonitor: any LockStateMonitoring = LockStateMonitor(),
        sessionLocker: any SessionLocking = SessionLocker()
    ) {
        // Written long-hand rather than with `??`: the operands are different
        // concrete types unified only by their protocol, which `??` cannot infer.
        let resolvedKeychain: any KeychainServicing = keychain ?? KeychainService()
        let encryption = EncryptionService(keychain: resolvedKeychain)
        let profileStore = BiometricProfileStore(encryption: encryption)
        let credentials = CredentialStore(keychain: resolvedKeychain)
        let resolvedCamera: any CameraManaging = camera ?? CameraManager()
        let validator = SecurityValidator()

        self.preferences = preferences
        self.keychain = resolvedKeychain
        self.permissions = permissions
        self.loginItems = loginItems
        self.localAuthentication = localAuthentication
        self.credentials = credentials
        self.profileStore = profileStore
        self.camera = resolvedCamera
        self.lockMonitor = lockMonitor
        self.sessionLocker = sessionLocker

        self.detector = FaceDetector()
        self.qualityAnalyzer = FaceQualityAnalyzer()
        // A bundled or user-supplied Core ML model wins when one is present;
        // otherwise the Vision feature print plus geometry pipeline is used.
        let embedder: any FaceEmbeddingProviding
        if let coreML = CoreMLFaceEmbeddingService() {
            embedder = coreML
        } else {
            embedder = VisionFaceEmbeddingService()
        }
        self.embedder = embedder
        self.matcher = FaceMatcher()
        self.livenessAnalyzer = LivenessAnalyzer()

        let presenceProvider = PresenceUnlockProvider(validator: validator)
        let accessibilityProvider = AccessibilityUnlockProvider(
            validator: validator,
            credentials: credentials,
            // Assisted entry stays off unless the user has explicitly opted in. The
            // flag is read straight from `UserDefaults`, which is thread-safe, so the
            // closure never has to touch main-actor state.
            isEnabled: { Preferences.assistedLockScreenEntryIsEnabled() }
        )
        let manualProvider = ManualConfirmationUnlockProvider()

        // The lock-screen path is a cycle in the object graph: the provider needs
        // the broker client, the client needs `IdentityService`, and that needs
        // the coordinator this provider chain is built into. The box is where the
        // cycle is cut; it is filled at the end of this initialiser, before
        // anything can ask.
        let identityBox = Atomic<(any IdentityServing)?>(nil)
        let brokerClient = BrokerClient(identity: { identityBox.value })
        let lockScreenProvider = LockScreenUnlockProvider(broker: brokerClient)
        self.brokerClient = brokerClient

        self.presenceProvider = presenceProvider
        self.unlockCoordinator = UnlockCoordinator(
            providers: [presenceProvider, lockScreenProvider, accessibilityProvider, manualProvider]
        )

        let unlockCoordinator = self.unlockCoordinator
        let preferencesBox = preferences
        self.recognitionCoordinator = RecognitionCoordinator(
            camera: resolvedCamera,
            detector: detector,
            quality: qualityAnalyzer,
            embedder: embedder,
            matcher: matcher,
            liveness: livenessAnalyzer,
            profileStore: profileStore,
            unlockCoordinator: unlockCoordinator,
            lockMonitor: lockMonitor,
            permissions: permissions,
            sessionLocker: sessionLocker,
            configurationProvider: {
                await MainActor.run {
                    RecognitionRuntimeConfiguration(
                        settings: preferencesBox.recognitionSettings,
                        unlockEnabled: preferencesBox.unlockEnabled,
                        isPaused: preferencesBox.isPaused,
                        lockWhenAbsent: preferencesBox.lockWhenAbsent
                    )
                }
            }
        )

        let identityService = IdentityService(
            recogniser: self.recognitionCoordinator,
            profileStore: profileStore,
            configurationProvider: {
                await MainActor.run {
                    RecognitionRuntimeConfiguration(
                        settings: preferencesBox.recognitionSettings,
                        unlockEnabled: preferencesBox.unlockEnabled,
                        isPaused: preferencesBox.isPaused,
                        lockWhenAbsent: preferencesBox.lockWhenAbsent
                    )
                }
            }
        )
        self.identityService = identityService
        identityBox.value = identityService

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        self.updateChecker = UpdateChecker(
            feedURL: URL(string: "https://faceunlock.de/appcast/latest.json")
                ?? URL(fileURLWithPath: "/dev/null"),
            currentVersion: version,
            isEnabled: { Preferences.automaticUpdateChecksAreEnabled() }
        )

        self.compatibilityBuilder = SystemCompatibility(
            permissions: permissions,
            loginItems: loginItems,
            keychain: resolvedKeychain,
            unlockCapabilityProvider: { [capabilityMirror] in capabilityMirror.value }
        )
    }

    // MARK: Lifecycle

    /// Idempotent: calling it again attaches nothing new and does not start a
    /// second monitoring task.
    public func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        windows.attach(environment: self)
        // Registers as the answering agent if the lock-screen components are
        // installed; a no-op with a logged note if they are not.
        brokerClient.start()
        await recognitionCoordinator.start()
        observeStatus()
        observeActivation()
        await refreshEverything()
        AppLogger.lifecycle.notice("FaceUnlock is running")
    }

    public func shutdown() async {
        hasStarted = false
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        statusTask?.cancel()
        statusTask = nil
        brokerClient.stop()
        await recognitionCoordinator.stop()
        await presenceProvider.release()
    }

    private func observeStatus() {
        guard statusTask == nil else { return }
        statusTask = Task { [weak self] in
            guard let self else { return }
            for await update in await self.recognitionCoordinator.progressUpdates() {
                self.progress = update
                self.status = update.status
                self.syncRecognitionOverlay()
            }
        }
    }

    /// Re-reads the permission states whenever the app comes back to the front.
    ///
    /// Answering a prompt, or flipping a switch in System Settings, happens outside
    /// this process; returning to FaceUnlock is the moment to notice.
    private func observeActivation() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `queue: .main` guarantees this runs on the main thread.
            MainActor.assumeIsolated {
                self?.refreshPermissions()
            }
        }
    }

    /// Cheap, synchronous re-read of the two permission states.
    public func refreshPermissions() {
        cameraPermission = permissions.cameraPermissionState()
        accessibilityPermission = permissions.accessibilityPermissionState()
    }

    /// Shows the notch indicator while an attempt is active and hides it once the
    /// coordinator settles. A user-opened panel (assistant, test) always wins.
    private func syncRecognitionOverlay() {
        guard preferences.showRecognitionAnimation else {
            windows.dismissRecognitionOverlay()
            return
        }
        switch status {
        case .monitoring, .faceDetected, .recognizing, .recognized, .unlockAttempt, .unlocked, .rejected:
            windows.showRecognitionOverlay()
        default:
            windows.dismissRecognitionOverlay()
        }
    }

    public func refreshEverything() async {
        // Repairs the broker connection if the components were installed, or the
        // daemon restarted, since the app launched. It is idempotent and cheap,
        // and it must not go through the unlock provider: in stage 0 the provider
        // reports `unsupported` without ever consulting the broker, so relying on
        // that path would leave the app unregistered exactly when the probe needs
        // it.
        brokerClient.start()
        refreshPermissions()
        await recognitionCoordinator.refreshPreconditions()
        status = await recognitionCoordinator.status
        statistics = await recognitionCoordinator.currentStatistics
        unlockCapability = await unlockCoordinator.bestAvailableCapability()
        capabilityMirror.value = unlockCapability
        providerSummaries = await unlockCoordinator.providerSummaries()
        let storedProfile = try? profileStore.load()
        profileSummary = storedProfile?.summary
        refreshProfileCompatibility(storedProfile)
        compatibility = compatibilityBuilder?.makeReport()
    }

    private func refreshProfileCompatibility(_ profile: BiometricProfile?) {
        guard let first = profile?.embeddings.first else {
            profileNeedsReenrollment = false
            return
        }
        let compatible = first.source == embedder.source && first.producerVersion == embedder.producerVersion
        profileNeedsReenrollment = !compatible
        if !compatible, !hasAnnouncedIncompatibleProfile {
            hasAnnouncedIncompatibleProfile = true
            presentedError = .profileIncompatible(stored: first.producerVersion, active: embedder.producerVersion)
            AppLogger.recognition.notice("The stored profile predates the active recognition engine; re-enrolment required")
        }
    }

    // MARK: Actions

    public func setUnlockEnabled(_ enabled: Bool) {
        preferences.unlockEnabled = enabled
        Task { await self.refreshEverything() }
    }

    public func pause(for duration: TimeInterval?) {
        preferences.pause(until: duration.map { Date().addingTimeInterval($0) })
        Task { await self.recognitionCoordinator.apply(.paused(until: self.preferences.pausedUntil)) }
    }

    public func resume() {
        preferences.resume()
        Task {
            await self.recognitionCoordinator.apply(.resumed)
            await self.refreshEverything()
        }
    }

    public func setLoginItemEnabled(_ enabled: Bool) {
        do {
            try loginItems.setEnabled(enabled)
        } catch let error as FaceUnlockError {
            presentedError = error
        } catch {
            presentedError = .loginItemRegistrationFailed(error.localizedDescription)
        }
    }

    public func setDockVisible(_ visible: Bool) {
        preferences.showInDock = visible
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
    }

    /// Runs a sensitive action, asking the system to authenticate first when the
    /// user has asked for FaceUnlock's own settings to be protected.
    public func performProtected(
        reason: String,
        _ action: @escaping @MainActor () async -> Void
    ) {
        Task {
            if self.preferences.protectSettings {
                do {
                    try await self.localAuthentication.authenticate(reason: reason)
                } catch let error as FaceUnlockError {
                    if error != .cancelled { self.presentedError = error }
                    return
                } catch {
                    self.presentedError = .localAuthenticationFailed(error.localizedDescription)
                    return
                }
            }
            await action()
        }
    }

    public func forgetFace() {
        performProtected(reason: "confirm removing your face profile from FaceUnlock") { [weak self] in
            guard let self else { return }
            do {
                try self.profileStore.forgetEverything()
                await self.recognitionCoordinator.profileDidChange(nil)
                self.preferences.hasCompletedOnboarding = false
                await self.refreshEverything()
                AppLogger.security.notice("User removed the biometric profile")
            } catch let error as FaceUnlockError {
                self.presentedError = error
            } catch {
                self.presentedError = .profileCorrupted
            }
        }
    }

    public func removeSavedPassword() {
        performProtected(reason: "confirm removing your saved password") { [weak self] in
            guard let self else { return }
            do {
                try self.credentials.removePassword()
                await self.refreshEverything()
            } catch let error as FaceUnlockError {
                self.presentedError = error
            } catch {
                self.presentedError = .keychainFailure(status: -1)
            }
        }
    }

    public func checkForUpdates() {
        Task {
            self.lastUpdateCheck = await self.updateChecker.checkForUpdates()
        }
    }

    public func makeEnrollmentCoordinator() -> EnrollmentCoordinator {
        EnrollmentCoordinator(
            camera: camera,
            detector: detector,
            quality: qualityAnalyzer,
            embedder: embedder,
            matcher: matcher,
            profileStore: profileStore
        )
    }

    public func profileDidChange(_ profile: BiometricProfile?) async {
        await recognitionCoordinator.profileDidChange(profile)
        await refreshEverything()
    }

    // MARK: Diagnostics

    public func makeDiagnosticsSnapshot() async -> DiagnosticsSnapshot {
        let info = Bundle.main.infoDictionary
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let cameras = CameraDiscovery.availableCameras()
        let profile = try? profileStore.load()
        let summaries = await unlockCoordinator.providerSummaries()
        let stats = await recognitionCoordinator.currentStatistics

        return DiagnosticsSnapshot(
            generatedAt: Date(),
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "0.0.0",
            buildNumber: info?["CFBundleVersion"] as? String ?? "0",
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            hardwareArchitecture: SystemCompatibility.isAppleSilicon ? "arm64" : "x86_64",
            hardwareModel: SystemCompatibility.hardwareModel,
            cameraDetected: !cameras.isEmpty,
            cameraIsBuiltIn: cameras.contains { $0.isBuiltIn },
            cameraPermission: permissions.cameraPermissionState().rawValue,
            accessibilityPermission: permissions.accessibilityPermissionState().rawValue,
            loginItemStatus: loginItems.statusDescription(),
            recognitionEngine: embedder.producerVersion,
            descriptorDimension: profile?.embeddings.first?.dimension ?? 0,
            profileSampleCount: profile?.embeddings.count ?? 0,
            profileCreatedAt: profile?.createdAt,
            profileUpdatedAt: profile?.updatedAt,
            recognitionThreshold: profile?.recognitionThreshold ?? 0,
            sensitivityPreset: preferences.recognitionSettings.sensitivity.rawValue,
            livenessMode: preferences.recognitionSettings.livenessMode.rawValue,
            lastRecognitionResult: stats.lastResultDescription,
            lastRecognitionAt: stats.lastResultAt,
            lastError: stats.lastErrorDescription,
            lastErrorAt: stats.lastErrorAt,
            averageRecognitionLatency: stats.averageLatency,
            attemptSummary: stats.successRateDescription,
            unlockCapability: unlockCapability.label,
            unlockProviders: summaries.map {
                DiagnosticsSnapshot.ProviderLine(
                    identifier: $0.identifier,
                    capability: $0.capability.label,
                    availableNow: $0.availableNow
                )
            },
            credentialStored: credentials.hasSavedPassword,
            keychainClass: (keychain as? KeychainService)?.usesDataProtectionKeychain == false
                ? "login keychain (ad-hoc build)" : "data-protection",
            analyticsEnabled: preferences.analyticsEnabled,
            networkUsage: preferences.automaticUpdateChecks
                ? "Update checks only, when requested"
                : "No network access"
        )
    }
}
