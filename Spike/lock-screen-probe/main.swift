import AVFoundation
import CoreGraphics
import Foundation
import Vision

// A standalone probe that answers one question and nothing else:
//
//     Does macOS keep delivering camera frames to a normal user-session
//     process while the screen is locked, and can Vision still find a face
//     in them?
//
// Everything FaceUnlock could do at the lock screen depends on that answer,
// and it cannot be looked up — Apple documents neither a guarantee nor a
// prohibition, and the behaviour has changed between releases. So it is
// measured instead.
//
// The probe installs nothing, needs no administrator rights and touches no
// system state. It opens the camera, counts frames, and prints one line every
// two seconds saying whether the screen was locked at that moment. Stopping it
// is Ctrl-C.

// MARK: - Counters shared between the capture queue and the reporting timer

final class ProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private var framesSinceReport = 0
    private var facesSinceReport = 0
    private var analysedSinceReport = 0
    private var totalFrames = 0
    private var totalFramesWhileLocked = 0
    private var totalFacesWhileLocked = 0

    func recordFrame(analysed: Bool, faceFound: Bool, locked: Bool) {
        lock.lock(); defer { lock.unlock() }
        framesSinceReport += 1
        totalFrames += 1
        if analysed { analysedSinceReport += 1 }
        if faceFound { facesSinceReport += 1 }
        if locked {
            totalFramesWhileLocked += 1
            if faceFound { totalFacesWhileLocked += 1 }
        }
    }

    struct Report {
        var frames: Int
        var analysed: Int
        var faces: Int
        var totalFrames: Int
        var totalFramesWhileLocked: Int
        var totalFacesWhileLocked: Int
    }

    func drain() -> Report {
        lock.lock(); defer { lock.unlock() }
        let report = Report(
            frames: framesSinceReport,
            analysed: analysedSinceReport,
            faces: facesSinceReport,
            totalFrames: totalFrames,
            totalFramesWhileLocked: totalFramesWhileLocked,
            totalFacesWhileLocked: totalFacesWhileLocked
        )
        framesSinceReport = 0
        analysedSinceReport = 0
        facesSinceReport = 0
        return report
    }
}

// MARK: - Lock state

/// True when the login session reports the screen as locked. Read fresh every
/// time: this is the whole point of the measurement.
func screenIsLocked() -> Bool {
    guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return (info["CGSSessionScreenIsLocked"] as? Bool) ?? false
}

// MARK: - Logging

let logURL = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("faceunlock-lock-probe.log")

let timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
}()

func log(_ message: String) {
    let line = "[\(timestampFormatter.string(from: Date()))] \(message)"
    print(line)
    fflush(stdout)
    guard let data = (line + "\n").data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: logURL) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: logURL)
    }
}

// MARK: - Capture

final class FrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let state: ProbeState
    private var counter = 0

    init(state: ProbeState) {
        self.state = state
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        counter += 1
        let locked = screenIsLocked()
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            state.recordFrame(analysed: false, faceFound: false, locked: locked)
            return
        }
        // Face detection on every fifth frame only: the question is whether
        // frames arrive at all, and running Vision on all of them would burn
        // battery for no extra information.
        guard counter % 5 == 0 else {
            state.recordFrame(analysed: false, faceFound: false, locked: locked)
            return
        }
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try? handler.perform([request])
        let faceFound = !(request.results?.isEmpty ?? true)
        state.recordFrame(analysed: true, faceFound: faceFound, locked: locked)
    }
}

// MARK: - Main

log("=== FaceUnlock lock-screen camera probe ===")
log("Log file: \(logURL.path)")

switch AVCaptureDevice.authorizationStatus(for: .video) {
case .authorized:
    log("Camera permission: already granted")
case .notDetermined:
    log("Camera permission: asking now — approve the prompt for Terminal")
    let semaphore = DispatchSemaphore(value: 0)
    var granted = false
    AVCaptureDevice.requestAccess(for: .video) { result in
        granted = result
        semaphore.signal()
    }
    semaphore.wait()
    guard granted else {
        log("Camera permission: DENIED — nothing to measure. Enable it for Terminal in")
        log("System Settings > Privacy & Security > Camera, then run this again.")
        exit(1)
    }
    log("Camera permission: granted")
default:
    log("Camera permission: DENIED or restricted — enable it for Terminal in")
    log("System Settings > Privacy & Security > Camera, then run this again.")
    exit(1)
}

guard let device = AVCaptureDevice.default(for: .video) else {
    log("No camera found.")
    exit(1)
}
log("Camera: \(device.localizedName)")

let session = AVCaptureSession()
session.beginConfiguration()
session.sessionPreset = .vga640x480

do {
    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else {
        log("The camera input was refused.")
        exit(1)
    }
    session.addInput(input)
} catch {
    log("The camera could not be opened: \(error.localizedDescription)")
    exit(1)
}

let state = ProbeState()
let delegate = FrameDelegate(state: state)
let output = AVCaptureVideoDataOutput()
output.alwaysDiscardsLateVideoFrames = true
output.setSampleBufferDelegate(delegate, queue: DispatchQueue(label: "de.faceunlock.probe.frames"))
guard session.canAddOutput(output) else {
    log("The video output was refused.")
    exit(1)
}
session.addOutput(output)
session.commitConfiguration()
session.startRunning()

log("")
log("Camera started. Now do this:")
log("  1. Leave this window running.")
log("  2. Lock the screen (Control-Command-Q) and stay in front of the Mac.")
log("  3. Wait about 30 seconds, then unlock.")
log("  4. Press Ctrl-C here and send me the last lines.")
log("")
log("A line with locked=YES and frames greater than 0 is the answer I need.")
log("")

// Report every two seconds. `frames` is how many arrived since the last line,
// `faces` how many of the analysed ones contained a face.
let timer = Timer(timeInterval: 2, repeats: true) { _ in
    let report = state.drain()
    let locked = screenIsLocked()
    log(
        "locked=\(locked ? "YES" : "no ") "
            + "frames=\(String(format: "%3d", report.frames)) "
            + "analysed=\(String(format: "%2d", report.analysed)) "
            + "faces=\(String(format: "%2d", report.faces)) "
            + "| totals: frames=\(report.totalFrames) "
            + "whileLocked=\(report.totalFramesWhileLocked) "
            + "facesWhileLocked=\(report.totalFacesWhileLocked)"
    )
}
RunLoop.main.add(timer, forMode: .common)

// Ctrl-C prints the verdict instead of dying silently.
signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler {
    let report = state.drain()
    log("")
    log("=== Result ===")
    log("Frames captured in total:        \(report.totalFrames)")
    log("Frames captured while locked:    \(report.totalFramesWhileLocked)")
    log("Faces detected while locked:     \(report.totalFacesWhileLocked)")
    if report.totalFramesWhileLocked == 0 {
        log("VERDICT: the camera delivered nothing while the screen was locked,")
        log("         or the screen was never locked during the run.")
    } else if report.totalFacesWhileLocked == 0 {
        log("VERDICT: frames kept arriving while locked, but no face was found in them.")
        log("         Recognition at the lock screen would need more work, not a different API.")
    } else {
        log("VERDICT: the camera works while the screen is locked and faces are")
        log("         detectable. Real unlock is worth building.")
    }
    log("Log saved at \(logURL.path)")
    session.stopRunning()
    exit(0)
}
interrupt.resume()

RunLoop.main.run()
