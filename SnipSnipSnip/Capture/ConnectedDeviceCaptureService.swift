import Foundation

nonisolated struct ConnectedAppleDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let modelName: String?

    init(id: String, name: String, modelName: String? = nil) {
        self.id = id
        self.name = name
        self.modelName = modelName
    }

    var displayName: String {
        if let modelName, !modelName.isEmpty, modelName != name {
            return "\(name) (\(modelName))"
        }

        return name
    }
}

nonisolated enum ConnectedDeviceVideoAuthorizationStatus: Equatable, Sendable {
    case authorized
    case notDetermined
    case denied
}

nonisolated enum ConnectedDeviceCaptureError: LocalizedError, Equatable {
    case noConnectedDevice
    case cameraPermissionNotDetermined
    case cameraPermissionDenied
    case missingCaptureConfiguration([String])
    case publicScreenCaptureUnavailable
    case sessionAlreadyActive
    case deviceDisconnected(String)
    case captureSessionFailed(String)
    case previewInterrupted(String)
    case previewRuntimeError(String)
    case noVideoFramesReceived
    case protectedContentUnavailable
    case recordingFinalizeFailed(String)
    case usbDeviceStreamUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .noConnectedDevice:
            return "No iPhone or iPad connected. Connect a device with USB and trust this Mac."
        case .cameraPermissionNotDetermined:
            return "Connected-device capture needs Camera access because macOS exposes trusted iPhone and iPad screens as video sources. Choose a connected device to continue."
        case .cameraPermissionDenied:
            return "Camera access is required for connected iPhone and iPad preview, screenshots, and recordings because macOS exposes those screens as video sources."
        case .missingCaptureConfiguration(let keys):
            return "Connected-device capture is enabled, but this app build is missing required camera configuration: \(keys.joined(separator: ", ")). Use the Dev Debug configuration file or the self-release configuration so the camera entitlement and Info.plist keys are included."
        case .publicScreenCaptureUnavailable:
            return "Connected iPhone and iPad screen capture is not available through public macOS APIs. \(AppBranding.displayName) cannot use private device services or QuickTime automation in an App Store-safe build."
        case .sessionAlreadyActive:
            return "Another connected-device capture session is already active."
        case .deviceDisconnected(let deviceName):
            return "\(deviceName) disconnected. Preview or recording stopped safely."
        case .captureSessionFailed(let message):
            return "Connected-device capture failed: \(message)"
        case .previewInterrupted(let message):
            return "Connected-device preview was interrupted: \(message)"
        case .previewRuntimeError(let message):
            return "Connected-device preview stopped because macOS reported a runtime error: \(message)"
        case .noVideoFramesReceived:
            return "No video frames were received from the connected device. Keep the device awake and unlocked, confirm Trust This Computer if prompted, then try Refresh Devices."
        case .protectedContentUnavailable:
            return "Protected content cannot be captured from the connected device."
        case .recordingFinalizeFailed(let message):
            return "The connected-device recording could not be finalized: \(message)"
        case .usbDeviceStreamUnavailable(let deviceName):
            return "\(deviceName) is connected over USB, but macOS is not exposing its screen stream. Unlock the device, confirm Trust This Computer, keep it awake, then choose Refresh Devices."
        }
    }
}

nonisolated protocol ConnectedDeviceCaptureServiceType: Sendable {
    func listDevices() async -> [ConnectedAppleDevice]
    func unavailableReason() async -> ConnectedDeviceCaptureError
    func videoAuthorizationStatus() async -> ConnectedDeviceVideoAuthorizationStatus
    func makePreviewSession(for device: ConnectedAppleDevice, preferences: VideoRecordingPreferences) async throws -> ConnectedDevicePreviewSession
}

nonisolated struct ConnectedDeviceCaptureService: ConnectedDeviceCaptureServiceType {
    private let capabilities: AppCapabilitySnapshot
    private let platform: any ConnectedDevicePlatform

    init(
        capabilities: AppCapabilitySnapshot,
        platform: any ConnectedDevicePlatform
    ) {
        self.capabilities = capabilities
        self.platform = platform
    }

    func listDevices() async -> [ConnectedAppleDevice] {
        guard capabilities.isEnabled(.connectedDeviceCapture) else {
            return []
        }

        return await platform.listDevices()
    }

    func unavailableReason() async -> ConnectedDeviceCaptureError {
        guard capabilities.isEnabled(.connectedDeviceCapture) else {
            return .publicScreenCaptureUnavailable
        }

        return await platform.unavailableReason()
    }

    func videoAuthorizationStatus() async -> ConnectedDeviceVideoAuthorizationStatus {
        guard capabilities.isEnabled(.connectedDeviceCapture) else {
            return .denied
        }

        return await platform.videoAuthorizationStatus()
    }

    func makePreviewSession(
        for device: ConnectedAppleDevice,
        preferences: VideoRecordingPreferences
    ) async throws -> ConnectedDevicePreviewSession {
        guard capabilities.isEnabled(.connectedDeviceCapture) else {
            throw ConnectedDeviceCaptureError.publicScreenCaptureUnavailable
        }

        return try await platform.makePreviewSession(for: device, preferences: preferences)
    }
}

nonisolated enum ConnectedDeviceCaptureMenu {
    static let emptyStateTitle = "No iPhone or iPad Connected"
    static let emptyStateMessage = ConnectedDeviceCaptureError.noConnectedDevice.errorDescription
        ?? "No iPhone or iPad connected."
}
