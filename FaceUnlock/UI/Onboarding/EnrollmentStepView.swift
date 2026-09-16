import SwiftUI

struct EnrollmentStepView: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            Text("Record your face").font(.title2.weight(.semibold))
            Text("FaceUnlock captures a handful of samples from several angles so it can still recognise you when you are not perfectly square to the camera. No photographs are saved — each sample becomes a mathematical descriptor and the frame is discarded.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: Design.Spacing.large) {
                VStack(spacing: Design.Spacing.small) {
                    LabelledCameraPreview(image: model.previewImage)
                        .frame(width: 320)
                    if let update = model.enrollmentUpdate {
                        Text(update.guidance)
                            .font(.callout.weight(.medium))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 320)
                            .accessibilityLiveRegion()
                    }
                }

                VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                    ForEach(EnrollmentPose.allCases) { pose in
                        let captured = model.enrollmentUpdate?.capturedByStep[pose] ?? 0
                        let isCurrent = model.enrollmentUpdate?.currentStep == pose
                        StatusRow(
                            symbolName: captured >= pose.requiredSamples
                                ? "checkmark.circle.fill"
                                : pose.symbolName,
                            tint: captured >= pose.requiredSamples ? .green : (isCurrent ? .accentColor : .secondary),
                            title: pose.title,
                            detail: "\(min(captured, pose.requiredSamples)) of \(pose.requiredSamples) captured"
                        )
                    }

                    if let update = model.enrollmentUpdate {
                        ProgressView(value: update.progress)
                            .accessibilityLabel("Enrolment progress")
                            .accessibilityValue("\(Int(update.progress * 100)) percent")
                    }

                    if model.isWorking {
                        Button("Stop") { model.cancelWork() }
                    } else {
                        Button("Start capturing") { model.startEnrollment() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct CalibrationStepView: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            Text("Calibration").font(.title2.weight(.semibold))
            Text("FaceUnlock now measures how consistently it recognises you, and sets your personal threshold from that. Calibration can only make recognition stricter than the preset you chose — never more permissive.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: Design.Spacing.large) {
                LabelledCameraPreview(image: model.previewImage)
                    .frame(width: 320)

                VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                    ConfidenceMeter(
                        value: model.latestConfidence,
                        threshold: model.savedProfile?.recognitionThreshold
                    )

                    ProgressView(value: model.calibrationProgress) {
                        Text("Samples collected")
                    }
                    .accessibilityValue("\(model.calibrationScores.count) of \(model.calibrationTarget)")

                    if let profile = model.savedProfile {
                        Card {
                            VStack(alignment: .leading, spacing: Design.Spacing.small) {
                                StatusRow(
                                    symbolName: "checkmark.seal",
                                    tint: .green,
                                    title: "Calibrated",
                                    detail: String(
                                        format: "Threshold %.3f from %d samples",
                                        profile.recognitionThreshold,
                                        model.calibrationScores.count
                                    )
                                )
                            }
                        }
                    }

                    if model.isWorking {
                        Button("Stop") { model.cancelWork() }
                    } else {
                        Button(model.savedProfile == nil ? "Start calibration" : "Calibrate again") {
                            model.startCalibration()
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.draft == nil)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// A horizontal confidence indicator with the active threshold marked.
struct ConfidenceMeter: View {
    let value: Double?
    let threshold: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.tight) {
            Text("Confidence").font(.callout.weight(.medium))
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
            .frame(height: 10)
            Text(valueDescription).font(.caption).foregroundStyle(.secondary)
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
        guard let value else { return "Waiting for a clear view of your face" }
        return String(format: "%.3f", value)
    }
}

extension View {
    /// Marks a view as an announcement region for VoiceOver.
    func accessibilityLiveRegion() -> some View {
        accessibilityAddTraits(.updatesFrequently)
    }
}
