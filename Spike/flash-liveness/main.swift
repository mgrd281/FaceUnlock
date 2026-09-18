//
//  flash-probe — does an active screen flash separate a face from a screen?
//
//  The physics under test: a face is a rounded, matte, three-dimensional
//  surface, so a flash reaching it falls off across the face — the nose and
//  forehead brighten more than the cheeks and the edges, following the surface
//  normal and the inverse square. A phone is flat and glossy: it either
//  brightens almost uniformly, or throws one specular hotspot that sits wherever
//  the geometry puts it. Those are different *spatial* signatures, not different
//  brightnesses, which matters because overall brightness is the one thing an
//  attacker can trivially match.
//
//  This measures that difference and prints it. It does not unlock anything and
//  installs nothing. It flashes a white window, which is why it runs unlocked —
//  the lock screen admits no window of ours, and that delivery problem is
//  deliberately separated from the question of whether the signal exists at all.
//
//  Usage:  ./flash-probe <label> [seconds]
//

import AVFoundation
import AppKit
import CoreImage
import QuartzCore

let label = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "sample"
let duration = CommandLine.arguments.count > 2 ? (Double(CommandLine.arguments[2]) ?? 12) : 12

// MARK: - Flash window

/// A plain white window at screen-saver level, toggled between black and white.
/// Nothing is drawn over a lock screen; this is for the unlocked measurement.
final class FlashWindow {
    private let window: NSWindow

    init() {
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = true
        window.ignoresMouseEvents = true
        // A layer-backed content view rather than the window's backgroundColor:
        // a borderless window with no content view does not reliably composite a
        // colour change, which showed up as a flash the camera could not see
        // (peak gain 0.001, indistinguishable from noise).
        let view = NSView(frame: frame)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = view
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func set(bright: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        window.contentView?.layer?.backgroundColor =
            (bright ? NSColor.white : NSColor.black).cgColor
        CATransaction.commit()
        window.displayIfNeeded()
    }

    func close() { window.orderOut(nil) }
}

// MARK: - Measurement

/// A face crop reduced to a coarse luminance grid.
struct Grid {
    let size: Int
    let values: [Double]

    init?(_ buffer: CVPixelBuffer, size: Int = 32) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)

        // Centre square of the frame: where a face being presented to a laptop
        // camera sits, whether it is a real one or one held up on a phone.
        let side = min(width, height)
        let originX = (width - side) / 2
        let originY = (height - side) / 2

        var out = [Double](repeating: 0, count: size * size)
        for gy in 0..<size {
            for gx in 0..<size {
                let px = originX + gx * side / size
                let py = originY + gy * side / size
                let offset = py * stride + px * 4
                // BGRA; a plain average is enough for a relative comparison.
                let b = Double(pixels[offset])
                let g = Double(pixels[offset + 1])
                let r = Double(pixels[offset + 2])
                out[gy * size + gx] = (r + g + b) / (3 * 255)
            }
        }
        self.size = size
        self.values = out
    }
}

func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }

/// The discriminating measure.
///
/// Take the per-pixel brightness increase caused by the flash, normalise it by
/// its own mean so that overall gain drops out, and report how much *structure*
/// is left. A flat surface gains uniformly: once normalised, the map is
/// featureless. A face gains unevenly in a way that follows its shape, so the
/// normalised map retains contrast — and, specifically, the centre gains more
/// than the edges.
struct FlashSignature {
    let gainCentre: Double
    let gainEdge: Double
    /// Centre-versus-edge gain ratio. A sphere-like surface exceeds 1; a plane
    /// sits at about 1; a specular hotspot can go either way but rarely sits
    /// near 1 with low variance.
    let falloff: Double
    /// Spatial variation of the normalised gain: structure that survives
    /// dividing out the overall change.
    let structure: Double

    init(dark: Grid, lit: Grid) {
        let size = dark.size
        var gain = [Double](repeating: 0, count: dark.values.count)
        for i in 0..<dark.values.count {
            gain[i] = lit.values[i] - dark.values[i]
        }
        let overall = max(1e-6, mean(gain))
        let normalised = gain.map { $0 / overall }

        var centre: [Double] = []
        var edge: [Double] = []
        let inner = size / 4
        for y in 0..<size {
            for x in 0..<size {
                let isCentre = x >= inner && x < size - inner && y >= inner && y < size - inner
                if isCentre { centre.append(gain[y * size + x]) } else { edge.append(gain[y * size + x]) }
            }
        }
        gainCentre = mean(centre)
        gainEdge = mean(edge)
        falloff = gainEdge.magnitude > 1e-6 ? gainCentre / gainEdge : 0

        let m = mean(normalised)
        structure = (mean(normalised.map { ($0 - m) * ($0 - m) })).squareRoot()
    }
}

// MARK: - Capture

final class Probe: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "flash.probe")
    private let lock = NSLock()
    private var latest: CVPixelBuffer?

    func start() throws {
        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video) else {
            throw NSError(domain: "flash", code: 1, userInfo: [NSLocalizedDescriptionKey: "no camera"])
        }

        // Exposure and white balance are locked, which is the whole experiment.
        // Left on automatic, the camera would compensate for the flash within a
        // frame or two and erase exactly the signal being measured.
        try device.lockForConfiguration()
        if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
        if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
        device.unlockForConfiguration()

        let input = try AVCaptureDeviceInput(device: device)
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
    }

    func stop() { session.stopRunning() }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock(); latest = buffer; lock.unlock()
    }

    func grab() -> Grid? {
        lock.lock(); let buffer = latest; lock.unlock()
        guard let buffer else { return nil }
        return Grid(buffer)
    }
}

// MARK: - Run

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let probe = Probe()
do { try probe.start() } catch {
    print("Could not start the camera: \(error.localizedDescription)")
    exit(1)
}

let flash = FlashWindow()
print("Measuring \"\(label)\" for \(Int(duration))s — hold the subject steady and filling the frame.")
print("The screen will blink. Do not move.")
print()

var cycles = 0
var rawGains: [Double] = []
var falloffs: [Double] = []
var structures: [Double] = []
var gains: [Double] = []

let deadline = Date().addingTimeInterval(duration)
// Let exposure settle before the first flash, or the first cycle measures the
// camera adapting rather than the subject.
Thread.sleep(forTimeInterval: 1.5)

while Date() < deadline {
    flash.set(bright: false)
    RunLoop.current.run(until: Date().addingTimeInterval(0.35))
    guard let dark = probe.grab() else { continue }

    flash.set(bright: true)
    RunLoop.current.run(until: Date().addingTimeInterval(0.35))
    guard let lit = probe.grab() else { continue }

    let signature = FlashSignature(dark: dark, lit: lit)
    cycles += 1
    let rawGain = (signature.gainCentre + signature.gainEdge) / 2
    rawGains.append(rawGain)
    // A cycle where the flash barely registered says nothing about the subject.
    guard signature.gainCentre + signature.gainEdge > 0.004 else { continue }
    falloffs.append(signature.falloff)
    structures.append(signature.structure)
    gains.append((signature.gainCentre + signature.gainEdge) / 2)
}

flash.set(bright: false)
flash.close()
probe.stop()

func median(_ v: [Double]) -> Double {
    guard !v.isEmpty else { return 0 }
    return v.sorted()[v.count / 2]
}

print()
print("  subject          \(label)")
print("  usable cycles    \(falloffs.count)")
if falloffs.isEmpty {
    print("  cycles attempted \(cycles)")
    if rawGains.isEmpty {
        print("  no frames captured at all — camera permission for the terminal?")
    } else {
        print(String(format: "  largest gain seen %.5f (threshold is 0.002)", rawGains.map(abs).max() ?? 0))
        print("  the flash is not reaching the subject, or the room is washing it out")
    }
} else {
    print(String(format: "  mean gain        %.4f   (how much the flash lit it at all)", median(gains)))
    print(String(format: "  centre/edge      %.3f   (>1 = brightens more in the middle, like a solid)", median(falloffs)))
    print(String(format: "  structure        %.3f   (spatial detail surviving normalisation)", median(structures)))
}
