import SwiftUI

/// Runs the full recognition pipeline without ever triggering an unlock.
///
/// This is the honest way to answer "would it recognise me right now?": it uses
/// the same detector, the same descriptors, the same threshold and the same
/// liveness analysis as a real attempt, and only the final unlock step is skipped.
public struct RecognitionTestView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var result: RecognitionAttemptResult?
    @State private var isRunning = false
    @State private var runTask: Task<Void, Never>?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.large) {
            Text("Test face recognition").font(.title2.weight(.semibold))
            Text("Nothing is unlocked by this test. It runs exactly the same pipeline a real attempt uses and reports what it found.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: Design.Spacing.large) {
                LabelledCameraPreview(
                    image: environment.progress.preview?.image,
                    placeholder: isRunning ? "Starting the camera…" : "The camera is off"
                )
                .frame(width: 320)

                VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                    StatusRow(
                        symbolName: StatusPresenter.symbolName(for: environment.status),
                        tint: StatusPresenter.tint(for: environment.status),
                        title: StatusPresenter.headline(for: environment.status),
                        detail: matchesDescription
                    )

                    ConfidenceMeter(
                        value: environment.progress.matchScore,
                        threshold: environment.progress.threshold
                    )

                    if let liveness = environment.progress.livenessScore {
                        LabeledContent("Liveness") {
                            Text(String(format: "%.2f", liveness))
                                .monospacedDigit()
                        }
                    }

                    if let challenge = environment.progress.activeChallenge {
                        Label(challenge.prompt, systemImage: challenge.symbolName)
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.tint)
                            .accessibilityLiveRegion()
                    }

                    if !environment.progress.qualityIssues.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(environment.progress.qualityIssues, id: \.self) { issue in
                                Label(issue.message, systemImage: "exclamationmark.circle")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let result {
                        Card { resultSummary(result) }
                    }

                    HStack {
                        if isRunning {
                            Button("Stop") { stop() }
                        } else {
                            Button("Run test") { run() }
                                .keyboardShortcut(.defaultAction)
                                .disabled(environment.profileSummary == nil)
                        }
                    }

                    if environment.profileSummary == nil {
                        Text("Set up your face first — there is nothing to compare against yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Design.Spacing.large)
        .frame(minWidth: 720, minHeight: 480)
        .onDisappear { stop() }
    }

    private var matchesDescription: String {
        let progress = environment.progress
        guard progress.requiredMatches > 0 else { return "Idle" }
        return "\(progress.consecutiveMatches) of \(progress.requiredMatches) consecutive matching frames"
    }

    @ViewBuilder
    private func resultSummary(_ result: RecognitionAttemptResult) -> some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            switch result.verdict {
            case .recognized:
                Label("Recognised", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case let .rejected(reason):
                Label(StatusPresenter.headline(for: .rejected(reason)), systemImage: "xmark.circle")
                    .foregroundStyle(.orange)
            case let .failed(error):
                Label(error.message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            DiagnosticsRow("Best score", String(format: "%.4f", result.bestScore))
            DiagnosticsRow("Threshold", String(format: "%.4f", result.threshold))
            DiagnosticsRow("Liveness", String(format: "%.2f", result.livenessScore))
            DiagnosticsRow("Frames", "\(result.framesProcessed)")
            DiagnosticsRow("Duration", String(format: "%.2f s", result.duration))
        }
    }

    private func run() {
        guard !isRunning else { return }
        isRunning = true
        result = nil
        runTask = Task {
            let outcome = await environment.recognitionCoordinator.runAttempt(purpose: .test)
            result = outcome
            isRunning = false
            await environment.refreshEverything()
        }
    }

    private func stop() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
        Task { await environment.recognitionCoordinator.apply(.attemptFinished) }
    }
}
