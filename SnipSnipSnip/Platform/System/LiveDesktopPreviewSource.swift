import AppKit

@MainActor
final class LiveDesktopPreviewSource {
    typealias Observer = @MainActor () -> Void
    private static let cropLogicalSize: CGFloat = 20
    private static let minimumCaptureIntervalNanoseconds: UInt64 = 120_000_000

    private var latestFramesByDisplayID: [CGDirectDisplayID: LiveDesktopPreviewFrame] = [:]
    private var observersByDisplayID: [CGDirectDisplayID: [UUID: Observer]] = [:]
    private var pendingRequest: LiveDesktopPreviewCaptureRequest?
    private var focusRevision: UInt64 = 0
    private var completedRevision: UInt64 = 0
    private var lastCaptureStartNanoseconds: UInt64?
    private var captureTask: Task<Void, Never>?
    private var isRunning = false
    private let displaysByID: [CGDirectDisplayID: DisplaySnapshot]
    private let capturePlatform: any ScreenCapturePlatform

    init(
        displays: [DisplaySnapshot],
        initialFocusPoint: CGPoint? = nil,
        capturePlatform: any ScreenCapturePlatform = LiveScreenCapturePlatform()
    ) {
        self.displaysByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.displayID, $0) })
        self.capturePlatform = capturePlatform
        if let initialFocusPoint,
           let display = displays.first(where: { $0.frame.contains(initialFocusPoint) }),
           let request = Self.captureRequest(around: initialFocusPoint, in: display) {
            pendingRequest = request
            focusRevision = 1
        }
    }

    func start() {
        guard !displaysByID.isEmpty, !isRunning else {
            return
        }

        isRunning = true
        scheduleCaptureIfNeeded()
    }

    func stop() async {
        isRunning = false
        let task = captureTask
        captureTask = nil
        task?.cancel()
        await task?.value

        latestFramesByDisplayID.removeAll()
        pendingRequest = nil
        focusRevision = 0
        completedRevision = 0
        lastCaptureStartNanoseconds = nil
    }

    func updateFocus(displayID: CGDirectDisplayID, cursorGlobalPoint: CGPoint) {
        guard let display = displaysByID[displayID],
              let request = Self.captureRequest(around: cursorGlobalPoint, in: display),
              request != pendingRequest else {
            return
        }

        pendingRequest = request
        focusRevision &+= 1
        scheduleCaptureIfNeeded()
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

    private static func captureRequest(
        around point: CGPoint,
        in display: DisplaySnapshot
    ) -> LiveDesktopPreviewCaptureRequest? {
        LiveDesktopPreviewRegionGeometry.captureRequest(
            around: point,
            in: display,
            cropLogicalSize: cropLogicalSize
        )
    }

    private func scheduleCaptureIfNeeded() {
        guard isRunning,
              pendingRequest != nil,
              completedRevision != focusRevision,
              captureTask == nil else {
            return
        }

        captureTask = Task { @MainActor [weak self] in
            await self?.drainPendingCaptures()
        }
    }

    private func drainPendingCaptures() async {
        defer { captureTask = nil }

        while isRunning, completedRevision != focusRevision {
            await waitForCaptureRateLimit()

            guard isRunning, !Task.isCancelled, let request = pendingRequest else {
                return
            }

            let requestRevision = focusRevision
            lastCaptureStartNanoseconds = DispatchTime.now().uptimeNanoseconds

            do {
                let image = try await captureImage(for: request)
                guard isRunning, !Task.isCancelled else {
                    return
                }

                completedRevision = requestRevision
                store(
                    frame: LiveDesktopPreviewFrame(
                        displayID: request.displayID,
                        image: image,
                        sourceGlobalRect: request.sourceGlobalRect
                    )
                )
            } catch is CancellationError {
                return
            } catch {
                // A new cursor position will retry. The draw path keeps the last live frame or
                // falls back to the original desktop snapshot while the pointer is stationary.
                completedRevision = requestRevision
            }
        }
    }

    private func waitForCaptureRateLimit() async {
        guard let lastCaptureStartNanoseconds else {
            return
        }

        let now = DispatchTime.now().uptimeNanoseconds
        let nextAllowedCapture = lastCaptureStartNanoseconds &+ Self.minimumCaptureIntervalNanoseconds
        guard now < nextAllowedCapture else {
            return
        }

        try? await Task.sleep(nanoseconds: nextAllowedCapture - now)
    }

    private func captureImage(for request: LiveDesktopPreviewCaptureRequest) async throws -> CGImage {
        try await capturePlatform.captureScreenshot(
            ScreenCaptureRequest(
                target: .screenRect(request.sourceGlobalRect),
                configuration: ScreenCaptureConfiguration(
                    width: Int(request.outputPixelSize.width.rounded(.up)),
                    height: Int(request.outputPixelSize.height.rounded(.up)),
                    showsCursor: false
                )
            )
        )
    }
}

nonisolated struct LiveDesktopPreviewFrame: @unchecked Sendable {
    let displayID: CGDirectDisplayID
    let image: CGImage
    let sourceGlobalRect: CGRect
}

nonisolated struct LiveDesktopPreviewCaptureRequest: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let sourceRect: CGRect
    let sourceGlobalRect: CGRect
    let outputPixelSize: CGSize
}

nonisolated struct LiveDesktopPreviewRegionGeometry {
    static func captureRequest(
        around cursorGlobalPoint: CGPoint,
        in snapshot: DisplaySnapshot,
        cropLogicalSize: CGFloat
    ) -> LiveDesktopPreviewCaptureRequest? {
        guard snapshot.frame.contains(cursorGlobalPoint) else {
            return nil
        }

        let localPoint = snapshot.captureDisplayTransform.overlayLocalPoint(fromCaptureGlobalPoint: cursorGlobalPoint)
        let overlayCropRect = gscCenteredCropRect(
            around: localPoint,
            size: cropLogicalSize,
            within: CGRect(origin: .zero, size: snapshot.overlayFrame.size)
        )
        let sourceGlobalRect = snapshot.captureDisplayTransform
            .captureGlobalRect(fromOverlayLocalRect: overlayCropRect)
            .intersection(snapshot.frame)
            .gscIntegralStandardized

        guard sourceGlobalRect.width > 0,
              sourceGlobalRect.height > 0 else {
            return nil
        }

        let sourceRect = CaptureScreenTransform(captureFrame: snapshot.frame)
            .localRect(fromGlobalRect: sourceGlobalRect)
        let outputPixelSize = CGSize(
            width: max((sourceRect.width * snapshot.scale).rounded(.up), 1),
            height: max((sourceRect.height * snapshot.scale).rounded(.up), 1)
        )

        return LiveDesktopPreviewCaptureRequest(
            displayID: snapshot.displayID,
            sourceRect: sourceRect,
            sourceGlobalRect: sourceGlobalRect,
            outputPixelSize: outputPixelSize
        )
    }

    static func appKitSourceRect(
        fromOverlayLocalRect overlayLocalRect: CGRect,
        display: DisplaySnapshot,
        frame: LiveDesktopPreviewFrame
    ) -> CGRect? {
        let captureRect = display.captureDisplayTransform
            .captureGlobalRect(fromOverlayLocalRect: overlayLocalRect)
            .intersection(display.frame)
            .gscIntegralStandardized

        guard captureRect.width > 0,
              captureRect.height > 0,
              frame.sourceGlobalRect.contains(captureRect) else {
            return nil
        }

        let scaleX = CGFloat(frame.image.width) / max(frame.sourceGlobalRect.width, 1)
        let scaleY = CGFloat(frame.image.height) / max(frame.sourceGlobalRect.height, 1)
        let topLeftRect = CGRect(
            x: (captureRect.minX - frame.sourceGlobalRect.minX) * scaleX,
            y: (captureRect.minY - frame.sourceGlobalRect.minY) * scaleY,
            width: captureRect.width * scaleX,
            height: captureRect.height * scaleY
        ).integral

        return CGRect(
            x: topLeftRect.minX,
            y: CGFloat(frame.image.height) - topLeftRect.maxY,
            width: topLeftRect.width,
            height: topLeftRect.height
        ).gscIntegralStandardized
    }
}
