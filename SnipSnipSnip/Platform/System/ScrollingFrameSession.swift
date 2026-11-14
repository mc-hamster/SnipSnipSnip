import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit
import Synchronization

@MainActor
protocol ScrollingFrameSession: AnyObject {
    func nextFrame() throws -> CGImage?
    func stop() async
}

/// The callback queue and consumer share only this bounded, lock-protected FIFO.
/// No full-session frames or on-disk video are retained, including Private Capture.
nonisolated final class ScrollingFrameBuffer: Sendable {
    private struct State: Sendable {
        var frames: [CGImage] = []
        var failure: (any Error)?
        var closed = false
    }
    private let storage = Mutex(State())
    let capacity: Int

    init(width: Int, height: Int) {
        let pixels = max(Double(width) * Double(height), 1)
        capacity = max(1, Int(min(8, 64 * 1024 * 1024 / (pixels * 4))))
    }

    func offer(_ image: CGImage) {
        storage.withLock { state in
            guard !state.closed else { return }
            if state.frames.count == capacity { state.frames.removeFirst() }
            state.frames.append(image)
        }
    }

    func fail(_ error: any Error) { storage.withLock { $0.failure = error } }
    func take() throws -> CGImage? {
        try storage.withLock { state in
            if !state.frames.isEmpty { return state.frames.removeFirst() }
            if let error = state.failure { throw error }
            return nil
        }
    }
    func close() { storage.withLock { $0.closed = true } }
}

@MainActor
final class LiveScrollingFrameSession: NSObject, ScrollingFrameSession, SCStreamOutput, SCStreamDelegate {
    nonisolated private let buffer: ScrollingFrameBuffer
    nonisolated private let context = CIContext(options: [.cacheIntermediates: false])
    private let queue = DispatchQueue(label: "com.oontz.SnipSnipSnip.ScrollingFrames", qos: .userInitiated)
    private var stream: SCStream?

    init(filter: SCContentFilter, configuration: ScreenCaptureConfiguration) throws {
        buffer = ScrollingFrameBuffer(width: configuration.width, height: configuration.height)
        super.init()
        let settings = SCStreamConfiguration()
        settings.width = configuration.width
        settings.height = configuration.height
        if let sourceRect = configuration.sourceRect { settings.sourceRect = sourceRect }
        settings.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        settings.queueDepth = 3
        settings.pixelFormat = kCVPixelFormatType_32BGRA
        settings.showsCursor = false
        settings.capturesAudio = false
        settings.captureMicrophone = false
        settings.captureDynamicRange = .SDR
        let stream = SCStream(filter: filter, configuration: settings, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
    }

    func start() async throws { try await stream?.startCapture() }
    func nextFrame() throws -> CGImage? { try buffer.take() }
    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        let buffer = buffer
        await withCheckedContinuation { continuation in
            queue.async { buffer.close(); continuation.resume() }
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) { buffer.fail(error) }
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              rawStatus == SCFrameStatus.complete.rawValue || rawStatus == SCFrameStatus.started.rawValue,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        autoreleasepool {
            let image = CIImage(cvPixelBuffer: pixels)
            guard let raster = context.createCGImage(image, from: image.extent) else { return }
            buffer.offer(raster)
        }
    }
}
