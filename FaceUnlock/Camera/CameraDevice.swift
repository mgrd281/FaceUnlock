import AVFoundation
import Foundation

/// A camera FaceUnlock is willing to use.
public struct CameraDevice: Identifiable, Equatable, Sendable {
    public let id: String
    public let localizedName: String
    public let isBuiltIn: Bool
    public let isContinuityCamera: Bool

    public init(id: String, localizedName: String, isBuiltIn: Bool, isContinuityCamera: Bool) {
        self.id = id
        self.localizedName = localizedName
        self.isBuiltIn = isBuiltIn
        self.isContinuityCamera = isContinuityCamera
    }
}

public enum CameraDiscovery {
    /// Device types are listed built-in first so `availableCameras().first` is the
    /// internal camera whenever one exists.
    private static let deviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInWideAngleCamera,
        .continuityCamera,
        .external
    ]

    public static func availableCameras() -> [CameraDevice] {
        discoveryDevices().map { device in
            CameraDevice(
                id: device.uniqueID,
                localizedName: device.localizedName,
                isBuiltIn: device.deviceType == .builtInWideAngleCamera,
                isContinuityCamera: device.deviceType == .continuityCamera
            )
        }
    }

    /// The device FaceUnlock uses: the built-in camera when present, otherwise the
    /// first available one.
    public static func preferredDevice(matching identifier: String? = nil) -> AVCaptureDevice? {
        let devices = discoveryDevices()
        if let identifier, let match = devices.first(where: { $0.uniqueID == identifier }) {
            return match
        }
        return devices.first { $0.deviceType == .builtInWideAngleCamera } ?? devices.first
    }

    static func discoveryDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        ).devices
    }
}
