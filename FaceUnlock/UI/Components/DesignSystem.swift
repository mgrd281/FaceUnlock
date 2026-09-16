import SwiftUI

/// Shared spacing, corner radii and typography.
///
/// Values follow macOS conventions rather than inventing a new visual language:
/// 8-point rhythm, system materials for surfaces, and semantic colours throughout
/// so Dark Mode, Increase Contrast and Reduce Transparency all work without any
/// per-view handling.
public enum Design {
    public enum Spacing {
        public static let tight: CGFloat = 4
        public static let small: CGFloat = 8
        public static let medium: CGFloat = 14
        public static let large: CGFloat = 22
        public static let section: CGFloat = 28
    }

    public enum Radius {
        public static let control: CGFloat = 7
        public static let card: CGFloat = 12
        public static let window: CGFloat = 16
    }

    public static let menuWidth: CGFloat = 320
    public static let assistantSize = CGSize(width: 820, height: 600)
}

/// A grouped surface used throughout Settings and the assistant.
public struct Card<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(Design.Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Design.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: Design.Radius.card)
                    .strokeBorder(.separator, lineWidth: 0.5)
            )
    }
}

/// A labelled row with a leading symbol, used for permission and status lists.
public struct StatusRow: View {
    private let symbolName: String
    private let tint: Color
    private let title: String
    private let detail: String
    private let accessory: AnyView?

    public init(symbolName: String, tint: Color, title: String, detail: String) {
        self.symbolName = symbolName
        self.tint = tint
        self.title = title
        self.detail = detail
        self.accessory = nil
    }

    public init<Accessory: View>(
        symbolName: String,
        tint: Color,
        title: String,
        detail: String,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.symbolName = symbolName
        self.tint = tint
        self.title = title
        self.detail = detail
        self.accessory = AnyView(accessory())
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.medium) {
            Image(systemName: symbolName)
                .foregroundStyle(tint)
                .font(.body.weight(.medium))
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Design.Spacing.small)
            accessory
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
    }
}

extension CompatibilityCheck.Level {
    public var tint: Color {
        switch self {
        case .supported: return .green
        case .attention: return .orange
        case .unsupported: return .red
        }
    }
}

extension PermissionState {
    public var tint: Color {
        switch self {
        case .granted: return .green
        case .notDetermined: return .orange
        case .denied, .restricted: return .red
        }
    }

    public var symbolName: String {
        switch self {
        case .granted: return "checkmark.circle.fill"
        case .notDetermined: return "questionmark.circle.fill"
        case .denied, .restricted: return "xmark.octagon.fill"
        }
    }
}

/// A dismissible inline banner for recoverable errors. Used instead of modal
/// alerts so a failed attempt never steals focus from what the user is doing.
public struct ErrorBanner: View {
    private let error: FaceUnlockError
    private let onDismiss: () -> Void

    public init(error: FaceUnlockError, onDismiss: @escaping () -> Void) {
        self.error = error
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Design.Spacing.small) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(error.message).font(.callout.weight(.medium))
                if let suggestion = error.recoverySuggestion {
                    Text(suggestion).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Design.Spacing.small)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss this message")
        }
        .padding(Design.Spacing.small)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: Design.Radius.control))
        .accessibilityElement(children: .contain)
    }
}
