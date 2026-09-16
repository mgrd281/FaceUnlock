import SwiftUI

/// The hero header every assistant step shares: a large hierarchical symbol, a
/// rounded title and a one-paragraph subtitle, centred.
struct StepHeader: View {
    let symbolName: String
    let title: String
    let subtitle: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(spacing: Design.Spacing.small) {
            Image(systemName: symbolName)
                .font(.system(size: 36, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(.title, design: .rounded, weight: .semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
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
