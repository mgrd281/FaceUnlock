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
    private let configurationProvider: @Sendable () async -> RecognitionRuntimeConfiguration
    /// Only instantiated for `RecognitionPurpose.test`; an unlock attempt never
    /// renders a frame anywhere.
    private let previewRenderer = PreviewRenderer()

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
                Task { await self?.removeObserver(id) }
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
        monitoringTask = Task { [weak self] in
            guard let self else { return }
            for await event in await self.lockMonitor.events() {
                await self.handle(event)
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
            cachedProfile = try profileStore.load()
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
        case .screenLocked, .screensaverStarted:
            await beginUnlockAttemptIfAppropriate()
        case .screensDidWake, .systemDidWake, .screensaverStopped:
            // A wake while still locked is the cheapest possible retry trigger:
            // the user just did something, so they are probably in front of the Mac.
            if lockMonitor.isScreenLocked() {
                await beginUnlockAttemptIfAppropriate()
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

    private func beginUnlockAttemptIfAppropriate() async {
        let configuration = await configurationProvider()
        guard configuration.unlockEnabled, !configuration.isPaused else { return }
        guard cachedProfile != nil else { return }
        guard attemptTask == nil else { return }

        let delay = configuration.settings.startDelayAfterLock
        if delay > 0 {
            // Give the lock animation time to finish before lighting up the camera.
            try? await Task.sleep(for: .seconds(delay))
        }
        guard lockMonitor.isScreenLocked() else { return }
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

    private func performAttempt(purpose: RecognitionPurpose) async -> RecognitionAttemptResult {
        let started = Date()
        let configuration = await configurationProvider()
        let settings = configuration.settings

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

        let required = profile.calibratedFor.requiredConsecutiveMatches
        var livenessConfiguration = profile.livenessConfiguration
        livenessConfiguration.mode = settings.livenessMode
        livenessConfiguration.minimumScore = max(
            livenessConfiguration.minimumScore, settings.sensitivity.livenessFloor
        )

        var consecutive = 0
        var framesProcessed = 0
        var bestScore = 0.0
        var lastLiveness = 0.0
        var activeChallenge: LivenessChallenge?
        var verdict: RecognitionAttemptResult.Verdict = .rejected(.timedOut)
        let deadline = started.addingTimeInterval(settings.attemptTimeout)

        frameLoop: for await frame in stream {
            if Task.isCancelled {
                verdict = .failed(.cancelled)
                break frameLoop
            }
            if Date() >= deadline {
                verdict = .rejected(.timedOut)
                break frameLoop
            }

            framesProcessed += 1
            let preview = purpose == .test ? previewRenderer.render(frame) : nil
            let faces: [DetectedFace]
            do {
                faces = try detector.detectFaces(in: frame)
            } catch {
                continue
            }

            let evaluation = quality.evaluate(faces: faces, frame: frame)
            guard case .acceptable = evaluation, let face = faces.first else {
                consecutive = 0
                publish(
                    RecognitionProgress(
                        status: machine.status,
                        qualityIssues: evaluation.issues,
                        activeChallenge: activeChallenge,
                        consecutiveMatches: 0,
                        requiredMatches: required,
                        preview: preview
                    )
                )
                continue
            }

            apply(.faceSeen)
            liveness.record(livenessBuilder.makeSample(for: face, in: frame))

            let embedding: FaceEmbedding
            do {
                embedding = try embedder.embedding(for: face, in: frame)
            } catch {
                consecutive = 0
                continue
            }

            let match = matcher.match(embedding, against: profile)
            bestScore = max(bestScore, match.score)
            consecutive = match.isMatch ? consecutive + 1 : 0

            let assessment = liveness.assess(configuration: livenessConfiguration)
            lastLiveness = assessment.score

            apply(.frameEvaluated(progress: Double(consecutive) / Double(required)))
            publish(
                RecognitionProgress(
                    status: machine.status,
                    matchScore: match.score,
                    threshold: match.threshold,
                    livenessScore: assessment.score,
                    activeChallenge: activeChallenge,
                    consecutiveMatches: consecutive,
                    requiredMatches: required,
                    preview: preview
                )
            )

            guard consecutive >= required else { continue }

            if let disqualifier = assessment.disqualifier {
                verdict = .rejected(.livenessFailed)
                AppLogger.liveness.error("Attempt rejected: \(disqualifier, privacy: .public)")
                break frameLoop
            }

            if let challenge = activeChallenge {
                guard liveness.challengeSatisfied(challenge) else { continue }
                activeChallenge = nil
            } else if let suggested = assessment.suggestedChallenge {
                activeChallenge = suggested
                publish(
                    RecognitionProgress(
                        status: machine.status,
                        matchScore: match.score,
                        threshold: match.threshold,
                        livenessScore: assessment.score,
                        activeChallenge: suggested,
                        consecutiveMatches: consecutive,
                        requiredMatches: required,
                        preview: preview
                    )
                )
                continue
            }

            guard assessment.score >= livenessConfiguration.minimumScore else {
                // Keep looking: more frames may raise the score. The deadline is the
                // only thing that ends the attempt, so a marginal score never
                // becomes an accept on its own.
                continue
            }

            verdict = .recognized
            break frameLoop
        }

        // The camera is released before anything else happens, including the
        // unlock, so it is never on any longer than the recognition itself.
        await camera.stop()

        var outcome: UnlockOutcome?
        if case .recognized = verdict {
            apply(.matchConfirmed)
            if purpose == .unlock {
                apply(.unlockStarted)
                do {
                    outcome = try await unlockCoordinator.unlock()
                    apply(.unlockSucceeded)
                } catch {
                    let failure = (error as? FaceUnlockError) ?? .unlockUnavailableOnThisSystem
                    verdict = .failed(failure)
                    apply(.failed(failure))
                }
            }
        } else if case let .rejected(reason) = verdict {
            apply(.rejected(reason))
        } else if case let .failed(error) = verdict {
            apply(.failed(error))
        }

        let result = RecognitionAttemptResult(
            verdict: verdict,
            bestScore: bestScore,
            threshold: profile.recognitionThreshold,
            livenessScore: lastLiveness,
            framesProcessed: framesProcessed,
            duration: Date().timeIntervalSince(started),
            unlockOutcome: outcome
        )
        return finish(result: result, purpose: purpose)
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
            duration=\(result.duration, format: .fixed(precision: 2), privacy: .public)s
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
        cachedProfile = profile
        apply(profile == nil ? .profileRemoved : .profileBecameAvailable)
    }
}
