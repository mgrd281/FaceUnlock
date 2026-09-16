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
/// ## Why this is a queue-confined class rather than an actor
///
/// Almost nothing in AVFoundation is `Sendable`: `AVCaptureSession`,
/// `AVCaptureDevice` and `AVCaptureVideoDataOutput` all are not. Holding them as
/// actor state means every `nonisolated` hop — the capture callback, a
/// `DispatchQueue.async` — has to smuggle a non-`Sendable` value across an
/// isolation boundary, which Swift 6 correctly rejects. Confining all of it to one
/// serial queue instead keeps every AVFoundation object on a single thread, which
/// is what AVFoundation wants anyway, and makes the `@unchecked Sendable`
/// conformance a statement about a real, checkable invariant: **every stored
/// property below is touched only on `sessionQueue`.**
///
/// ## Power behaviour
///
/// * The session is created lazily and torn down completely in `stop()` — there is
///   no idling session, so the camera indicator is off and the ISP is powered down
///   whenever FaceUnlock is not actively looking for a face.
/// * Frames are throttled inside the capture callback before anything else
///   happens, so a dropped frame costs one timestamp comparison.
/// * `alwaysDiscardsLateVideoFrames` stops the queue growing when the recognition
///   pipeline is briefly slower than the camera.
public final class CameraManager: CameraManaging, @unchecked Sendable {
    private let sessionQueue = DispatchQueue(label: "de.faceunlock.mac.camera", qos: .userInitiated)
    private let preferredDeviceID: String?

    // MARK: State — only ever touched on `sessionQueue`.
    private var session: AVCaptureSession?
    private var output: AVCaptureVideoDataOutput?
    private var delegate: FrameDelegate?
    private var continuation: AsyncStream<CameraFrame>.Continuation?

    public init(preferredDeviceID: String? = nil) {
        self.preferredDeviceID = preferredDeviceID
    }

    public func isRunning() async -> Bool {
        await withCheckedContinuation { (resumed: CheckedContinuation<Bool, Never>) in
            sessionQueue.async {
                resumed.resume(returning: self.session?.isRunning ?? false)
            }
        }
    }

    public func start(frameRate: Double) async throws -> AsyncStream<CameraFrame> {
        await stop()
        let interval = 1.0 / max(1.0, frameRate)
        let stream: AsyncStream<CameraFrame> = try await withCheckedThrowingContinuation { resumed in
            sessionQueue.async {
                do {
                    resumed.resume(returning: try self.startOnQueue(minimumInterval: interval))
                } catch {
                    self.teardownOnQueue()
                    resumed.resume(throwing: error)
                }
            }
        }
        AppLogger.camera.notice(
            "Camera started at \(frameRate, format: .fixed(precision: 1), privacy: .public) fps"
        )
        return stream
    }

    public func stop() async {
        await withCheckedContinuation { (resumed: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                let wasRunning = self.session != nil
                self.teardownOnQueue()
                if wasRunning {
                    AppLogger.camera.notice("Camera stopped and released")
                }
                resumed.resume()
            }
        }
    }

    // MARK: - Queue-confined work

    private func startOnQueue(minimumInterval: TimeInterval) throws -> AsyncStream<CameraFrame> {
        dispatchPrecondition(condition: .onQueue(sessionQueue))

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
        // 640×480 is ample for a face that fills a useful part of the frame, and it
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

        // The frames themselves are yielded straight from the capture callback.
        // `CameraFrame` is `Sendable`, so nothing non-sendable ever leaves this
        // queue, and there is no task hop per frame.
        let stream = AsyncStream<CameraFrame>(bufferingPolicy: .bufferingNewest(2)) { continuation in
            let delegate = FrameDelegate(minimumInterval: minimumInterval) { frame in
                continuation.yield(frame)
            }
            output.setSampleBufferDelegate(delegate, queue: sessionQueue)
            self.delegate = delegate
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.sessionQueue.async { self.teardownOnQueue() }
            }
        }

        self.session = session
        self.output = output

        session.startRunning()
        guard session.isRunning else {
            throw FaceUnlockError.cameraStartFailed("The capture session did not start.")
        }
        return stream
    }

    private func teardownOnQueue() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        output?.setSampleBufferDelegate(nil, queue: nil)
        if let session {
            if session.isRunning { session.stopRunning() }
            for input in session.inputs { session.removeInput(input) }
            for existingOutput in session.outputs { session.removeOutput(existingOutput) }
        }
        // Finishing the stream re-enters `onTermination`, which hops back onto this
        // queue and finds nothing left to do.
        continuation?.finish()
        continuation = nil
        session = nil
        output = nil
        delegate = nil
    }
}

/// Capture callback.
///
/// Throttling and sequence numbering both live here so that a dropped frame costs
/// as little as possible and so that the `CameraFrame` handed onwards is complete.
/// All of its state is touched only from the capture queue, which AVFoundation
/// serialises — that is what the `@unchecked` conformance asserts.
private final class FrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let minimumInterval: TimeInterval
    private let onFrame: @Sendable (CameraFrame) -> Void
    private var lastEmitted: TimeInterval = -.greatestFiniteMagnitude
    private var sequence: UInt64 = 0

    init(minimumInterval: TimeInterval, onFrame: @escaping @Sendable (CameraFrame) -> Void) {
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
        // Retaining the pixel buffer holds a slot in the capture pool, which is why
        // the stream buffers at most two frames.
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastEmitted = timestamp
        sequence &+= 1
        onFrame(CameraFrame(pixelBuffer: pixelBuffer, timestamp: timestamp, sequence: sequence))
    }
}
