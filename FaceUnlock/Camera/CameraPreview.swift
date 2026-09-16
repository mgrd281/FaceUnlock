import AppKit
import SwiftUI

/// Draws preview frames in a layer-backed view.
///
/// A plain `Image(decorative:)` would re-create a SwiftUI image every frame;
/// assigning to `CALayer.contents` instead hands the `CGImage` straight to the
/// compositor, which keeps a 15 fps preview essentially free.
public struct CameraPreview: NSViewRepresentable {
    private let image: CGImage?
    private let cornerRadius: CGFloat

    public init(image: CGImage?, cornerRadius: CGFloat = Design.Radius.card) {
        self.image = image
        self.cornerRadius = cornerRadius
    }

    public func makeNSView(context: Context) -> PreviewLayerView {
        let view = PreviewLayerView()
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
        view.layer?.contentsGravity = .resizeAspectFill
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        return view
    }

    public func updateNSView(_ nsView: PreviewLayerView, context: Context) {
        nsView.layer?.cornerRadius = cornerRadius
        nsView.layer?.contents = image
    }
}

/// Layer-backed container for the preview. Exposed so the representable can name
/// its view type without resorting to `NSView` and casts.
public final class PreviewLayerView: NSView {
    public override var isFlipped: Bool { true }
    public override func makeBackingLayer() -> CALayer { CALayer() }
}

/// The preview plus an accessibility description, used everywhere a live camera
/// view is shown.
public struct LabelledCameraPreview: View {
    private let image: CGImage?
    private let placeholder: String

    public init(image: CGImage?, placeholder: String = "Starting the camera…") {
        self.image = image
        self.placeholder = placeholder
    }

    public var body: some View {
        ZStack {
            CameraPreview(image: image)
            if image == nil {
                VStack(spacing: Design.Spacing.small) {
                    ProgressView()
                    Text(placeholder).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Live camera preview")
        .accessibilityValue(image == nil ? placeholder : "Showing the camera")
    }
}
