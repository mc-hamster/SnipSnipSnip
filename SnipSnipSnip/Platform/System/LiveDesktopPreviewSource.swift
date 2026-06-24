import AppKit
import CoreImage
import CoreMedia
@preconcurrency import ScreenCaptureKit

@MainActor
final class LiveDesktopPreviewSource {
    typealias Observer = @MainActor () -> Void

    private var sessionsByDisplayID: [CGDirectDisplayID: LiveDesktopPreviewSession] = [:]
    private var latestFramesByDisplayID: [CGDirectDisplayID: LiveDesktopPreviewFrame] = [:]
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
        latestFramesByDisplayID.removeAll()

        for session in sessions {
            await session.stop()
        }
    }

    func updateFocus(displayID: CGDirectDisplayID, cursorGlobalPoint: CGPoint) {
        sessionsByDisplayID[displayID]?.updateFocus(cursorGlobalPoint: cursorGlobalPoint)
    }

    func image(for displayID: CGDirectDisplayID) -> CGImage? {
        latestFramesByDisplayID[displayID]?.image
    }

    func frame(for displayID: CGDirectDisplayID) -> LiveDesktopPreviewFrame? {
        latestFramesByDisplayID[displayID]
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
        latestFramesByDisplayID[frame.displayID] = frame
        observersByDisplayID[frame.displayID]?.values.forEach { $0() }
    }

    private func fetchShareableContent() async throws -> SCShareableContent {
        let result: LiveDesktopPreviewShareableContentResult = try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let content else {
                    continuation.resume(throwing: ScreenCaptureError.noDisplays)
                    return
                }

                continuation.resume(returning: LiveDesktopPreviewShareableContentResult(content: content))
            }
        }
        return result.content
    }
}

nonisolated struct LiveDesktopPreviewFrame: @unchecked Sendable {
    let displayID: CGDirectDisplayID
    let image: CGImage
    let sourceRect: CGRect
    let sourceGlobalRect: CGRect
}

nonisolated private struct LiveDesktopPreviewShareableContentResult: @unchecked Sendable {
    let content: SCShareableContent
}

private final class LiveDesktopPreviewSession: NSObject, SCStreamOutput {
    nonisolated private static let ciContext = CIContext(options: nil)
    nonisolated private static let regionLogicalSize: CGFloat = 640
    nonisolated private static let recenterThresholdFraction: CGFloat = 0.28

    let displayID: CGDirectDisplayID

    private let stream: SCStream
    private let snapshot: DisplaySnapshot
    private let sampleOutputQueue: DispatchQueue
    private let onFrame: @MainActor (LiveDesktopPreviewFrame) -> Void
    private let frameDeliveryLock = NSLock()
    nonisolated(unsafe) private var pendingFrame: LiveDesktopPreviewFrame?
    nonisolated(unsafe) private var isFrameDeliveryScheduled = false
    nonisolated(unsafe) private var latestSourceRect: CGRect
    private var activeSourceRect: CGRect
    private var pendingFocusPoint: CGPoint?
    private var isConfigurationUpdateInFlight = false
    private var isCapturing = false

    init(
        displayID: CGDirectDisplayID,
        filter: SCContentFilter,
        snapshot: DisplaySnapshot,
        onFrame: @escaping @MainActor (LiveDesktopPreviewFrame) -> Void
    ) {
        self.displayID = displayID
        self.snapshot = snapshot
        self.sampleOutputQueue = DispatchQueue(label: "com.oontz.SnipSnipSnip.LiveDesktopPreview.\(displayID)")
        self.onFrame = onFrame
        let initialSourceRect = Self.centeredSourceRect(
            around: CGPoint(x: snapshot.frame.midX, y: snapshot.frame.midY),
            in: snapshot
        )
        self.activeSourceRect = initialSourceRect
        self.latestSourceRect = initialSourceRect

        self.stream = SCStream(filter: filter, configuration: Self.configuration(for: snapshot, sourceRect: initialSourceRect), delegate: nil)

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

    func updateFocus(cursorGlobalPoint: CGPoint) {
        guard snapshot.frame.contains(cursorGlobalPoint) else {
            return
        }

        guard shouldRecenter(around: cursorGlobalPoint) else {
            return
        }

        pendingFocusPoint = cursorGlobalPoint
        scheduleConfigurationUpdateIfNeeded()
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

        let sourceRect = latestSourceRect
        let sourceGlobalRect = CaptureScreenTransform(captureFrame: snapshot.frame)
            .globalRect(fromLocalRect: sourceRect)
        let frame = LiveDesktopPreviewFrame(
            displayID: displayID,
            image: cgImage,
            sourceRect: sourceRect,
            sourceGlobalRect: sourceGlobalRect
        )
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

    private func shouldRecenter(around cursorGlobalPoint: CGPoint) -> Bool {
        let cursorLocalPoint = CaptureScreenTransform(captureFrame: snapshot.frame)
            .localPoint(fromGlobalPoint: cursorGlobalPoint)
        let safeRect = activeSourceRect.insetBy(
            dx: activeSourceRect.width * Self.recenterThresholdFraction,
            dy: activeSourceRect.height * Self.recenterThresholdFraction
        )
        return !safeRect.contains(cursorLocalPoint)
    }

    private func scheduleConfigurationUpdateIfNeeded() {
        guard !isConfigurationUpdateInFlight,
              let focusPoint = pendingFocusPoint else {
            return
        }

        pendingFocusPoint = nil
        isConfigurationUpdateInFlight = true

        let sourceRect = Self.centeredSourceRect(around: focusPoint, in: snapshot)
        let previousSourceRect = activeSourceRect
        activeSourceRect = sourceRect
        let configuration = Self.configuration(for: snapshot, sourceRect: sourceRect)

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                try await stream.updateConfiguration(configuration)
                self.latestSourceRect = sourceRect
            } catch {
                self.activeSourceRect = previousSourceRect
                // Keep the previous live frame and allow future cursor moves to retry.
            }

            self.isConfigurationUpdateInFlight = false
            if self.pendingFocusPoint != nil {
                self.scheduleConfigurationUpdateIfNeeded()
            }
        }
    }

    private static func configuration(for snapshot: DisplaySnapshot, sourceRect: CGRect) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = max(Int((sourceRect.width * snapshot.scale).rounded(.up)), 1)
        configuration.height = max(Int((sourceRect.height * snapshot.scale).rounded(.up)), 1)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 1
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.captureDynamicRange = .SDR
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        return configuration
    }

    nonisolated static func centeredSourceRect(around cursorGlobalPoint: CGPoint, in snapshot: DisplaySnapshot) -> CGRect {
        LiveDesktopPreviewRegionGeometry.centeredSourceRect(
            around: cursorGlobalPoint,
            in: snapshot,
            preferredSideLength: regionLogicalSize
        )
    }
}

nonisolated struct LiveDesktopPreviewRegionGeometry {
    static func centeredSourceRect(
        around cursorGlobalPoint: CGPoint,
        in snapshot: DisplaySnapshot,
        preferredSideLength: CGFloat
    ) -> CGRect {
        let displayBounds = CGRect(origin: .zero, size: snapshot.frame.size)
        let localPoint = CaptureScreenTransform(captureFrame: snapshot.frame)
            .localPoint(fromGlobalPoint: cursorGlobalPoint)
        let side = min(max(preferredSideLength, 1), max(displayBounds.width, displayBounds.height))
        let size = CGSize(width: min(side, displayBounds.width), height: min(side, displayBounds.height))
        let origin = CGPoint(
            x: min(max(localPoint.x - size.width / 2, displayBounds.minX), displayBounds.maxX - size.width),
            y: min(max(localPoint.y - size.height / 2, displayBounds.minY), displayBounds.maxY - size.height)
        )
        return CGRect(origin: origin, size: size).gscIntegralStandardized
    }

    static func appKitSourceRect(
        fromOverlayLocalRect overlayLocalRect: CGRect,
        display: DisplaySnapshot,
        frame: LiveDesktopPreviewFrame
    ) -> CGRect? {
        let captureRect = display.captureDisplayTransform.captureGlobalRect(fromOverlayLocalRect: overlayLocalRect)
        let intersection = captureRect.intersection(frame.sourceGlobalRect).gscIntegralStandardized

        guard intersection.width > 0, intersection.height > 0 else {
            return nil
        }

        let scaleX = CGFloat(frame.image.width) / max(frame.sourceGlobalRect.width, 1)
        let scaleY = CGFloat(frame.image.height) / max(frame.sourceGlobalRect.height, 1)
        let topLeftRect = CGRect(
            x: (intersection.minX - frame.sourceGlobalRect.minX) * scaleX,
            y: (intersection.minY - frame.sourceGlobalRect.minY) * scaleY,
            width: intersection.width * scaleX,
            height: intersection.height * scaleY
        ).integral

        return CGRect(
            x: topLeftRect.minX,
            y: CGFloat(frame.image.height) - topLeftRect.maxY,
            width: topLeftRect.width,
            height: topLeftRect.height
        ).gscIntegralStandardized
    }
}
