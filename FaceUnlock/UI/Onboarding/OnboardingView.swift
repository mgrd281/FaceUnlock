import SwiftUI

/// The setup assistant window.
public struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var model: OnboardingModel?

    public init() {}

    public var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(
            minWidth: Design.assistantSize.width,
            minHeight: Design.assistantSize.height
        )
        .task {
            if model == nil { model = OnboardingModel(environment: environment) }
            await environment.refreshEverything()
        }
        .onDisappear { model?.cancelWork() }
    }

    private func content(_ model: OnboardingModel) -> some View {
        VStack(spacing: 0) {
            StepIndicator(current: model.step)
                .padding(.horizontal, Design.Spacing.large)
                .padding(.vertical, Design.Spacing.medium)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Design.Spacing.large) {
                    if let error = model.error {
                        ErrorBanner(error: error) { model.error = nil }
                    }
                    stepContent(model)
                }
                .padding(Design.Spacing.large)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            footer(model)
                .padding(Design.Spacing.medium)
        }
    }

    @ViewBuilder
    private func stepContent(_ model: OnboardingModel) -> some View {
        switch model.step {
        case .welcome:
            WelcomeStepView()
        case .compatibility:
            CompatibilityStepView(report: model.compatibility)
        case .cameraPermission:
            CameraPermissionStepView(state: model.cameraPermission) {
                model.requestCameraAccess()
            }
        case .accessibility:
            AccessibilityStepView(state: model.accessibilityPermission) {
                model.promptForAccessibility()
            }
        case .enrollment:
            EnrollmentStepView(model: model)
        case .calibration:
            CalibrationStepView(model: model)
        case .password:
            PasswordStepView(environment: environment)
        case .finished:
            FinishedStepView(environment: environment)
        }
    }

    private func footer(_ model: OnboardingModel) -> some View {
        HStack {
            if model.step != .welcome {
                Button("Back") { model.goBack() }
                    .disabled(model.isWorking)
            }
            Spacer()
            if model.step == .finished {
                Button("Done") {
                    model.finish()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button(model.step == .password ? "Skip" : "Continue") { model.advance() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canAdvance || model.isWorking)
            }
        }
    }
}

/// The horizontal step indicator at the top of the assistant.
struct StepIndicator: View {
    let current: OnboardingModel.Step

    var body: some View {
        HStack(spacing: Design.Spacing.small) {
            ForEach(OnboardingModel.Step.allCases) { step in
                let isDone = step.rawValue < current.rawValue
                let isCurrent = step == current
                HStack(spacing: Design.Spacing.tight) {
                    Circle()
                        .fill(isDone ? Color.accentColor : (isCurrent ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.25)))
                        .frame(width: 8, height: 8)
                    Text(step.title)
                        .font(.caption)
                        .foregroundStyle(isCurrent ? .primary : .secondary)
                }
                if step != OnboardingModel.Step.allCases.last {
                    Rectangle()
                        .fill(.separator)
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Setup step \(current.rawValue + 1) of \(OnboardingModel.Step.allCases.count): \(current.title)")
    }
}
