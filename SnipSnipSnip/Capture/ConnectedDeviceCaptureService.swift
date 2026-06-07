import AVFoundation
import CoreMediaIO
import CoreGraphics
import Foundation
import IOKit

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

nonisolated enum ConnectedDeviceCaptureError: LocalizedError, Equatable {
    case noConnectedDevice
    case cameraPermissionDenied
    case missingCaptureConfiguration([String])
    case publicScreenCaptureUnavailable
    case sessionAlreadyActive
    case deviceDisconnected(String)
    case captureSessionFailed(String)
    case noVideoFramesReceived
    case protectedContentUnavailable
    case recordingFinalizeFailed(String)
    case usbDeviceStreamUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .noConnectedDevice:
            return "No iPhone or iPad connected. Connect a device with USB and trust this Mac."
        case .cameraPermissionDenied:
            return "Camera access is required to preview connected-device video sources in this self-release build."
        case .missingCaptureConfiguration(let keys):
            return "Connected-device capture is enabled, but this app build is missing required camera configuration: \(keys.joined(separator: ", ")). Use the Dev Debug configuration file or the self-release configuration so the camera entitlement and Info.plist keys are included."
        case .publicScreenCaptureUnavailable:
            return "Connected iPhone and iPad screen capture is not available through public macOS APIs. SnipSnipSnip cannot use private device services or QuickTime automation in an App Store-safe build."
        case .sessionAlreadyActive:
            return "Another connected-device capture session is already active."
        case .deviceDisconnected(let deviceName):
            return "\(deviceName) disconnected. Preview or recording stopped safely."
        case .captureSessionFailed(let message):
            return "Connected-device capture failed: \(message)"
        case .noVideoFramesReceived:
            return "No video frames were received from the connected device."
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
    func makePreviewSession(for device: ConnectedAppleDevice, preferences: VideoRecordingPreferences) async throws -> ConnectedDevicePreviewSession
}

nonisolated struct ConnectedDeviceCaptureService: ConnectedDeviceCaptureServiceType {
    func listDevices() async -> [ConnectedAppleDevice] {
        guard FeatureFlags.connectedDeviceCaptureEnabled else {
            return []
        }

#if APP_STORE_BUILD
        return []
#else
        return await ConnectedDeviceAVFoundationBridge.listDevices()
#endif
    }

    func unavailableReason() async -> ConnectedDeviceCaptureError {
        guard FeatureFlags.connectedDeviceCaptureEnabled else {
            return .publicScreenCaptureUnavailable
        }

#if APP_STORE_BUILD
        return .publicScreenCaptureUnavailable
#else
        return await ConnectedDeviceAVFoundationBridge.unavailableReason()
#endif
    }

    func makePreviewSession(
        for device: ConnectedAppleDevice,
        preferences: VideoRecordingPreferences
    ) async throws -> ConnectedDevicePreviewSession {
        guard FeatureFlags.connectedDeviceCaptureEnabled else {
            throw ConnectedDeviceCaptureError.publicScreenCaptureUnavailable
        }

#if APP_STORE_BUILD
        throw ConnectedDeviceCaptureError.publicScreenCaptureUnavailable
#else
        return try await ConnectedDeviceAVFoundationBridge.makePreviewSession(for: device, preferences: preferences)
#endif
    }
}

nonisolated enum ConnectedDeviceCaptureMenu {
    static let emptyStateTitle = "No iPhone or iPad Connected"
    static let emptyStateMessage = ConnectedDeviceCaptureError.noConnectedDevice.errorDescription
        ?? "No iPhone or iPad connected."
}

#if !APP_STORE_BUILD
nonisolated private enum ConnectedDeviceAVFoundationBridge {
    static func listDevices() async -> [ConnectedAppleDevice] {
        guard hasRequiredBundleCaptureConfiguration else {
            return []
        }

        enableWiredScreenCaptureDevices()

        guard await ensureVideoAccess() else {
            return []
        }

        return captureDevices().map { device in
            ConnectedAppleDevice(
                id: device.uniqueID,
                name: device.localizedName,
                modelName: device.modelID.isEmpty ? nil : device.modelID
            )
        }
    }

    static func unavailableReason() async -> ConnectedDeviceCaptureError {
        if let error = missingBundleCaptureConfigurationError {
            return error
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            return .cameraPermissionDenied
        case .notDetermined:
            guard await ensureVideoAccess() else {
                return .cameraPermissionDenied
            }
        case .authorized:
            break
        @unknown default:
            return .cameraPermissionDenied
        }

        enableWiredScreenCaptureDevices()

        if let usbDevice = usbConnectedMobileDevices().first {
            return .usbDeviceStreamUnavailable(usbDevice.displayName)
        }

        return .noConnectedDevice
    }

    static func makePreviewSession(
        for device: ConnectedAppleDevice,
        preferences: VideoRecordingPreferences
    ) async throws -> ConnectedDevicePreviewSession {
        if let error = missingBundleCaptureConfigurationError {
            throw error
        }

        enableWiredScreenCaptureDevices()

        guard await ensureVideoAccess() else {
            throw ConnectedDeviceCaptureError.cameraPermissionDenied
        }

        guard let captureDevice = captureDevices().first(where: { $0.uniqueID == device.id }) else {
            throw ConnectedDeviceCaptureError.deviceDisconnected(device.displayName)
        }

        return try ConnectedDevicePreviewSession(
            device: device,
            captureDevice: captureDevice,
            preferences: preferences
        )
    }

    private static func ensureVideoAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private static var hasRequiredBundleCaptureConfiguration: Bool {
        missingBundleCaptureConfigurationError == nil
    }

    private static var missingBundleCaptureConfigurationError: ConnectedDeviceCaptureError? {
        let requiredKeys = [
            "NSCameraUsageDescription",
            "NSCameraUseExternalDeviceType",
            "NSCameraUseContinuityCameraDeviceType",
        ]
        let missingKeys = requiredKeys.filter { key in
            Bundle.main.object(forInfoDictionaryKey: key) == nil
        }

        guard !missingKeys.isEmpty else {
            return nil
        }

        return .missingCaptureConfiguration(missingKeys)
    }

    private static func captureDevices() -> [AVCaptureDevice] {
        enableWiredScreenCaptureDevices()

        let muxedDevices = discoverySession(mediaType: .muxed).devices
        let namedMobileVideoDevices = discoverySession(mediaType: .video).devices
            .filter { device in
                let foldedName = device.localizedName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                return foldedName.contains("iphone") || foldedName.contains("ipad")
            }

        return (muxedDevices + namedMobileVideoDevices).stableUniquedByUniqueID()
    }

    private static func discoverySession(mediaType: AVMediaType) -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .continuityCamera],
            mediaType: mediaType,
            position: .unspecified
        )
    }

    private static func enableWiredScreenCaptureDevices() {
        var propertyAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allow: UInt32 = 1

        _ = CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &allow
        )
    }

    private static func usbConnectedMobileDevices() -> [ConnectedAppleDevice] {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else {
            return []
        }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var devices: [ConnectedAppleDevice] = []
        var service = IOIteratorNext(iterator)

        while service != 0 {
            defer { IOObjectRelease(service) }

            if let device = connectedAppleMobileDevice(from: service) {
                devices.append(device)
            }

            service = IOIteratorNext(iterator)
        }

        return devices
    }

    private static func connectedAppleMobileDevice(from service: io_object_t) -> ConnectedAppleDevice? {
        let vendorID = registryNumber("idVendor", from: service)?.intValue
        guard vendorID == 1452 else {
            return nil
        }

        let productName = registryString("USB Product Name", from: service)
            ?? registryString("kUSBProductString", from: service)
            ?? "Apple mobile device"
        let foldedName = productName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard foldedName.contains("iphone") || foldedName.contains("ipad") else {
            return nil
        }

        let serial = registryString("USB Serial Number", from: service)
            ?? registryString("kUSBSerialNumberString", from: service)
            ?? UUID().uuidString

        return ConnectedAppleDevice(id: "usb:\(serial)", name: productName)
    }

    private static func registryString(_ key: String, from service: io_object_t) -> String? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    private static func registryNumber(_ key: String, from service: io_object_t) -> NSNumber? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber
    }
}

private extension Array where Element == AVCaptureDevice {
    nonisolated func stableUniquedByUniqueID() -> [AVCaptureDevice] {
        var seenIDs: Set<String> = []
        var uniqueDevices: [AVCaptureDevice] = []

        for device in self where seenIDs.insert(device.uniqueID).inserted {
            uniqueDevices.append(device)
        }

        return uniqueDevices
    }
}
#endif
