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
    @Environment(\.notchPresentation) private var inNotch

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(spacing: inNotch ? Design.Spacing.medium : Design.Spacing.large) {
                StepHeader(
                    symbolName: "viewfinder",
                    title: "Test face recognition",
                    subtitle: "Nothing is unlocked by this test. It runs the same pipeline a real attempt uses and reports what it found."
                )

                FaceScannerView(
                    image: environment.progress.preview?.image,
                    progress: matchProgress,
                    cue: cue,
                    cueProgress: environment.progress.activeChallenge == nil ? nil : matchProgress,
                    status: scannerStatus,
                    diameter: inNotch ? 190 : 220,
                    accent: inNotch ? .green : .accentColor
                )

                VStack(spacing: 4) {
                    Text(headline)
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .frame(minHeight: 48)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)

                metrics
                    .frame(maxWidth: 420)

                if let result {
                    Card { resultSummary(result) }
                        .frame(maxWidth: 420)
                }

                controls
            }
            .padding(inNotch ? Design.Spacing.large : Design.Spacing.section)
            .frame(maxWidth: .infinity)
            .reportsNotchHeight()
        }
        .frame(minWidth: inNotch ? 0 : 720, minHeight: inNotch ? 0 : 700)
        .onDisappear { stop() }
    }

    // MARK: - Derived presentation

    private var matchProgress: Double {
        let progress = environment.progress
        guard progress.requiredMatches > 0 else { return 0 }
        return Double(progress.consecutiveMatches) / Double(progress.requiredMatches)
    }

    private var cue: FaceScannerView.Cue? {
        guard isRunning, let challenge = environment.progress.activeChallenge else {
            return isRunning ? .center : nil
        }
        switch challenge {
        case .turnLeft: return .left
        case .turnRight: return .right
        case .blink: return .center
        }
    }

    private var scannerStatus: FaceScannerView.Status {
        guard isRunning || result != nil else { return .idle }
        if let result {
            return result.succeeded ? .success : .failure
        }
        switch environment.status {
        case .recognized, .unlocked: return .success
        case .rejected, .error: return .failure
        case .faceDetected, .recognizing: return environment.progress.qualityIssues.isEmpty ? .aligned : .attention
        default: return .searching
        }
    }

    private var headline: String {
        if let challenge = environment.progress.activeChallenge, isRunning {
            return challenge.prompt
        }
        if let result {
            switch result.verdict {
            case .recognized: return "Recognised"
            case let .rejected(reason): return StatusPresenter.headline(for: .rejected(reason))
            case let .failed(error): return error.message
            }
        }
        if isRunning { return StatusPresenter.headline(for: environment.status) }
        return environment.profileSummary == nil ? "Set up your face first" : "Ready to test"
    }

    private var detail: String {
        if isRunning, let issue = environment.progress.qualityIssues.first {
            return issue.message
        }
        let progress = environment.progress
        if isRunning, progress.requiredMatches > 0 {
            return "\(progress.consecutiveMatches) of \(progress.requiredMatches) consecutive matching frames"
        }
        if result != nil { return "Run again to try different lighting or angles." }
        return environment.profileSummary == nil
            ? "There is nothing to compare against yet."
            : "Look at the camera as you normally would."
    }

    private var metrics: some View {
        VStack(spacing: Design.Spacing.small) {
            ConfidenceMeter(
                value: environment.progress.matchScore,
                threshold: environment.progress.threshold
            )
            if let liveness = environment.progress.livenessScore {
                HStack {
                    Text("Liveness").font(.caption.weight(.medium))
                    Spacer()
                    Text(String(format: "%.2f", liveness))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func resultSummary(_ result: RecognitionAttemptResult) -> some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            DiagnosticsRow("Best score", String(format: "%.4f", result.bestScore))
            DiagnosticsRow("Threshold", String(format: "%.4f", result.threshold))
            DiagnosticsRow("Liveness", String(format: "%.2f", result.livenessScore))
            DiagnosticsRow("Frames", "\(result.framesProcessed)")
            DiagnosticsRow("Duration", String(format: "%.2f s", result.duration))
        }
    }

    @ViewBuilder
    private var controls: some View {
        if isRunning {
            Button("Stop") { stop() }
                .controlSize(.large)
        } else {
            Button {
                run()
            } label: {
                Label(result == nil ? "Run test" : "Run again", systemImage: "play.fill")
                    .frame(minWidth: 140)
            }
            .primaryActionStyle(inNotch: inNotch)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(environment.profileSummary == nil)
        }
    }

    // MARK: - Actions

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
