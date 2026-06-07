import AVFoundation
import CoreGraphics
import CoreImage
import Foundation

nonisolated final class ConnectedDevicePreviewSession: NSObject, @unchecked Sendable {
    private let device: ConnectedAppleDevice
    private let captureDevice: AVCaptureDevice
    private let preferences: VideoRecordingPreferences
    private let sessionQueue = DispatchQueue(label: "com.oontz.Snips.connected-device.session")
    private let sampleQueue = DispatchQueue(label: "com.oontz.Snips.connected-device.samples")
    private let frameLock = NSLock()
    private let ciContext = CIContext()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var latestPixelBuffer: CVPixelBuffer?
    private var latestFrameSize = CGSize.zero
    private var recordingOutputURL: URL?
    private var recordingStartedAt: Date?
    private var stopRecordingContinuation: CheckedContinuation<CapturedVideoRecording, Error>?

    let captureSession = AVCaptureSession()

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

                self.captureSession.startRunning()
                continuation.resume()
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else {
                return
            }

            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            }

            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
        }
    }

    func captureLatestScreenshot() throws -> CapturedScreenshot {
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

    func startRecording() throws {
        guard !movieOutput.isRecording else {
            return
        }

        guard captureSession.isRunning else {
            throw ConnectedDeviceCaptureError.captureSessionFailed("The live preview is not running.")
        }

        let outputURL = TemporaryVideoMediaManager.recordingOutputURL(format: .mp4)
        try? FileManager.default.removeItem(at: outputURL)
        recordingOutputURL = outputURL
        recordingStartedAt = Date()
        movieOutput.startRecording(to: outputURL, recordingDelegate: self)
    }

    func stopRecording() async throws -> CapturedVideoRecording {
        guard movieOutput.isRecording else {
            throw ConnectedDeviceCaptureError.recordingFinalizeFailed("No connected-device recording is active.")
        }

        return try await withCheckedThrowingContinuation { continuation in
            stopRecordingContinuation = continuation
            movieOutput.stopRecording()
        }
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

        guard captureSession.canAddOutput(movieOutput) else {
            throw ConnectedDeviceCaptureError.captureSessionFailed("The connected device could not provide recordable video.")
        }
        captureSession.addOutput(movieOutput)

        movieOutput.movieFragmentInterval = .invalid
    }

    private func finishRecording(to outputURL: URL, error: Error?) {
        let continuation = stopRecordingContinuation
        stopRecordingContinuation = nil

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
}

extension ConnectedDevicePreviewSession: @preconcurrency AVCaptureVideoDataOutputSampleBufferDelegate {
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

extension ConnectedDevicePreviewSession: @preconcurrency AVCaptureFileOutputRecordingDelegate {
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
