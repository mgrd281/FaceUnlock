import AVFoundation
import CoreVideo
import Foundation

public protocol CameraManaging: Sendable {
    /// Starts capture and returns a stream of frames throttled to `frameRate`.
    /// Finishing the stream — or calling `stop()` — tears the session down.
    func start(frameRate: Double) async throws -> AsyncStream<CameraFrame>
    func stop() async
    func isRunning() async -> Bool
}

/// Owns the `AVCaptureSession`.
///
/// Power behaviour, which is the main design constraint here:
/// * The session is created lazily and torn down completely in `stop()`. There is
///   no idling session, so the camera indicator light is off and the ISP is
///   powered down whenever FaceUnlock is not actively looking for a face.
/// * Frames are throttled in the capture callback before anything else happens,
///   so a 30 fps device costs one `CMTime` comparison per dropped frame.
/// * `alwaysDiscardsLateVideoFrames` keeps the queue from growing when the
///   recognition pipeline is briefly slower than the camera.
public actor CameraManager: CameraManaging {
    private var session: AVCaptureSession?
    private var output: AVCaptureVideoDataOutput?
    private var delegate: FrameDelegate?
    private var continuation: AsyncStream<CameraFrame>.Continuation?
    private var sequence: UInt64 = 0
    private let sessionQueue = DispatchQueue(label: "de.faceunlock.mac.camera", qos: .userInitiated)
    private let preferredDeviceID: String?

    public init(preferredDeviceID: String? = nil) {
        self.preferredDeviceID = preferredDeviceID
    }

    public func isRunning() async -> Bool {
        session?.isRunning ?? false
    }

    public func start(frameRate: Double) async throws -> AsyncStream<CameraFrame> {
        if session != nil { await stop() }

        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw FaceUnlockError.cameraPermissionDenied
        }
        guard let device = CameraDiscovery.preferredDevice(matching: preferredDeviceID) else {
            throw FaceUnlockError.cameraUnavailable
        }
        if device.isInUseByAnotherApplication {
            throw FaceUnlockError.cameraBusy
        }

        let session = AVCaptureSession()
        session.beginConfiguration()
        // 640x480 is ample for a face that fills a useful part of the frame, and it
        // keeps both the ISP and the Vision requests cheap.
        session.sessionPreset = .vga640x480

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            session.commitConfiguration()
            throw FaceUnlockError.cameraStartFailed(error.localizedDescription)
        }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw FaceUnlockError.cameraStartFailed("The camera input could not be attached.")
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw FaceUnlockError.cameraStartFailed("The camera output could not be attached.")
        }
        session.addOutput(output)
        session.commitConfiguration()

        let interval = 1.0 / max(1.0, frameRate)
        let stream = AsyncStream<CameraFrame>(bufferingPolicy: .bufferingNewest(2)) { continuation in
            let delegate = FrameDelegate(minimumInterval: interval) { [weak self] pixelBuffer, timestamp in
                guard let self else { return }
                Task { await self.emit(pixelBuffer: pixelBuffer, timestamp: timestamp) }
            }
            output.setSampleBufferDelegate(delegate, queue: self.sessionQueue)
            self.delegate = delegate
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.stop() }
            }
        }

        self.session = session
        self.output = output
        self.sequence = 0

        await withCheckedContinuation { (resumed: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                session.startRunning()
                resumed.resume()
            }
        }

        guard session.isRunning else {
            await stop()
            throw FaceUnlockError.cameraStartFailed("The capture session did not start.")
        }

        AppLogger.camera.notice(
            "Camera started at \(frameRate, format: .fixed(precision: 1), privacy: .public) fps"
        )
        return stream
    }

    public func stop() async {
        guard let session else { return }
        let output = self.output
        self.session = nil
        self.output = nil
        self.delegate = nil
        continuation?.finish()
        continuation = nil

        await withCheckedContinuation { (resumed: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                output?.setSampleBufferDelegate(nil, queue: nil)
                if session.isRunning { session.stopRunning() }
                for input in session.inputs { session.removeInput(input) }
                for existingOutput in session.outputs { session.removeOutput(existingOutput) }
                resumed.resume()
            }
        }
        AppLogger.camera.notice("Camera stopped and released")
    }

    private func emit(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) {
        guard let continuation else { return }
        sequence &+= 1
        continuation.yield(CameraFrame(pixelBuffer: pixelBuffer, timestamp: timestamp, sequence: sequence))
    }
}

/// Capture callback. Throttling happens here so that dropped frames cost as
/// little as possible.
private final class FrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let minimumInterval: TimeInterval
    private let onFrame: @Sendable (CVPixelBuffer, TimeInterval) -> Void
    private var lastEmitted: TimeInterval = -.greatestFiniteMagnitude

    init(minimumInterval: TimeInterval, onFrame: @escaping @Sendable (CVPixelBuffer, TimeInterval) -> Void) {
        self.minimumInterval = minimumInterval
        self.onFrame = onFrame
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard timestamp - lastEmitted >= minimumInterval else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastEmitted = timestamp
        onFrame(pixelBuffer, timestamp)
    }
}
