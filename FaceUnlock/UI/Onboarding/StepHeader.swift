import SwiftUI

/// The hero header every assistant step shares: a large hierarchical symbol, a
/// rounded title and a one-paragraph subtitle, centred.
struct StepHeader: View {
    let symbolName: String
    let title: String
    let subtitle: String
    var tint: Color = .accentColor

    @Environment(\.notchPresentation) private var inNotch

    var body: some View {
        VStack(spacing: inNotch ? 6 : Design.Spacing.small) {
            Image(systemName: symbolName)
                .font(.system(size: inNotch ? 28 : 36, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(inNotch ? Color.green : tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(inNotch ? .title2 : .title, design: .rounded, weight: .semibold))
            Text(subtitle)
                .font(inNotch ? .subheadline : .callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// The page dots in the notch panel's footer.
struct StepDots: View {
    let current: OnboardingModel.Step

    var body: some View {
        HStack(spacing: 7) {
            ForEach(OnboardingModel.Step.allCases) { step in
                Circle()
                    .fill(step == current ? Color.green : Color.white.opacity(0.28))
                    .frame(width: step == current ? 7 : 6, height: step == current ? 7 : 6)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Setup step \(current.rawValue + 1) of \(OnboardingModel.Step.allCases.count): \(current.title)"
        )
    }
}

/// The compact progress strip at the top of the assistant.
struct StepProgressBar: View {
    let current: OnboardingModel.Step

    private var total: Int { OnboardingModel.Step.allCases.count }
    private var fraction: Double { Double(current.rawValue + 1) / Double(total) }

    var body: some View {
        VStack(spacing: Design.Spacing.small) {
            HStack {
                Text("Step \(current.rawValue + 1) of \(total)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(current.title)
                    .font(.caption.weight(.semibold))
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: 4)
            .animation(.easeInOut(duration: 0.3), value: current)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Setup step \(current.rawValue + 1) of \(total): \(current.title)")
    }
}
