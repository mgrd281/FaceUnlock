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
            StepProgressBar(current: model.step)
                .padding(.horizontal, Design.Spacing.section)
                .padding(.top, Design.Spacing.medium)
                .padding(.bottom, Design.Spacing.small)

            ScrollView {
                VStack(spacing: Design.Spacing.large) {
                    if let error = model.error {
                        ErrorBanner(error: error) { model.error = nil }
                            .frame(maxWidth: 640)
                    }
                    stepContent(model)
                        .transition(.opacity)
                }
                .padding(.horizontal, Design.Spacing.section)
                .padding(.vertical, Design.Spacing.large)
                .frame(maxWidth: .infinity)
            }
            .animation(.easeInOut(duration: 0.2), value: model.step)

            Divider()

            footer(model)
                .padding(.horizontal, Design.Spacing.section)
                .padding(.vertical, Design.Spacing.medium)
        }
        .background(.background)
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
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button(model.step == .password ? "Skip" : "Continue") { model.advance() }
                    .buttonStyle(.borderedProminent)
                    // On the camera steps the in-content Start button owns Return.
                    .keyboardShortcut(model.isCameraStep ? nil : .defaultAction)
                    .disabled(!model.canAdvance || model.isWorking)
            }
        }
        .controlSize(.large)
    }
}

extension OnboardingModel {
    /// Steps whose primary button is inside the content, so Continue must not
    /// steal the Return key from it.
    var isCameraStep: Bool {
        step == .enrollment || step == .calibration
    }
}
