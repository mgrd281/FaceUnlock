import SwiftUI

/// The setup assistant.
///
/// Presented in the notch panel by default — a dark surface hanging from the
/// camera housing, with Back, page dots and Next along the bottom — and equally
/// at home in an ordinary window, where it gains a progress strip at the top.
public struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.notchPresentation) private var inNotch
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
            minWidth: inNotch ? 0 : Design.assistantSize.width,
            minHeight: inNotch ? 0 : Design.assistantSize.height
        )
        .task {
            if model == nil { model = OnboardingModel(environment: environment) }
            await environment.refreshEverything()
        }
        .onDisappear { model?.cancelWork() }
    }

    private func content(_ model: OnboardingModel) -> some View {
        VStack(spacing: 0) {
            if !inNotch {
                StepProgressBar(current: model.step)
                    .padding(.horizontal, Design.Spacing.section)
                    .padding(.top, Design.Spacing.medium)
                    .padding(.bottom, Design.Spacing.small)
            }

            ScrollView {
                VStack(spacing: Design.Spacing.large) {
                    if let error = model.error {
                        ErrorBanner(error: error) { model.error = nil }
                            .frame(maxWidth: 640)
                    }
                    stepContent(model)
                        .transition(.opacity)
                }
                .padding(.horizontal, inNotch ? Design.Spacing.large : Design.Spacing.section)
                .padding(.top, inNotch ? Design.Spacing.section : Design.Spacing.large)
                .padding(.bottom, Design.Spacing.large)
                .frame(maxWidth: .infinity)
            }
            .animation(.easeInOut(duration: 0.2), value: model.step)

            if !inNotch { Divider() }

            footer(model)
                .padding(.horizontal, inNotch ? Design.Spacing.large : Design.Spacing.section)
                .padding(.vertical, Design.Spacing.medium)
        }
        .background(inNotch ? Color.black : Color(nsColor: .windowBackgroundColor))
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
            Button("Back") { model.goBack() }
                .footerStyle(inNotch: inNotch, prominent: false)
                .disabled(model.isWorking || model.step == .welcome)
                .opacity(model.step == .welcome ? 0 : 1)
                .accessibilityHidden(model.step == .welcome)

            Spacer()
            if inNotch { StepDots(current: model.step) }
            Spacer()

            if model.step == .finished {
                Button("Done") {
                    model.finish()
                    environment.windows.close(.onboarding)
                }
                .footerStyle(inNotch: inNotch, prominent: true)
                .keyboardShortcut(.defaultAction)
            } else {
                Button(nextTitle(for: model.step)) { model.advance() }
                    .footerStyle(inNotch: inNotch, prominent: true)
                    // On the camera steps the in-content Start button owns Return.
                    .keyboardShortcut(model.isCameraStep ? nil : .defaultAction)
                    .disabled(!model.canAdvance || model.isWorking)
            }
        }
        .controlSize(.large)
    }

    private func nextTitle(for step: OnboardingModel.Step) -> String {
        switch step {
        case .password: return "Skip"
        default: return inNotch ? "Next" : "Continue"
        }
    }
}

extension OnboardingModel {
    /// Steps whose primary button is inside the content, so Next must not steal
    /// the Return key from it.
    var isCameraStep: Bool {
        step == .enrollment || step == .calibration
    }
}

/// Text-only footer buttons for the notch panel: Back in white, Next in the
/// panel's green tint, the way a first-run flow reads on a dark surface.
struct NotchFooterButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(prominent ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.white.opacity(0.85)))
            .opacity(isEnabled ? (configuration.isPressed ? 0.55 : 1) : 0.35)
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
    }
}

/// Picks the footer button style for the current presentation. `.bordered` and
/// `.borderedProminent` are primitive styles and `NotchFooterButtonStyle` is not,
/// so the choice has to be made with a modifier rather than a single value.
struct FooterButtonStyling: ViewModifier {
    let inNotch: Bool
    let prominent: Bool

    func body(content: Content) -> some View {
        if inNotch {
            content.buttonStyle(NotchFooterButtonStyle(prominent: prominent))
        } else if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

extension View {
    func footerStyle(inNotch: Bool, prominent: Bool) -> some View {
        modifier(FooterButtonStyling(inNotch: inNotch, prominent: prominent))
    }
}
