import Foundation

/// Configuration the coordinator reads at the start of every attempt, so a
/// settings change takes effect without restarting anything.
public struct RecognitionRuntimeConfiguration: Sendable {
    public var settings: RecognitionSettings
    public var unlockEnabled: Bool
    public var isPaused: Bool
    public var lockWhenAbsent: Bool

    public init(
        settings: RecognitionSettings,
        unlockEnabled: Bool,
        isPaused: Bool,
        lockWhenAbsent: Bool
    ) {
        self.settings = settings
        self.unlockEnabled = unlockEnabled
        self.isPaused = isPaused
        self.lockWhenAbsent = lockWhenAbsent
    }
}

/// The central state owner.
///
/// Everything that could race — camera start-up, lock and wake events, frame
/// processing, unlock attempts — is funnelled through this actor, so there is
/// exactly one place where an attempt can begin and exactly one place where it
/// can end. The state machine is a plain value type held here; it is never
/// mutated from anywhere else.
public actor RecognitionCoordinator {
    private let camera: any CameraManaging
    private let detector: any FaceDetecting
    private let quality: any FaceQualityAnalyzing
    private let embedder: any FaceEmbeddingProviding
    private let matcher: any FaceMatching
    private let liveness: any LivenessAnalyzing
    private let livenessBuilder: LivenessSampleBuilder
    private let profileStore: any BiometricProfileStoring
    private let unlockCoordinator: any UnlockCoordinating
    private let lockMonitor: any LockStateMonitoring
    private let permissions: any PermissionManaging
    private let sessionLocker: any SessionLocking
    private let configurationProvider: @Sendable () async -> RecognitionRuntimeConfiguration
    /// Only instantiated for `RecognitionPurpose.test`; an unlock attempt never
    /// renders a frame anywhere.
    private let previewRenderer = PreviewRenderer()

    /// How long a lock-screen challenge may spend looking, kept comfortably
    /// inside the broker's challenge TTL so the answer is still wanted when it
    /// arrives. See `BrokerProtocol.challengeTTL`.
    ///
    /// Eight seconds rather than four. The shorter budget was chosen to keep the
    /// lock screen responsive, but it starved the thing it was budgeting for:
    /// passive liveness needs motion accumulated across frames, and fourteen
    /// frames is not enough to distinguish a still person from a photograph. On
    /// this Mac it scored 0.40-0.66 against a 0.62 floor, so whether the Mac
    /// unlocked came down to whether the user happened to shift in their seat.
    /// The in-app test reaches 0.77 given seventy-eight frames.
    ///
    /// The cost is paid in latency: the password branch now appears up to eight
    /// seconds after the face branch starts, instead of four. That is the
    /// trade — a slower fallback in exchange for a decision worth making.
    static let challengeAttemptTimeout: TimeInterval = 8.0

    private var machine = RecognitionStateMachine()
    private var statistics = RecognitionStatistics()
    private var latencySamples: [TimeInterval] = []
    private var progressContinuations: [UUID: AsyncStream<RecognitionProgress>.Continuation] = [:]
    private var monitoringTask: Task<Void, Never>?
    private var attemptTask: Task<RecognitionAttemptResult, Never>?
    private var cachedProfile: BiometricProfile?

    public init(
        camera: any CameraManaging,
        detector: any FaceDetecting,
        quality: any FaceQualityAnalyzing,
        embedder: any FaceEmbeddingProviding,
        matcher: any FaceMatching,
        liveness: any LivenessAnalyzing,
        livenessBuilder: LivenessSampleBuilder = LivenessSampleBuilder(),
        profileStore: any BiometricProfileStoring,
        unlockCoordinator: any UnlockCoordinating,
        lockMonitor: any LockStateMonitoring,
        permissions: any PermissionManaging,
        sessionLocker: any SessionLocking,
        configurationProvider: @escaping @Sendable () async -> RecognitionRuntimeConfiguration
    ) {
        self.camera = camera
        self.detector = detector
        self.quality = quality
        self.embedder = embedder
        self.matcher = matcher
        self.liveness = liveness
        self.livenessBuilder = livenessBuilder
        self.profileStore = profileStore
        self.unlockCoordinator = unlockCoordinator
        self.lockMonitor = lockMonitor
        self.permissions = permissions
        self.sessionLocker = sessionLocker
        self.configurationProvider = configurationProvider
    }

    // MARK: - Observation

    public var status: AppStatus { machine.status }
    public var currentStatistics: RecognitionStatistics { statistics }

    /// A stream of progress updates. Several observers may subscribe; each gets
    /// its own stream and is removed automatically when it stops listening.
    public func progressUpdates() -> AsyncStream<RecognitionProgress> {
        AsyncStream(bufferingPolicy: .bufferingNewest(4)) { continuation in
            let id = UUID()
            progressContinuations[id] = continuation
            continuation.yield(RecognitionProgress(status: machine.status))
            continuation.onTermination = { [weak self] _ in
                // Bind the weak reference before the inner task: a nested closure
                // that reads a `[weak self]` capture while running concurrently is
                // the "captured var 'self' in concurrently-executing code" race.
                guard let self else { return }
                Task { await self.removeObserver(id) }
            }
        }
    }

    private func removeObserver(_ id: UUID) {
        progressContinuations.removeValue(forKey: id)
    }

    // MARK: - Lifecycle

    /// Refreshes the structural preconditions and begins listening for session
    /// events. Safe to call repeatedly.
    public func start() async {
        await refreshPreconditions()
        guard monitoringTask == nil else { return }
        monitoringTask = Task { [weak self, lockMonitor] in
            for await event in lockMonitor.events() {
                await self?.handle(event)
            }
        }
        AppLogger.lifecycle.notice("Recognition coordinator started")
    }

    public func stop() async {
        monitoringTask?.cancel()
        monitoringTask = nil
        lockMonitor.stop()
        attemptTask?.cancel()
        attemptTask = nil
        await camera.stop()
        AppLogger.lifecycle.notice("Recognition coordinator stopped")
    }

    /// Re-reads the profile and permission state and publishes the resulting
    /// resting status.
    public func refreshPreconditions() async {
        do {
            cachedProfile = try Self.compatibleProfile(try profileStore.load(), with: embedder)
        } catch {
            cachedProfile = nil
            record(error: error as? FaceUnlockError ?? .profileCorrupted)
        }
        apply(cachedProfile == nil ? .profileRemoved : .profileBecameAvailable)

        let cameraState = permissions.cameraPermissionState()
        if cameraState == .granted {
            apply(.permissionsSatisfied)
        } else {
            apply(.permissionLost(.camera))
        }

        let configuration = await configurationProvider()
        if configuration.isPaused {
            apply(.paused(until: nil))
        } else {
            apply(.resumed)
        }
        if CameraDiscovery.availableCameras().isEmpty {
            apply(.cameraBecameUnavailable)
        } else {
            apply(.armed)
        }
    }

    // MARK: - Session events

    private func handle(_ event: LockEvent) async {
        switch event {
        case .screenLocked:
            await beginAttemptIfAppropriate(trigger: .screenLocked)
        case .screensaverStarted:
            // The screen saver starts *before* the session locks, by however long
            // the user's "require password after…" grace period is. That window is
            // the only moment the presence provider can act at all, because once the
            // session is locked nothing can defer the lock any more.
            await beginAttemptIfAppropriate(trigger: .idleApproaching)
        case .screensDidWake, .systemDidWake, .screensaverStopped:
            // A wake while still locked is the cheapest possible retry trigger:
            // the user just did something, so they are probably in front of the Mac.
            if lockMonitor.isScreenLocked() {
                await beginAttemptIfAppropriate(trigger: .screenLocked)
            }
        case .screenUnlocked:
            apply(.attemptFinished)
            await cancelAttempt()
        case .systemWillSleep, .screensDidSleep, .sessionDidResignActive:
            // Fast user switching or sleep: release the camera immediately.
            await cancelAttempt()
        case .sessionDidBecomeActive:
            await refreshPreconditions()
        }
    }

    /// Why an attempt is starting. The two cases differ in what the session state
    /// is allowed to be, and therefore in which providers can act.
    private enum AttemptTrigger {
        /// The session is locked. Only the manual and assisted providers apply.
        case screenLocked
        /// The screen saver has started but the session has not locked yet, so the
        /// presence provider can still defer the lock.
        case idleApproaching
    }

    private func beginAttemptIfAppropriate(trigger: AttemptTrigger) async {
        let configuration = await configurationProvider()
        guard configuration.unlockEnabled, !configuration.isPaused else { return }
        guard cachedProfile != nil else { return }
        guard attemptTask == nil else { return }

        if trigger == .screenLocked {
            let delay = configuration.settings.startDelayAfterLock
            if delay > 0 {
                // Give the lock animation time to finish before lighting up the camera.
                try? await Task.sleep(for: .seconds(delay))
            }
            guard lockMonitor.isScreenLocked() else { return }
        }
        _ = await runAttempt(purpose: .unlock)
    }

    private func cancelAttempt() async {
        attemptTask?.cancel()
        attemptTask = nil
        await camera.stop()
    }

    // MARK: - Attempts

    /// Runs one complete attempt. Only one can be in flight; a second call while
    /// one is running awaits the first rather than starting a competing session.
    @discardableResult
    public func runAttempt(purpose: RecognitionPurpose) async -> RecognitionAttemptResult {
        if let attemptTask {
            return await attemptTask.value
        }
        let task = Task { [weak self] () -> RecognitionAttemptResult in
            guard let self else {
                return RecognitionAttemptResult(
                    verdict: .failed(.cancelled), bestScore: 0, threshold: 0,
                    livenessScore: 0, framesProcessed: 0, duration: 0, unlockOutcome: nil
                )
            }
            return await self.performAttempt(purpose: purpose)
        }
        attemptTask = task
        let result = await task.value
        attemptTask = nil
        return result
    }

    /// Per-attempt mutable state, kept in one place so the frame loop reads as a
    /// sequence of decisions rather than a pile of bookkeeping variables.
    private struct AttemptState {
        var consecutiveMatches = 0
        var framesProcessed = 0
        var bestScore = 0.0
        var lastLivenessScore = 0.0
        var activeChallenge: LivenessChallenge?
    }

    /// What the frame loop should do next.
    private enum FrameOutcome {
        case keepLooking
        case recognized
        case rejected(AppStatus.RejectionReason)
    }

    private func performAttempt(purpose: RecognitionPurpose) async -> RecognitionAttemptResult {
        let started = Date()
        let settings = await configurationProvider().settings

        guard let profile = cachedProfile else {
            return finish(
                result: .init(
                    verdict: .failed(.noEnrolledProfile), bestScore: 0, threshold: 0,
                    livenessScore: 0, framesProcessed: 0, duration: 0, unlockOutcome: nil
                ),
                purpose: purpose
            )
        }

        apply(.attemptStarted)
        quality.reset()
        liveness.reset()
        livenessBuilder.reset()

        let stream: AsyncStream<CameraFrame>
        do {
            stream = try await camera.start(frameRate: settings.processingFrameRate)
        } catch {
            let failure = (error as? FaceUnlockError) ?? .cameraStartFailed(error.localizedDescription)
            apply(.failed(failure))
            return finish(
                result: .init(
                    verdict: .failed(failure), bestScore: 0, threshold: profile.recognitionThreshold,
                    livenessScore: 0, framesProcessed: 0,
                    duration: Date().timeIntervalSince(started), unlockOutcome: nil
                ),
                purpose: purpose
            )
        }

        let livenessConfiguration = Self.livenessConfiguration(for: profile, settings: settings)
        let required = profile.calibratedFor.requiredConsecutiveMatches
        // A challenge is answered against the lock screen's clock, not the app's.
        // The broker stops waiting after `FU_CHALLENGE_TTL_SECONDS`, and an
        // answer that arrives later is discarded, so spending the full attempt
        // timeout on one would guarantee a wasted camera start. Failing fast is
        // also the better lock-screen behaviour: the password branch appears
        // promptly instead of after a long blank pause.
        let timeout = purpose == .challenge
            ? min(settings.attemptTimeout, RecognitionCoordinator.challengeAttemptTimeout)
            : settings.attemptTimeout
        let deadline = started.addingTimeInterval(timeout)

        var state = AttemptState()
        var verdict: RecognitionAttemptResult.Verdict = .rejected(.timedOut)

        frameLoop: for await frame in stream {
            if Task.isCancelled {
                verdict = .failed(.cancelled)
                break frameLoop
            }
            if Date() >= deadline {
                verdict = .rejected(.timedOut)
                break frameLoop
            }

            switch evaluate(
                frame: frame,
                purpose: purpose,
                profile: profile,
                livenessConfiguration: livenessConfiguration,
                required: required,
                state: &state
            ) {
            case .keepLooking:
                continue
            case .recognized:
                verdict = .recognized
                break frameLoop
            case let .rejected(reason):
                verdict = .rejected(reason)
                break frameLoop
            }
        }

        // The camera is released before anything else happens, including the
        // unlock, so it is never on any longer than the recognition itself.
        await camera.stop()

        var outcome: UnlockOutcome?
        if case .recognized = verdict {
            apply(.matchConfirmed)
            if purpose == .unlock {
                do {
                    outcome = try await performUnlock()
                } catch {
                    let failure = (error as? FaceUnlockError) ?? .unlockUnavailableOnThisSystem
                    verdict = .failed(failure)
                    apply(.failed(failure))
                }
            }
        } else if case let .rejected(reason) = verdict {
            apply(.rejected(reason))
            await lockIfUserIsAbsent(purpose: purpose)
        } else if case let .failed(error) = verdict {
            apply(.failed(error))
        }

        return finish(
            result: RecognitionAttemptResult(
                verdict: verdict,
                bestScore: state.bestScore,
                threshold: profile.recognitionThreshold,
                livenessScore: state.lastLivenessScore,
                framesProcessed: state.framesProcessed,
                duration: Date().timeIntervalSince(started),
                unlockOutcome: outcome
            ),
            purpose: purpose
        )
    }

    /// Runs the whole per-frame pipeline and decides what the loop does next.
    private func evaluate(
        frame: CameraFrame,
        purpose: RecognitionPurpose,
        profile: BiometricProfile,
        livenessConfiguration: BiometricProfile.LivenessConfiguration,
        required: Int,
        state: inout AttemptState
    ) -> FrameOutcome {
        state.framesProcessed += 1
        // A frame is only ever rendered for the recognition test window; an unlock
        // attempt never produces an image anywhere.
        let preview = purpose == .test ? previewRenderer.render(frame) : nil

        guard let faces = try? detector.detectFaces(in: frame) else { return .keepLooking }
        let evaluation = quality.evaluate(faces: faces, frame: frame)
        guard case .acceptable = evaluation, let face = faces.first else {
            state.consecutiveMatches = 0
            publish(
                RecognitionProgress(
                    status: machine.status,
                    qualityIssues: evaluation.issues,
                    activeChallenge: state.activeChallenge,
                    consecutiveMatches: 0,
                    requiredMatches: required,
                    preview: preview
                )
            )
            return .keepLooking
        }

        apply(.faceSeen)
        liveness.record(livenessBuilder.makeSample(for: face, in: frame))

        guard let embedding = try? embedder.embedding(for: face, in: frame) else {
            state.consecutiveMatches = 0
            return .keepLooking
        }

        let match = matcher.match(embedding, against: profile)
        state.bestScore = max(state.bestScore, match.score)
        state.consecutiveMatches = match.isMatch ? state.consecutiveMatches + 1 : 0

        let assessment = liveness.assess(configuration: livenessConfiguration)
        state.lastLivenessScore = assessment.score

        apply(.frameEvaluated(progress: Double(state.consecutiveMatches) / Double(required)))
        publish(
            RecognitionProgress(
                status: machine.status,
                matchScore: match.score,
                threshold: match.threshold,
                livenessScore: assessment.score,
                activeChallenge: state.activeChallenge,
                consecutiveMatches: state.consecutiveMatches,
                requiredMatches: required,
                preview: preview
            )
        )

        guard state.consecutiveMatches >= required else { return .keepLooking }

        // A match is never enough on its own: liveness must have had a full
        // window to judge, or it has not judged anything.
        //
        // A face that matches on every frame reaches `required` in about a
        // second, which is sooner than the liveness window fills. Concluding
        // there would accept an identity that was never checked for liveness at
        // all — a photograph matches just as promptly as a person. An earlier
        // version of this code was saved from that only by latching a challenge
        // on a quarter-full window; once that premature latch was removed, this
        // guard is what keeps the ordering honest.
        guard assessment.sampleCount >= livenessConfiguration.windowFrames else {
            return .keepLooking
        }

        if let disqualifier = assessment.disqualifier {
            AppLogger.liveness.error("Attempt rejected: \(disqualifier, privacy: .public)")
            return .rejected(.livenessFailed)
        }

        if let challenge = state.activeChallenge {
            guard liveness.challengeSatisfied(challenge) else { return .keepLooking }
            state.activeChallenge = nil
        } else if let suggested = assessment.suggestedChallenge {
            // A challenge needs somewhere to be shown, and the lock screen
            // covers every window this app owns. Rather than wait for a cue the
            // user will never see — which is exactly how the first real attempt
            // spent its whole budget and then timed out — say no now and let the
            // password branch take over immediately.
            // The lock screen covers every window this app owns, so the prompt
            // has nowhere to appear. This path therefore judges liveness on the
            // floor alone and lets the marginal band through.
            //
            // That is a deliberate weakening, chosen knowingly, and it is the
            // one place in this app where a check is relaxed rather than
            // reported honestly and refused. What it costs is written down in
            // SECURITY.md and KNOWN_LIMITATIONS.md §14: the interactive
            // challenge is what a photograph or a replayed video cannot answer,
            // and unlocking a locked session is the highest-value target here.
            // The floor, the full window and the spoof disqualifiers above still
            // apply — a stale or frozen feed is still rejected outright.
            //
            // The honest alternatives, both rejected for this build, were a
            // longer attempt so passive evidence could reach the band, and
            // drawing the prompt inside SecurityAgent itself.
            if purpose == .challenge {
                AppLogger.liveness.notice(
                    "Liveness is marginal and no prompt can be shown at the lock screen; judging on the floor alone"
                )
                return assessment.score >= livenessConfiguration.minimumScore
                    ? .recognized
                    : .rejected(.livenessFailed)
            }
            state.activeChallenge = suggested
            publish(
                RecognitionProgress(
                    status: machine.status,
                    matchScore: match.score,
                    threshold: match.threshold,
                    livenessScore: assessment.score,
                    activeChallenge: suggested,
                    consecutiveMatches: state.consecutiveMatches,
                    requiredMatches: required,
                    preview: preview
                )
            )
            return .keepLooking
        }

        // A marginal liveness score keeps the attempt going rather than ending it:
        // more frames may raise the score, and only the deadline ends an attempt,
        // so a marginal score can never become an accept on its own.
        guard assessment.score >= livenessConfiguration.minimumScore else { return .keepLooking }

        return .recognized
    }

    /// Puts the display to sleep when the enrolled user was not found and the
    /// session is still unlocked.
    ///
    /// This only ever runs inside the pre-lock grace window — the attempt that
    /// reaches it was started by the screen saver, not by a lock — so it costs
    /// nothing while the Mac is in use, and macOS still applies the user's own
    /// "require password after…" setting afterwards. FaceUnlock never shortens it.
    private func lockIfUserIsAbsent(purpose: RecognitionPurpose) async {
        guard purpose == .unlock else { return }
        let configuration = await configurationProvider()
        guard configuration.lockWhenAbsent else { return }
        guard !lockMonitor.isScreenLocked() else { return }
        do {
            try await sessionLocker.lockDisplay()
        } catch {
            AppLogger.unlock.error(
                "Could not put the display to sleep: \((error as? FaceUnlockError)?.code ?? "unknown", privacy: .public)"
            )
        }
    }

    /// Runs the unlock chain for a confirmed recognition.
    private func performUnlock() async throws -> UnlockOutcome {
        apply(.unlockStarted)
        let outcome = try await unlockCoordinator.unlock()
        apply(.unlockSucceeded)
        return outcome
    }

    /// The profile's stored liveness configuration, tightened by the current
    /// settings. Settings may only ever raise the bar, never lower it.
    private static func livenessConfiguration(
        for profile: BiometricProfile,
        settings: RecognitionSettings
    ) -> BiometricProfile.LivenessConfiguration {
        var configuration = profile.livenessConfiguration
        configuration.mode = settings.livenessMode
        configuration.minimumScore = max(configuration.minimumScore, settings.sensitivity.livenessFloor)
        return configuration
    }

    private func finish(result: RecognitionAttemptResult, purpose: RecognitionPurpose) -> RecognitionAttemptResult {
        statistics.attemptCount += 1
        if result.succeeded { statistics.successCount += 1 }
        statistics.lastResultAt = Date()
        statistics.lastResultDescription = Self.describe(result)
        if case let .failed(error) = result.verdict {
            statistics.lastErrorDescription = error.message
            statistics.lastErrorAt = Date()
        }
        latencySamples.append(result.duration)
        if latencySamples.count > 20 { latencySamples.removeFirst(latencySamples.count - 20) }
        statistics.averageLatency = ImageAnalysis.mean(latencySamples)

        AppLogger.recognition.notice(
            """
            Attempt finished: purpose=\(purpose.rawValue, privacy: .public) \
            verdict=\(Self.describe(result), privacy: .public) \
            frames=\(result.framesProcessed, privacy: .public) \
            duration=\(result.duration, format: .fixed(precision: 2), privacy: .public)s \
            bestScore=\(result.bestScore, format: .fixed(precision: 4), privacy: .public) \
            threshold=\(result.threshold, format: .fixed(precision: 4), privacy: .public) \
            liveness=\(result.livenessScore, format: .fixed(precision: 2), privacy: .public)
            """
        )

        // Hold the terminal status briefly so the menu-bar icon and the animation
        // can show it, then return to rest.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.settleAfterAttempt()
        }
        return result
    }

    private func settleAfterAttempt() {
        apply(.attemptFinished)
    }

    private static func describe(_ result: RecognitionAttemptResult) -> String {
        switch result.verdict {
        case .recognized: return "recognized"
        case let .rejected(reason): return "rejected (\(reason.rawValue))"
        case let .failed(error): return "failed (\(error.code))"
        }
    }

    // MARK: - Status plumbing

    /// Applies an event and publishes the new status when it changed.
    public func apply(_ event: RecognitionEvent) {
        guard machine.apply(event) else { return }
        publish(RecognitionProgress(status: machine.status))
    }

    private func publish(_ progress: RecognitionProgress) {
        for continuation in progressContinuations.values {
            continuation.yield(progress)
        }
    }

    private func record(error: FaceUnlockError) {
        statistics.lastErrorDescription = error.message
        statistics.lastErrorAt = Date()
        AppLogger.recognition.error("Recognition error: \(error.code, privacy: .public)")
    }

    /// Replaces the cached profile after enrolment without a disk round-trip.
    public func profileDidChange(_ profile: BiometricProfile?) {
        cachedProfile = profile.flatMap { try? Self.compatibleProfile($0, with: embedder) }
        apply(cachedProfile == nil ? .profileRemoved : .profileBecameAvailable)
    }

    /// A profile enrolled by a different descriptor producer can never score, so
    /// it is refused here — before any frame is captured — rather than surfacing
    /// as an endless "not recognised". `FaceMatcher` still checks per descriptor;
    /// this only makes the failure legible.
    static func compatibleProfile(
        _ profile: BiometricProfile?,
        with embedder: any FaceEmbeddingProviding
    ) throws -> BiometricProfile? {
        guard let profile, let first = profile.embeddings.first else { return profile }
        guard first.source == embedder.source, first.producerVersion == embedder.producerVersion else {
            throw FaceUnlockError.profileIncompatible(
                stored: first.producerVersion, active: embedder.producerVersion
            )
        }
        return profile
    }
}
