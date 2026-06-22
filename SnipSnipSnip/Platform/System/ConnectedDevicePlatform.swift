import AppKit
import CoreGraphics
import CoreImage
import Foundation

#if !APP_STORE_BUILD
import AVFoundation
import CoreMediaIO
import IOKit
#endif

nonisolated protocol ConnectedDevicePlatform: Sendable {
    func listDevices() async -> [ConnectedAppleDevice]
    func unavailableReason() async -> ConnectedDeviceCaptureError
    func videoAuthorizationStatus() async -> ConnectedDeviceVideoAuthorizationStatus
    func makePreviewSession(
        for device: ConnectedAppleDevice,
        preferences: VideoRecordingPreferences
    ) async throws -> ConnectedDevicePreviewSession
}

nonisolated struct LiveConnectedDevicePlatform: ConnectedDevicePlatform {
    func listDevices() async -> [ConnectedAppleDevice] {
#if APP_STORE_BUILD
        return []
#else
        guard Self.hasRequiredBundleCaptureConfiguration else {
            return []
        }

        Self.enableWiredScreenCaptureDevices()

        return Self.captureDevices().map { device in
            ConnectedAppleDevice(
                id: device.uniqueID,
                name: device.localizedName,
                modelName: device.modelID.isEmpty ? nil : device.modelID
            )
        }
#endif
    }

    func unavailableReason() async -> ConnectedDeviceCaptureError {
#if APP_STORE_BUILD
        return .publicScreenCaptureUnavailable
#else
        if let error = Self.missingBundleCaptureConfigurationError {
            return error
        }

        Self.enableWiredScreenCaptureDevices()

        switch Self.videoAuthorizationStatus() {
        case .denied:
            return .cameraPermissionDenied
        case .authorized:
            break
        case .notDetermined:
            if Self.usbConnectedMobileDevices().isEmpty, Self.captureDevices().isEmpty {
                return .noConnectedDevice
            }

            return .cameraPermissionNotDetermined
        }

        if let usbDevice = Self.usbConnectedMobileDevices().first {
            return .usbDeviceStreamUnavailable(usbDevice.displayName)
        }

        return .noConnectedDevice
#endif
    }

    func videoAuthorizationStatus() async -> ConnectedDeviceVideoAuthorizationStatus {
#if APP_STORE_BUILD
        return .denied
#else
        Self.videoAuthorizationStatus()
#endif
    }

    func makePreviewSession(
        for device: ConnectedAppleDevice,
        preferences: VideoRecordingPreferences
    ) async throws -> ConnectedDevicePreviewSession {
#if APP_STORE_BUILD
        throw ConnectedDeviceCaptureError.publicScreenCaptureUnavailable
#else
        if let error = Self.missingBundleCaptureConfigurationError {
            throw error
        }

        Self.enableWiredScreenCaptureDevices()

        guard await Self.ensureVideoAccess() else {
            throw ConnectedDeviceCaptureError.cameraPermissionDenied
        }

        guard let captureDevice = Self.captureDevices().first(where: { $0.uniqueID == device.id }) else {
            throw ConnectedDeviceCaptureError.deviceDisconnected(device.displayName)
        }

        let platformSession = try LiveConnectedDevicePreviewPlatformSession(
            device: device,
            captureDevice: captureDevice,
            preferences: preferences
        )
        return ConnectedDevicePreviewSession(platformSession: platformSession)
#endif
    }
}

#if !APP_STORE_BUILD
private extension LiveConnectedDevicePlatform {
    static func videoAuthorizationStatus() -> ConnectedDeviceVideoAuthorizationStatus {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .authorized
        case .notDetermined:
            return .notDetermined
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }

    static func ensureVideoAccess() async -> Bool {
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

    static var hasRequiredBundleCaptureConfiguration: Bool {
        missingBundleCaptureConfigurationError == nil
    }

    static var missingBundleCaptureConfigurationError: ConnectedDeviceCaptureError? {
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

    static func captureDevices() -> [AVCaptureDevice] {
        enableWiredScreenCaptureDevices()

        let muxedDevices = discoverySession(mediaType: .muxed).devices
        let namedMobileVideoDevices = discoverySession(mediaType: .video).devices
            .filter { device in
                let foldedName = device.localizedName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                return foldedName.contains("iphone") || foldedName.contains("ipad")
            }

        return (muxedDevices + namedMobileVideoDevices).stableUniquedByUniqueID()
    }

    static func discoverySession(mediaType: AVMediaType) -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .continuityCamera],
            mediaType: mediaType,
            position: .unspecified
        )
    }

    static func enableWiredScreenCaptureDevices() {
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

    static func usbConnectedMobileDevices() -> [ConnectedAppleDevice] {
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

    static func connectedAppleMobileDevice(from service: io_object_t) -> ConnectedAppleDevice? {
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

    static func registryString(_ key: String, from service: io_object_t) -> String? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    static func registryNumber(_ key: String, from service: io_object_t) -> NSNumber? {
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

private final class LiveConnectedDevicePreviewPlatformSession: NSObject, ConnectedDevicePreviewPlatformSession, @unchecked Sendable {
    private let device: ConnectedAppleDevice
    private let captureDevice: AVCaptureDevice
    private let preferences: VideoRecordingPreferences
    private let sessionQueue = DispatchQueue(label: "com.oontz.Snips.connected-device.session")
    private let sampleQueue = DispatchQueue(label: "com.oontz.Snips.connected-device.samples")
    private let frameLock = NSLock()
    private let runtimeIssueLock = NSLock()
    private let ciContext = CIContext()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var isStopped = false
    private var isMovieOutputConfigured = false
    private var runtimeNotificationObservers: [NSObjectProtocol] = []
    private var runtimeIssueHandler: (@Sendable (ConnectedDeviceCaptureError) -> Void)?
    private var latestPixelBuffer: CVPixelBuffer?
    private var latestFrameSize = CGSize.zero
    private var recordingOutputURL: URL?
    private var recordingStartedAt: Date?
    private var stopRecordingContinuation: CheckedContinuation<CapturedVideoRecording, Error>?

    private let captureSession = AVCaptureSession()

    init(
        device: ConnectedAppleDevice,
        captureDevice: AVCaptureDevice,
        preferences: VideoRecordingPreferences
    ) throws {
        self.device = device
        self.captureDevice = captureDevice
        self.preferences = preferences
        super.init()
        try configureSession()
    }

    deinit {
        stop()
    }

    nonisolated func setRuntimeIssueHandler(_ handler: (@Sendable (ConnectedDeviceCaptureError) -> Void)?) {
        runtimeIssueLock.lock()
        runtimeIssueHandler = handler
        runtimeIssueLock.unlock()
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: ConnectedDeviceCaptureError.captureSessionFailed("The preview session was released."))
                    return
                }

                guard !self.captureSession.isRunning else {
                    continuation.resume()
                    return
                }

                self.isStopped = false
                self.captureSession.startRunning()
                continuation.resume()
            }
        }
    }

    nonisolated func stop() {
        sessionQueue.async { [weak self] in
            guard let self else {
                return
            }

            guard !self.isStopped else {
                return
            }

            self.isStopped = true
            self.videoDataOutput.setSampleBufferDelegate(nil, queue: nil)

            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            }

            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }

            self.removeRuntimeObservers()

            self.captureSession.beginConfiguration()
            if self.isMovieOutputConfigured, self.captureSession.outputs.contains(self.movieOutput) {
                self.captureSession.removeOutput(self.movieOutput)
                self.isMovieOutputConfigured = false
            }
            if self.captureSession.outputs.contains(self.videoDataOutput) {
                self.captureSession.removeOutput(self.videoDataOutput)
            }
            for input in self.captureSession.inputs {
                self.captureSession.removeInput(input)
            }
            self.captureSession.commitConfiguration()

            self.frameLock.lock()
            self.latestPixelBuffer = nil
            self.latestFrameSize = .zero
            self.frameLock.unlock()
        }
    }

    nonisolated func captureLatestScreenshot() throws -> CapturedScreenshot {
        frameLock.lock()
        let pixelBuffer = latestPixelBuffer
        let frameSize = latestFrameSize
        frameLock.unlock()

        guard let pixelBuffer else {
            throw ConnectedDeviceCaptureError.noVideoFramesReceived
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let image = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            throw ConnectedDeviceCaptureError.captureSessionFailed("The latest device frame could not be converted into an image.")
        }

        let imageSize = frameSize == .zero
            ? CGSize(width: image.width, height: image.height)
            : frameSize

        return CapturedScreenshot(
            image: image,
            kind: .connectedDevice,
            sourceName: device.displayName,
            sourceRect: CGRect(origin: .zero, size: imageSize),
            capturedAt: Date()
        )
    }

    func startRecording() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: ConnectedDeviceCaptureError.captureSessionFailed("The preview session was released."))
                    return
                }

                guard !self.isStopped else {
                    continuation.resume(throwing: ConnectedDeviceCaptureError.captureSessionFailed("The preview session is stopped."))
                    return
                }

                guard !self.movieOutput.isRecording else {
                    continuation.resume()
                    return
                }

                guard self.captureSession.isRunning else {
                    continuation.resume(throwing: ConnectedDeviceCaptureError.captureSessionFailed("The live preview is not running."))
                    return
                }

                do {
                    try self.configureMovieOutputIfNeeded()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let outputURL = TemporaryVideoMediaManager.recordingOutputURL(format: .mp4)
                try? FileManager.default.removeItem(at: outputURL)
                self.recordingOutputURL = outputURL
                self.recordingStartedAt = Date()
                self.movieOutput.startRecording(to: outputURL, recordingDelegate: self)
                continuation.resume()
            }
        }
    }

    func stopRecording() async throws -> CapturedVideoRecording {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CapturedVideoRecording, Error>) in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: ConnectedDeviceCaptureError.recordingFinalizeFailed("The preview session was released."))
                    return
                }

                guard self.movieOutput.isRecording else {
                    continuation.resume(throwing: ConnectedDeviceCaptureError.recordingFinalizeFailed("No connected-device recording is active."))
                    return
                }

                self.stopRecordingContinuation = continuation
                self.movieOutput.stopRecording()
            }
        }
    }

    @MainActor
    func makePreviewView() -> NSView {
        let view = ConnectedDevicePreviewLayerContainerView()
        view.previewLayer.session = captureSession
        return view
    }

    @MainActor
    func updatePreviewView(_ view: NSView) {
        guard let view = view as? ConnectedDevicePreviewLayerContainerView else {
            return
        }

        view.previewLayer.session = captureSession
    }

    @MainActor
    func dismantlePreviewView(_ view: NSView) {
        guard let view = view as? ConnectedDevicePreviewLayerContainerView else {
            return
        }

        view.previewLayer.session = nil
    }

    private func configureSession() throws {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        if captureSession.canSetSessionPreset(.high) {
            captureSession.sessionPreset = .high
        }

        let input = try AVCaptureDeviceInput(device: captureDevice)
        guard captureSession.canAddInput(input) else {
            throw ConnectedDeviceCaptureError.captureSessionFailed("The connected device could not be added as a capture input.")
        }
        captureSession.addInput(input)

        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        ]
        videoDataOutput.setSampleBufferDelegate(self, queue: sampleQueue)
        guard captureSession.canAddOutput(videoDataOutput) else {
            throw ConnectedDeviceCaptureError.captureSessionFailed("The connected device could not provide preview frames.")
        }
        captureSession.addOutput(videoDataOutput)

        installRuntimeObservers()
    }

    private func configureMovieOutputIfNeeded() throws {
        guard !isMovieOutputConfigured else {
            return
        }

        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        guard captureSession.canAddOutput(movieOutput) else {
            throw ConnectedDeviceCaptureError.captureSessionFailed("The connected device could not provide recordable video.")
        }

        captureSession.addOutput(movieOutput)
        movieOutput.movieFragmentInterval = .invalid
        isMovieOutputConfigured = true
    }

    private func finishRecording(to outputURL: URL, error: Error?) {
        let continuation = stopRecordingContinuation
        stopRecordingContinuation = nil
        recordingOutputURL = nil

        if let error {
            continuation?.resume(throwing: ConnectedDeviceCaptureError.recordingFinalizeFailed(error.localizedDescription))
            return
        }

        let startedAt = recordingStartedAt ?? Date()
        let frameSize = currentFrameSize()

        Task {
            let duration = await Self.recordingDuration(from: outputURL, fallbackStart: startedAt)
            let recording = CapturedVideoRecording(
                sourceURL: outputURL,
                kind: .connectedDevice,
                sourceName: device.displayName,
                bounds: CGRect(origin: .zero, size: frameSize),
                recordedAt: startedAt,
                duration: duration,
                preferences: preferences
            )
            continuation?.resume(returning: recording)
        }
    }

    private func currentFrameSize() -> CGSize {
        frameLock.lock()
        let frameSize = latestFrameSize
        frameLock.unlock()
        return frameSize == .zero ? CGSize(width: 1, height: 1) : frameSize
    }

    private static func recordingDuration(from url: URL, fallbackStart: Date) async -> TimeInterval {
        let asset = AVURLAsset(url: url)

        if let duration = try? await asset.load(.duration) {
            let seconds = duration.seconds
            if seconds.isFinite, seconds > 0 {
                return seconds
            }
        }

        return max(Date().timeIntervalSince(fallbackStart), 0)
    }

    private func installRuntimeObservers() {
        removeRuntimeObservers()

        let center = NotificationCenter.default
        runtimeNotificationObservers = [
            center.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification,
                object: captureSession,
                queue: nil
            ) { [weak self] notification in
                self?.handleRuntimeError(notification)
            },
            center.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification,
                object: captureSession,
                queue: nil
            ) { [weak self] notification in
                self?.handleSessionInterruption(notification)
            },
        ]
    }

    private func removeRuntimeObservers() {
        let observers = runtimeNotificationObservers
        runtimeNotificationObservers = []

        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func handleRuntimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
        emitRuntimeIssue(.previewRuntimeError(error?.localizedDescription ?? "The capture session failed unexpectedly."))
    }

    private func handleSessionInterruption(_ notification: Notification) {
        emitRuntimeIssue(.previewInterrupted("macOS interrupted the connected-device stream. Keep the device awake and unlocked, then refresh devices if the preview does not recover."))
    }

    private func emitRuntimeIssue(_ issue: ConnectedDeviceCaptureError) {
        runtimeIssueLock.lock()
        let handler = runtimeIssueHandler
        runtimeIssueLock.unlock()

        handler?(issue)
    }
}

extension LiveConnectedDevicePreviewPlatformSession: @preconcurrency AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        frameLock.lock()
        latestPixelBuffer = pixelBuffer
        latestFrameSize = CGSize(width: width, height: height)
        frameLock.unlock()
    }
}

extension LiveConnectedDevicePreviewPlatformSession: @preconcurrency AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: (any Error)?
    ) {
        Task { @MainActor [weak self] in
            self?.finishRecording(to: outputFileURL, error: error)
        }
    }
}

private final class ConnectedDevicePreviewLayerContainerView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspect
        layer = previewLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}
#endif
