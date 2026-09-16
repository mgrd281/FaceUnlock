import Foundation

/// Live state of the guided enrolment flow.
public struct EnrollmentUpdate: @unchecked Sendable {
    public var currentStep: EnrollmentPose
    public var capturedByStep: [EnrollmentPose: Int]
    public var issues: [FaceQualityIssue]
    /// Guidance derived from the measured pose, e.g. "turn a little further".
    public var guidance: String
    public var preview: PreviewImage?
    public var isComplete: Bool

    public var totalCaptured: Int { capturedByStep.values.reduce(0, +) }
    public var totalRequired: Int {
        EnrollmentPose.allCases.reduce(0) { $0 + $1.requiredSamples }
    }
    public var progress: Double {
        guard totalRequired > 0 else { return 0 }
        return Double(totalCaptured) / Double(totalRequired)
    }
}

/// Result of a completed capture pass, before calibration.
public struct EnrollmentDraft: Sendable {
    public var embeddings: [FaceEmbedding]
    public var poseTags: [EnrollmentPose]

    public var isUsable: Bool {
        embeddings.count >= EnrollmentPose.allCases.count
            && embeddings.count == poseTags.count
    }
}

/// Runs the guided capture and the calibration pass that follows it.
///
/// Enrolment never writes an image anywhere. Each accepted frame is turned into a
/// descriptor in memory and the frame is then dropped; the only thing that
/// survives the flow is the encrypted profile.
public actor EnrollmentCoordinator {
    private let camera: any CameraManaging
    private let detector: any FaceDetecting
    private let quality: any FaceQualityAnalyzing
    private let embedder: any FaceEmbeddingProviding
    private let matcher: any FaceMatching
    private let profileStore: any BiometricProfileStoring
    private let previewRenderer: PreviewRenderer

    private var updateContinuation: AsyncStream<EnrollmentUpdate>.Continuation?
    private var captureTask: Task<EnrollmentDraft, Error>?

    public init(
        camera: any CameraManaging,
        detector: any FaceDetecting,
        quality: any FaceQualityAnalyzing,
        embedder: any FaceEmbeddingProviding,
        matcher: any FaceMatching,
        profileStore: any BiometricProfileStoring,
        previewRenderer: PreviewRenderer = PreviewRenderer()
    ) {
        self.camera = camera
        self.detector = detector
        self.quality = quality
        self.embedder = embedder
        self.matcher = matcher
        self.profileStore = profileStore
        self.previewRenderer = previewRenderer
    }

    public func updates() -> AsyncStream<EnrollmentUpdate> {
        AsyncStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            updateContinuation = continuation
        }
    }

    public func cancel() async {
        captureTask?.cancel()
        captureTask = nil
        await camera.stop()
        updateContinuation?.finish()
        updateContinuation = nil
    }

    /// Captures the full set of guided samples.
    public func capture() async throws -> EnrollmentDraft {
        if let captureTask { return try await captureTask.value }
        let task = Task { [weak self] () throws -> EnrollmentDraft in
            guard let self else { throw FaceUnlockError.cancelled }
            return try await self.performCapture()
        }
        captureTask = task
        defer { captureTask = nil }
        return try await task.value
    }

    private func performCapture() async throws -> EnrollmentDraft {
        quality.reset()
        // A higher rate than unlock monitoring: the preview has to feel live and
        // the user is present and waiting, so the extra power cost is justified.
        let stream = try await camera.start(frameRate: 12)
        defer { Task { await camera.stop() } }

        var embeddings: [FaceEmbedding] = []
        var poseTags: [EnrollmentPose] = []
        var captured: [EnrollmentPose: Int] = [:]
        var stepIndex = 0
        let steps = EnrollmentPose.allCases
        /// Descriptors captured for the current step, used to reject near-duplicates.
        var currentStepEmbeddings: [FaceEmbedding] = []

        for await frame in stream {
            try Task.checkCancellation()
            guard stepIndex < steps.count else { break }
            let step = steps[stepIndex]
            let preview = previewRenderer.render(frame)

            let faces = (try? detector.detectFaces(in: frame)) ?? []
            let evaluation = quality.evaluate(faces: faces, frame: frame)

            guard case let .acceptable(measured) = evaluation, let face = faces.first else {
                emit(
                    EnrollmentUpdate(
                        currentStep: step,
                        capturedByStep: captured,
                        issues: evaluation.issues,
                        guidance: evaluation.issues.first?.message ?? step.instruction,
                        preview: preview,
                        isComplete: false
                    )
                )
                continue
            }

            let poseDistance = measured.pose.angularDistance(to: step.targetPose)
            guard poseDistance <= step.tolerance else {
                emit(
                    EnrollmentUpdate(
                        currentStep: step,
                        capturedByStep: captured,
                        issues: [],
                        guidance: Self.guidance(for: step, measured: measured.pose),
                        preview: preview,
                        isComplete: false
                    )
                )
                continue
            }

            guard let embedding = try? embedder.embedding(for: face, in: frame) else {
                emit(
                    EnrollmentUpdate(
                        currentStep: step,
                        capturedByStep: captured,
                        issues: [.occluded],
                        guidance: "Make sure your whole face is visible.",
                        preview: preview,
                        isComplete: false
                    )
                )
                continue
            }

            // Reject a descriptor that is almost identical to one already captured
            // for this step: three copies of the same instant add no information and
            // would make the calibration spread artificially small.
            let isDuplicate = currentStepEmbeddings.contains { existing in
                SimilarityMetric.cosine.score(existing, embedding) > 0.995
            }
            if isDuplicate {
                emit(
                    EnrollmentUpdate(
                        currentStep: step,
                        capturedByStep: captured,
                        issues: [],
                        guidance: "Hold that position — moving very slightly helps.",
                        preview: preview,
                        isComplete: false
                    )
                )
                continue
            }

            embeddings.append(embedding)
            poseTags.append(step)
            currentStepEmbeddings.append(embedding)
            captured[step, default: 0] += 1

            if captured[step, default: 0] >= step.requiredSamples {
                stepIndex += 1
                currentStepEmbeddings.removeAll(keepingCapacity: true)
                quality.reset()
            }

            let nextStep = stepIndex < steps.count ? steps[stepIndex] : step
            emit(
                EnrollmentUpdate(
                    currentStep: nextStep,
                    capturedByStep: captured,
                    issues: [],
                    guidance: stepIndex < steps.count ? nextStep.instruction : "All set.",
                    preview: preview,
                    isComplete: stepIndex >= steps.count
                )
            )
            if stepIndex >= steps.count { break }
        }

        await camera.stop()
        let draft = EnrollmentDraft(embeddings: embeddings, poseTags: poseTags)
        guard draft.isUsable else {
            throw FaceUnlockError.enrollmentIncomplete(
                capturedSamples: embeddings.count,
                requiredSamples: steps.reduce(0) { $0 + $1.requiredSamples }
            )
        }
        AppLogger.recognition.notice(
            "Enrolment captured \(embeddings.count, privacy: .public) descriptors"
        )
        return draft
    }

    /// Runs the calibration pass: live frames are matched against the freshly
    /// captured descriptors to measure how tightly this user's own scores cluster.
    ///
    /// `onScore` is called for every genuine score so the UI can show a live
    /// confidence indicator.
    public func calibrate(
        draft: EnrollmentDraft,
        sensitivity: SensitivityPreset,
        livenessMode: LivenessMode,
        sampleTarget: Int = 20,
        timeout: TimeInterval = 25,
        onScore: @Sendable @escaping (Double, PreviewImage?) -> Void
    ) async throws -> BiometricProfile {
        // A provisional profile with the preset floor as the threshold, used only
        // to score the calibration frames.
        let provisional = BiometricProfile(
            createdAt: Date(),
            updatedAt: Date(),
            embeddings: draft.embeddings,
            poseTags: draft.poseTags,
            recognitionThreshold: sensitivity.scoreFloor,
            metric: .cosine,
            livenessConfiguration: .init(
                mode: livenessMode,
                minimumScore: sensitivity.livenessFloor,
                windowFrames: 12
            ),
            calibratedFor: sensitivity
        )

        quality.reset()
        let stream = try await camera.start(frameRate: 10)
        defer { Task { await camera.stop() } }

        var scores: [Double] = []
        let deadline = Date().addingTimeInterval(timeout)
        for await frame in stream {
            try Task.checkCancellation()
            if scores.count >= sampleTarget || Date() >= deadline { break }
            let preview = previewRenderer.render(frame)
            let faces = (try? detector.detectFaces(in: frame)) ?? []
            guard case .acceptable = quality.evaluate(faces: faces, frame: frame),
                  let face = faces.first,
                  let embedding = try? embedder.embedding(for: face, in: frame) else {
                onScore(-1, preview)
                continue
            }
            let match = matcher.match(embedding, against: provisional)
            scores.append(match.score)
            onScore(match.score, preview)
        }
        await camera.stop()

        guard scores.count >= ThresholdCalibrator.minimumSamples else {
            throw FaceUnlockError.enrollmentQualityTooLow(
                "only \(scores.count) usable calibration frames were captured"
            )
        }

        let outcome = ThresholdCalibrator.calibrate(genuineScores: scores, preset: sensitivity)
        AppLogger.recognition.notice(
            """
            Calibration complete: samples=\(outcome.sampleCount, privacy: .public) \
            threshold=\(outcome.threshold, format: .fixed(precision: 4), privacy: .public) \
            clampedToFloor=\(outcome.clampedToFloor, privacy: .public)
            """
        )

        var profile = provisional
        profile.recognitionThreshold = outcome.threshold
        profile.updatedAt = Date()
        try profileStore.save(profile)
        return profile
    }

    private func emit(_ update: EnrollmentUpdate) {
        updateContinuation?.yield(update)
    }

    private static func guidance(for step: EnrollmentPose, measured: FacePose) -> String {
        let target = step.targetPose
        let yawDelta = measured.yaw - target.yaw
        let pitchDelta = measured.pitch - target.pitch
        if abs(yawDelta) > abs(pitchDelta) {
            return yawDelta > 0 ? "Turn a little back to your left." : "Turn a little further to your right."
        }
        return pitchDelta > 0 ? "Lower your chin slightly." : "Raise your chin slightly."
    }
}
