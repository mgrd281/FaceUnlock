import SwiftUI

/// Guided face capture, presented as a Face ID–style scanner.
struct EnrollmentStepView: View {
    @Bindable var model: OnboardingModel
    @Environment(\.notchPresentation) private var inNotch

    private var update: EnrollmentUpdate? { model.enrollmentUpdate }
    private var accent: Color { inNotch ? .green : .accentColor }

    var body: some View {
        VStack(spacing: inNotch ? Design.Spacing.medium : Design.Spacing.large) {
            if !inNotch {
                StepHeader(
                    symbolName: "faceid",
                    title: "Set up your face",
                    subtitle: "Move your head slowly as the ring fills. Nothing is photographed — each sample becomes a mathematical descriptor and the frame is discarded."
                )
            }

            FaceScannerView(
                image: model.previewImage,
                progress: update?.progress ?? 0,
                cue: cue,
                cueProgress: currentStepProgress,
                status: scannerStatus,
                diameter: inNotch ? 190 : 220,
                accent: accent
            )

            VStack(spacing: 4) {
                Text(instruction)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                if let blocker {
                    Label(blocker, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                } else {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .frame(minHeight: 44)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)

            PoseChips(
                capturedByStep: update?.capturedByStep ?? [:],
                current: update?.currentStep,
                accent: accent
            )

            controls

            if let readout {
                // Shown only while something is blocking capture. It is the
                // difference between "it just will not work" and "the face box is
                // at 9%, so move closer" — and it carries no image or descriptor
                // data, only three percentages.
                Text(readout)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Derived presentation

    /// The quality issue standing between the user and a captured sample.
    private var blocker: String? {
        guard model.isWorking, let issue = update?.issues.first else { return nil }
        return issue.message
    }

    private var readout: String? {
        guard model.isWorking, update?.issues.isEmpty == false else { return nil }
        return update?.quality?.readout
    }

    private var instruction: String {
        guard model.isWorking || update != nil else { return "Ready when you are" }
        guard let update else { return "Starting the camera…" }
        if update.isComplete { return "All samples captured" }
        return update.currentStep.title
    }

    private var detail: String {
        guard model.isWorking || update != nil else {
            return "Sit facing the camera in even light, then start."
        }
        guard let update else { return "" }
        if update.isComplete { return "Continue to calibrate recognition." }
        if let issue = update.issues.first { return issue.message }
        return update.guidance
    }

    /// How far the pose being asked for has got, 0...1.
    private var currentStepProgress: Double? {
        guard let update, !update.isComplete, model.isWorking else { return nil }
        let step = update.currentStep
        let captured = update.capturedByStep[step] ?? 0
        return Double(captured) / Double(step.requiredSamples)
    }

    private var cue: FaceScannerView.Cue? {
        guard let update, !update.isComplete, model.isWorking else { return nil }
        switch update.currentStep {
        case .left: return .left
        case .right: return .right
        case .up: return .up
        case .down: return .down
        case .straight, .neutralExpression: return .center
        }
    }

    private var scannerStatus: FaceScannerView.Status {
        guard let update else { return model.isWorking ? .searching : .idle }
        if update.isComplete { return .success }
        if !update.issues.isEmpty { return .attention }
        return update.faceInPosition ? .aligned : .searching
    }

    @ViewBuilder
    private var controls: some View {
        if model.isWorking {
            Button("Stop") { model.cancelWork() }
                .secondaryActionStyle(inNotch: inNotch)
                .controlSize(.large)
        } else if update?.isComplete == true {
            Text("Press Continue to calibrate.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Button {
                model.startEnrollment()
            } label: {
                Label(update == nil ? "Start" : "Start again", systemImage: "camera.fill")
                    .frame(minWidth: 140)
            }
            .primaryActionStyle(inNotch: inNotch)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
    }
}

/// Calibration, on the same scanner: the ring fills as genuine samples arrive.
struct CalibrationStepView: View {
    @Bindable var model: OnboardingModel
    @Environment(\.notchPresentation) private var inNotch

    var body: some View {
        VStack(spacing: inNotch ? Design.Spacing.medium : Design.Spacing.large) {
            if !inNotch {
                StepHeader(
                    symbolName: "waveform.path.ecg",
                    title: "Calibrating",
                    subtitle: "FaceUnlock measures how consistently it recognises you and sets your personal threshold from that. Calibration can only make recognition stricter than the preset — never more permissive."
                )
            }

            FaceScannerView(
                image: model.previewImage,
                progress: model.calibrationProgress,
                cue: model.isWorking ? .center : nil,
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

            ConfidenceMeter(
                value: model.latestConfidence,
                threshold: model.savedProfile?.recognitionThreshold
            )
            .frame(maxWidth: 360)

            controls
        }
        .frame(maxWidth: .infinity)
    }

    private var headline: String {
        if let profile = model.savedProfile {
            return String(format: "Calibrated — threshold %.3f", profile.recognitionThreshold)
        }
        if model.isWorking { return "Look at the camera naturally" }
        return "Ready to calibrate"
    }

    private var detail: String {
        if model.savedProfile != nil {
            return "\(model.calibrationScores.count) samples measured. Continue when you are ready."
        }
        if model.isWorking {
            return "\(model.calibrationScores.count) of \(model.calibrationTarget) samples"
        }
        return "Small natural movements are fine — just keep looking at the screen."
    }

    private var scannerStatus: FaceScannerView.Status {
        if model.savedProfile != nil { return .success }
        if !model.isWorking { return .idle }
        guard let latest = model.latestConfidence else { return .searching }
        return latest >= SensitivityPreset.convenient.scoreFloor ? .aligned : .attention
    }

    @ViewBuilder
    private var controls: some View {
        if model.isWorking {
            Button("Stop") { model.cancelWork() }
                .secondaryActionStyle(inNotch: inNotch)
                .controlSize(.large)
        } else {
            Button {
                model.startCalibration()
            } label: {
                Label(model.savedProfile == nil ? "Start calibration" : "Calibrate again", systemImage: "waveform")
                    .frame(minWidth: 160)
            }
            .primaryActionStyle(inNotch: inNotch)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(model.draft == nil)
        }
    }
}

/// A horizontal confidence indicator with the active threshold marked.
struct ConfidenceMeter: View {
    let value: Double?
    let threshold: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.tight) {
            HStack {
                Text("Confidence").font(.caption.weight(.medium))
                Spacer()
                Text(valueDescription)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(fillColor)
                        .frame(width: geometry.size.width * CGFloat(normalized))
                    if let threshold {
                        Rectangle()
                            .fill(.primary)
                            .frame(width: 2)
                            .offset(x: geometry.size.width * CGFloat(scale(threshold)))
                            .accessibilityHidden(true)
                    }
                }
            }
            .frame(height: 8)
            .animation(.easeOut(duration: 0.2), value: value)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recognition confidence")
        .accessibilityValue(valueDescription)
    }

    /// Scores live in the upper part of the range in practice, so the meter shows
    /// 0.70–1.00 rather than 0–1, where all the useful resolution is.
    private func scale(_ score: Double) -> Double {
        min(1, max(0, (score - 0.70) / 0.30))
    }

    private var normalized: Double { value.map(scale) ?? 0 }

    private var fillColor: Color {
        guard let value, let threshold else { return .accentColor }
        return value >= threshold ? .green : .orange
    }

    private var valueDescription: String {
        guard let value else { return "—" }
        return String(format: "%.3f", value)
    }
}

extension View {
    /// Marks a view as an announcement region for VoiceOver.
    func accessibilityLiveRegion() -> some View {
        accessibilityAddTraits(.updatesFrequently)
    }
}
