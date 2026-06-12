import AppKit
import CoreImage
import CoreMedia
@preconcurrency import ScreenCaptureKit

@MainActor
final class LiveDesktopPreviewSource {
    typealias Observer = @MainActor () -> Void

    private var sessionsByDisplayID: [CGDirectDisplayID: LiveDesktopPreviewSession] = [:]
    private var latestImagesByDisplayID: [CGDirectDisplayID: CGImage] = [:]
    private var observersByDisplayID: [CGDirectDisplayID: [UUID: Observer]] = [:]
    private let displaysByID: [CGDirectDisplayID: DisplaySnapshot]
    private let processID = ProcessInfo.processInfo.processIdentifier

    init(displays: [DisplaySnapshot]) {
        self.displaysByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.displayID, $0) })
    }

    func start() async throws {
        guard !displaysByID.isEmpty else {
            return
        }

        let content = try await fetchShareableContent()
        let excludedApplications = content.applications.filter { $0.processID == processID }
        let excludedWindows = content.windows.filter { $0.owningApplication?.processID == processID }
        let sessions = displaysByID.keys.compactMap { displayID -> LiveDesktopPreviewSession? in
            guard let display = content.displays.first(where: { $0.displayID == displayID }),
                  let snapshot = displaysByID[displayID] else {
                return nil
            }

            let filter: SCContentFilter
            if excludedApplications.isEmpty {
                filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
            } else {
                filter = SCContentFilter(
                    display: display,
                    excludingApplications: excludedApplications,
                    exceptingWindows: []
                )
            }
            filter.includeMenuBar = true

            return LiveDesktopPreviewSession(
                displayID: displayID,
                filter: filter,
                snapshot: snapshot
            ) { [weak self] frame in
                self?.store(frame: frame)
            }
        }

        for session in sessions {
            sessionsByDisplayID[session.displayID] = session
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for session in sessions {
                    group.addTask {
                        try await session.start()
                    }
                }

                try await group.waitForAll()
            }
        } catch {
            await stop()
            throw error
        }
    }

    func stop() async {
        let sessions = Array(sessionsByDisplayID.values)
        sessionsByDisplayID.removeAll()
        latestImagesByDisplayID.removeAll()

        for session in sessions {
            await session.stop()
        }
    }

    func image(for displayID: CGDirectDisplayID) -> CGImage? {
        latestImagesByDisplayID[displayID]
    }

    @discardableResult
    func addObserver(for displayID: CGDirectDisplayID, _ observer: @escaping Observer) -> UUID {
        let token = UUID()
        var observers = observersByDisplayID[displayID] ?? [:]
        observers[token] = observer
        observersByDisplayID[displayID] = observers
        return token
    }

    func removeObserver(for displayID: CGDirectDisplayID, token: UUID) {
        observersByDisplayID[displayID]?[token] = nil
        if observersByDisplayID[displayID]?.isEmpty == true {
            observersByDisplayID[displayID] = nil
        }
    }

    private func store(frame: LiveDesktopPreviewFrame) {
        latestImagesByDisplayID[frame.displayID] = frame.image
        observersByDisplayID[frame.displayID]?.values.forEach { $0() }
    }

    private func fetchShareableContent() async throws -> SCShareableContent {
        let result: ShareableContentResult = try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let content else {
                    continuation.resume(throwing: ScreenCaptureError.noDisplays)
                    return
                }

                continuation.resume(returning: ShareableContentResult(content: content))
            }
        }

        return result.content
    }
}

private final class LiveDesktopPreviewSession: NSObject, SCStreamOutput {
    nonisolated private static let ciContext = CIContext(options: nil)

    let displayID: CGDirectDisplayID

    private let stream: SCStream
    private let sampleOutputQueue: DispatchQueue
    private let onFrame: @MainActor (LiveDesktopPreviewFrame) -> Void
    private let frameDeliveryLock = NSLock()
    nonisolated(unsafe) private var pendingFrame: LiveDesktopPreviewFrame?
    nonisolated(unsafe) private var isFrameDeliveryScheduled = false
    private var isCapturing = false

    init(
        displayID: CGDirectDisplayID,
        filter: SCContentFilter,
        snapshot: DisplaySnapshot,
        onFrame: @escaping @MainActor (LiveDesktopPreviewFrame) -> Void
    ) {
        self.displayID = displayID
        self.sampleOutputQueue = DispatchQueue(label: "com.oontz.SnipSnipSnip.LiveDesktopPreview.\(displayID)")
        self.onFrame = onFrame

        let configuration = SCStreamConfiguration()
        configuration.width = max(Int((snapshot.frame.width * snapshot.scale).rounded(.up)), 1)
        configuration.height = max(Int((snapshot.frame.height * snapshot.scale).rounded(.up)), 1)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 1
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.captureDynamicRange = .SDR
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        self.stream = SCStream(filter: filter, configuration: configuration, delegate: nil)

        super.init()
    }

    func start() async throws {
        guard !isCapturing else {
            return
        }

        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleOutputQueue)
        try await stream.startCapture()
        isCapturing = true
    }

    func stop() async {
        guard isCapturing else {
            return
        }

        try? await stream.stopCapture()
        isCapturing = false
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = Self.ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return
        }

        let frame = LiveDesktopPreviewFrame(displayID: displayID, image: cgImage)
        storePendingFrame(frame)
    }

    nonisolated private func storePendingFrame(_ frame: LiveDesktopPreviewFrame) {
        let shouldScheduleDelivery: Bool

        frameDeliveryLock.lock()
        pendingFrame = frame
        shouldScheduleDelivery = !isFrameDeliveryScheduled
        if shouldScheduleDelivery {
            isFrameDeliveryScheduled = true
        }
        frameDeliveryLock.unlock()

        guard shouldScheduleDelivery else {
            return
        }

        Task { @MainActor [weak self, onFrame] in
            guard let frame = self?.takePendingFrame() else {
                return
            }

            onFrame(frame)
        }
    }

    nonisolated private func takePendingFrame() -> LiveDesktopPreviewFrame? {
        frameDeliveryLock.lock()
        defer { frameDeliveryLock.unlock() }

        let frame = pendingFrame
        pendingFrame = nil
        isFrameDeliveryScheduled = false
        return frame
    }
}

nonisolated private struct LiveDesktopPreviewFrame: @unchecked Sendable {
    let displayID: CGDirectDisplayID
    let image: CGImage
}

nonisolated private struct ShareableContentResult: @unchecked Sendable {
    let content: SCShareableContent
}
