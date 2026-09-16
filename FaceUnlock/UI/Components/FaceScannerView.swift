import SwiftUI

/// A Face ID–style circular scanner.
///
/// The live preview is masked to a circle, a ring of tick marks around it fills
/// clockwise from twelve o'clock as progress is made, and a glowing cue on the
/// ring's edge shows which way the user should turn. Every colour is semantic so
/// Dark Mode and Increase Contrast work without special handling, and the pulse
/// is disabled under Reduce Motion.
public struct FaceScannerView: View {
    /// Which edge of the ring to highlight.
    public enum Cue: Equatable, Sendable {
        case left, right, up, down
        /// Highlight the whole outline rather than one edge.
        case center

        /// Angle in degrees, measured clockwise from three o'clock — the same
        /// convention SwiftUI's `Circle().trim` uses.
        var angle: Double {
            switch self {
            case .right: return 0
            case .down: return 90
            case .left: return 180
            case .up: return 270
            case .center: return 0
            }
        }

        var symbolName: String {
            switch self {
            case .left: return "chevron.left"
            case .right: return "chevron.right"
            case .up: return "chevron.up"
            case .down: return "chevron.down"
            case .center: return "viewfinder"
            }
        }
    }

    public enum Status: Equatable, Sendable {
        case idle
        case searching
        case aligned
        case attention
        case success
        case failure
    }

    private let image: CGImage?
    private let progress: Double
    private let cue: Cue?
    private let status: Status
    private let diameter: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private let tickCount = 60
    private var ringRadius: CGFloat { diameter / 2 + 24 }
    private var outerSize: CGFloat { diameter + 120 }

    public init(
        image: CGImage?,
        progress: Double,
        cue: Cue?,
        status: Status,
        diameter: CGFloat = 220
    ) {
        self.image = image
        self.progress = min(1, max(0, progress))
        self.cue = cue
        self.status = status
        self.diameter = diameter
    }

    public var body: some View {
        ZStack {
            halo
            ticks
            cueOverlay
            preview
        }
        .frame(width: outerSize, height: outerSize)
        .animation(.easeInOut(duration: 0.3), value: progress)
        .animation(.easeInOut(duration: 0.25), value: status)
        .onAppear { pulse = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Face scanner")
        .accessibilityValue(accessibilityDescription)
    }

    // MARK: - Layers

    private var halo: some View {
        Circle()
            .fill(statusColor.opacity(status == .idle ? 0.04 : 0.12))
            .frame(width: diameter + 96, height: diameter + 96)
            .blur(radius: 28)
    }

    private var ticks: some View {
        ForEach(0..<tickCount, id: \.self) { index in
            let threshold = Double(index) / Double(tickCount)
            let isFilled = progress > threshold + 0.0001
            Capsule()
                .fill(isFilled ? Color.green : Color.secondary.opacity(0.22))
                .frame(width: 3, height: 14)
                .offset(y: -ringRadius)
                .rotationEffect(.degrees(threshold * 360))
        }
    }

    @ViewBuilder
    private var cueOverlay: some View {
        if let cue, cue != .center {
            // A short glowing arc centred on the target edge. `trim` starts at three
            // o'clock, so the rotation places the arc's midpoint at `cue.angle`.
            Circle()
                .trim(from: 0, to: 0.14)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .frame(width: ringRadius * 2, height: ringRadius * 2)
                .rotationEffect(.degrees(cue.angle - 0.07 * 360))
                .blur(radius: 2)
                .opacity(pulseOpacity)
                .animation(pulseAnimation, value: pulse)

            Image(systemName: cue.symbolName)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .offset(
                    x: cos(cue.angle * .pi / 180) * (ringRadius + 34),
                    y: sin(cue.angle * .pi / 180) * (ringRadius + 34)
                )
                .opacity(pulseOpacity)
                .animation(pulseAnimation, value: pulse)
        } else if cue == .center {
            Circle()
                .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 2)
                .frame(width: diameter + 14, height: diameter + 14)
                .opacity(pulseOpacity)
                .animation(pulseAnimation, value: pulse)
        }
    }

    private var preview: some View {
        ZStack {
            CameraPreview(image: image, cornerRadius: 0)
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())

            if image == nil {
                Circle()
                    .fill(.quaternary)
                    .frame(width: diameter, height: diameter)
                ProgressView()
                    .controlSize(.large)
            }

            Circle()
                .strokeBorder(statusColor, lineWidth: 3)
                .frame(width: diameter, height: diameter)

            if status == .success {
                Image(systemName: "checkmark")
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(radius: 6)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    // MARK: - Styling

    private var statusColor: Color {
        switch status {
        case .idle: return .secondary
        case .searching: return .accentColor
        case .aligned, .success: return .green
        case .attention, .failure: return .orange
        }
    }

    private var pulseOpacity: Double {
        if reduceMotion { return 0.9 }
        return pulse ? 1 : 0.35
    }

    private var pulseAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
    }

    private var accessibilityDescription: String {
        let percent = Int(progress * 100)
        switch status {
        case .idle: return "Camera off"
        case .searching: return "Looking for a face, \(percent) percent complete"
        case .aligned: return "Face in position, \(percent) percent complete"
        case .attention: return "Adjust your position, \(percent) percent complete"
        case .success: return "Complete"
        case .failure: return "Not recognised"
        }
    }
}

/// A row of compact chips, one per enrolment pose, showing which are done.
struct PoseChips: View {
    let capturedByStep: [EnrollmentPose: Int]
    let current: EnrollmentPose?

    var body: some View {
        HStack(spacing: Design.Spacing.small) {
            ForEach(EnrollmentPose.allCases) { pose in
                let captured = capturedByStep[pose] ?? 0
                let isDone = captured >= pose.requiredSamples
                let isCurrent = pose == current && !isDone
                HStack(spacing: 5) {
                    Image(systemName: isDone ? "checkmark.circle.fill" : pose.symbolName)
                        .font(.caption.weight(.semibold))
                    Text(pose.shortTitle)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .foregroundStyle(isDone ? Color.green : (isCurrent ? Color.accentColor : Color.secondary))
                .background(
                    Capsule().fill(
                        isDone ? Color.green.opacity(0.12)
                            : (isCurrent ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.10))
                    )
                )
                .overlay(
                    Capsule().strokeBorder(isCurrent ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1)
                )
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(pose.title): \(min(captured, pose.requiredSamples)) of \(pose.requiredSamples)")
            }
        }
    }
}
