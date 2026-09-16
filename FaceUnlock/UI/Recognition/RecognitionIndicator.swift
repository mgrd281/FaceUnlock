import SwiftUI

/// The optional recognition animation.
///
/// Restraint is the point: a slow scanning sweep while searching, a single
/// checkmark on success, a brief neutral fade on rejection. It respects Reduce
/// Motion — with that setting on, the sweep is replaced by a static indicator —
/// and it disappears entirely when the user turns the animation off.
public struct RecognitionIndicator: View {
    private let status: AppStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    public init(status: AppStatus) {
        self.status = status
    }

    public var body: some View {
        ZStack {
            Circle()
                .strokeBorder(.quaternary, lineWidth: 2)
            switch status {
            case .monitoring, .faceDetected, .recognizing:
                searching
            case .recognized, .unlocked:
                Image(systemName: "checkmark")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.green)
                    .transition(.opacity)
            case .rejected, .error:
                Image(systemName: "minus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            default:
                Image(systemName: StatusPresenter.symbolName(for: status))
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 56, height: 56)
        .animation(.easeInOut(duration: 0.25), value: status)
        .accessibilityElement()
        .accessibilityLabel(StatusPresenter.accessibilityDescription(for: status))
    }

    @ViewBuilder
    private var searching: some View {
        if reduceMotion {
            Image(systemName: "viewfinder")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.tint)
        } else {
            Circle()
                .trim(from: 0, to: 0.22)
                .stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(sweep ? 360 : 0))
                .animation(.linear(duration: 1.6).repeatForever(autoreverses: false), value: sweep)
                .onAppear { sweep = true }
                .onDisappear { sweep = false }
        }
    }
}

/// A floating panel shown near the menu bar during an unlock attempt.
public struct RecognitionOverlayView: View {
    @Environment(AppEnvironment.self) private var environment

    public init() {}

    public var body: some View {
        HStack(spacing: Design.Spacing.medium) {
            RecognitionIndicator(status: environment.status)
            VStack(alignment: .leading, spacing: 2) {
                Text("FaceUnlock").font(.headline)
                Text(StatusPresenter.headline(for: environment.status))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let challenge = environment.progress.activeChallenge {
                    Label(challenge.prompt, systemImage: challenge.symbolName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.tint)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Design.Spacing.medium)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Design.Radius.window))
    }
}
