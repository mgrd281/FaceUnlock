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
    /// True when a single, acceptable-quality face was in frame for this update.
    public var faceInPosition: Bool = false
    /// What the quality gate measured, when it had a face to measure.
    public var quality: FaceQuality?
    /// For a directional step, how far the head has leaned towards what the step
    /// needs, 0...1. Fills the cue arc so the user can *see* the turn register.
    public var leanProgress: Double?

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
        defer { Task { await self.camera.stop() } }

        var embeddings: [FaceEmbedding] = []
        var poseTags: [EnrollmentPose] = []
        var captured: [EnrollmentPose: Int] = [:]
        var stepIndex = 0
        var directions = DirectionCalibration()
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
                        isComplete: false,
                        quality: evaluation.measured
                    )
                )
                continue
            }

            guard directions.matches(step: step, pose: measured.pose) else {
                emit(
                    EnrollmentUpdate(
                        currentStep: step,
                        capturedByStep: captured,
                        issues: [],
                        guidance: Self.guidance(
                            for: step,
                            progress: directions.leanProgress(step: step, pose: measured.pose),
                            wrongWay: directions.isLeaningWrongWay(step: step, pose: measured.pose)
                        ),
                        preview: preview,
                        isComplete: false,
                        faceInPosition: true,
                        quality: measured,
                        leanProgress: directions.leanProgress(step: step, pose: measured.pose)
                    )
                )
                continue
            }
            directions.record(step: step, pose: measured.pose)

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
            // Only a near-identical frame is a duplicate. The feature print is a
            // robust descriptor, so at 0.995 two consecutive frames of a still
            // face were often refused, which showed up as the step stalling on
            // "hold that position".
            let isDuplicate = currentStepEmbeddings.contains { existing in
                SimilarityMetric.cosine.score(existing, embedding) > 0.999
            }
            if isDuplicate {
                emit(
                    EnrollmentUpdate(
                        currentStep: step,
                        capturedByStep: captured,
                        issues: [],
                        guidance: "Hold that position — moving very slightly helps.",
                        preview: preview,
                        isComplete: false,
                        faceInPosition: true,
                        quality: measured
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
                    isComplete: stepIndex >= steps.count,
                    faceInPosition: true,
                    quality: measured
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
        defer { Task { await self.camera.stop() } }

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

    /// Learns the user's own straight-ahead pose, then which way they lean for the
    /// first pose of each opposed pair, and requires the opposite lean for its
    /// partner.
    ///
    /// Everything is measured *relative to the person's own baseline* — the pose
    /// recorded while they looked straight ahead — because the landmark estimate
    /// is a proxy whose zero point differs from face to face. The security-
    /// relevant property, that "left" and "right" capture two genuinely different
    /// profiles, holds without asserting any global sign convention.
    private struct DirectionCalibration {
        private var baseline: FacePose?
        private var baselineSamples = 0
        private var yawSign: Double?
        private var pitchSign: Double?

        func matches(step: EnrollmentPose, pose: FacePose) -> Bool {
            switch step.axis {
            case .none:
                guard let baseline else {
                    // The straight-ahead step *defines* the baseline, so it cannot
                    // be judged against one. The nose sitting centred between the
                    // eyes is the one absolute check the estimator makes reliably
                    // for any face; the quality gate already bounds everything else.
                    return abs(pose.yaw) <= step.centredYawTolerance
                }
                return abs(pose.yaw - baseline.yaw) <= step.centredTolerance
                    && abs(pose.pitch - baseline.pitch) <= step.centredTolerance
            case .yaw:
                return leans(value: delta(step: step, pose: pose), step: step, recorded: yawSign)
            case .pitch:
                return leans(value: delta(step: step, pose: pose), step: step, recorded: pitchSign)
            }
        }

        /// 0 when the head has not moved from the baseline, 1 at the required lean.
        func leanProgress(step: EnrollmentPose, pose: FacePose) -> Double {
            guard step.axis != .none, step.minimumLean > 0 else { return 0 }
            let value = delta(step: step, pose: pose)
            let sign: Double = value < 0 ? -1 : 1
            let recorded = step.axis == .yaw ? yawSign : pitchSign
            // Leaning the wrong way for the second of a pair counts as no progress.
            if let recorded, (step.isOpposite ? sign == recorded : sign != recorded) { return 0 }
            return min(1, abs(value) / step.minimumLean)
        }

        /// True when the head has clearly leaned, but the way its partner pose
        /// already used.
        func isLeaningWrongWay(step: EnrollmentPose, pose: FacePose) -> Bool {
            guard step.axis != .none else { return false }
            let value = delta(step: step, pose: pose)
            guard abs(value) >= step.minimumLean * 0.5 else { return false }
            let sign: Double = value < 0 ? -1 : 1
            let recorded = step.axis == .yaw ? yawSign : pitchSign
            guard let recorded else { return false }
            return step.isOpposite ? sign == recorded : sign != recorded
        }

        mutating func record(step: EnrollmentPose, pose: FacePose) {
            switch step.axis {
            case .none:
                // Average every straight-ahead sample into the baseline, so a
                // single slightly-off frame does not become the reference for
                // the whole enrolment.
                guard step == .straight else { return }
                if let current = baseline {
                    let n = Double(baselineSamples)
                    baseline = FacePose(
                        yaw: (current.yaw * n + pose.yaw) / (n + 1),
                        pitch: (current.pitch * n + pose.pitch) / (n + 1),
                        roll: (current.roll * n + pose.roll) / (n + 1)
                    )
                } else {
                    baseline = pose
                }
                baselineSamples += 1
            case .yaw:
                if yawSign == nil, !step.isOpposite {
                    yawSign = delta(step: step, pose: pose) < 0 ? -1 : 1
                }
            case .pitch:
                if pitchSign == nil, !step.isOpposite {
                    pitchSign = delta(step: step, pose: pose) < 0 ? -1 : 1
                }
            }
        }

        private func delta(step: EnrollmentPose, pose: FacePose) -> Double {
            let reference = baseline ?? FacePose()
            switch step.axis {
            case .yaw: return pose.yaw - reference.yaw
            case .pitch: return pose.pitch - reference.pitch
            case .none: return 0
            }
        }

        private func leans(value: Double, step: EnrollmentPose, recorded: Double?) -> Bool {
            guard abs(value) >= step.minimumLean else { return false }
            let sign: Double = value < 0 ? -1 : 1
            guard let recorded else { return true }
            return step.isOpposite ? sign != recorded : sign == recorded
        }
    }

    /// Magnitude-only guidance. The step's title already names the direction, and
    /// naming one here again would be a guess about which way the axis points.
    private static func guidance(for step: EnrollmentPose, progress: Double, wrongWay: Bool) -> String {
        switch step.axis {
        case .none:
            return "Centre your face in the circle and hold still."
        case .yaw, .pitch:
            if wrongWay { return "That is the other direction — turn the opposite way." }
            if progress < 0.4 { return "Keep going — a bit further." }
            if progress < 1 { return "Almost there." }
            return "Hold it right there."
        }
    }
}
