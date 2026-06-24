import AppKit
@preconcurrency import ScreenCaptureKit

@MainActor
final class LiveDesktopPreviewSource {
    typealias Observer = @MainActor () -> Void
    private static let cropLogicalSize: CGFloat = 20
    private static let refreshIntervalNanoseconds: UInt64 = 66_666_667

    private var latestFramesByDisplayID: [CGDirectDisplayID: LiveDesktopPreviewFrame] = [:]
    private var observersByDisplayID: [CGDirectDisplayID: [UUID: Observer]] = [:]
    private var focusedPointByDisplayID: [CGDirectDisplayID: CGPoint] = [:]
    private var activeDisplayID: CGDirectDisplayID?
    private var refreshTask: Task<Void, Never>?
    private var isCaptureInFlight = false
    private let displaysByID: [CGDirectDisplayID: DisplaySnapshot]

    init(displays: [DisplaySnapshot], initialFocusPoint: CGPoint? = nil) {
        self.displaysByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.displayID, $0) })
        if let initialFocusPoint,
           let display = displays.first(where: { $0.frame.contains(initialFocusPoint) }) {
            self.activeDisplayID = display.displayID
            self.focusedPointByDisplayID[display.displayID] = initialFocusPoint
        }
    }

    func start() {
        guard !displaysByID.isEmpty, refreshTask == nil else {
            return
        }

        refreshTask = Task { @MainActor [weak self] in
            await self?.captureFocusedRegionIfNeeded()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.refreshIntervalNanoseconds)
                await self?.captureFocusedRegionIfNeeded()
            }
        }
    }

    func stop() async {
        refreshTask?.cancel()
        refreshTask = nil
        latestFramesByDisplayID.removeAll()
        focusedPointByDisplayID.removeAll()
        activeDisplayID = nil
        isCaptureInFlight = false
    }

    func updateFocus(displayID: CGDirectDisplayID, cursorGlobalPoint: CGPoint) {
        guard displaysByID[displayID]?.frame.contains(cursorGlobalPoint) == true else {
            return
        }

        activeDisplayID = displayID
        focusedPointByDisplayID[displayID] = cursorGlobalPoint

        if refreshTask != nil {
            Task { @MainActor [weak self] in
                await self?.captureFocusedRegionIfNeeded()
            }
        }
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

    private func captureFocusedRegionIfNeeded() async {
        guard !isCaptureInFlight,
              let activeDisplayID,
              let display = displaysByID[activeDisplayID],
              let focusedPoint = focusedPointByDisplayID[activeDisplayID],
              let request = LiveDesktopPreviewRegionGeometry.captureRequest(
                around: focusedPoint,
                in: display,
                cropLogicalSize: Self.cropLogicalSize
              ) else {
            return
        }

        isCaptureInFlight = true
        defer {
            isCaptureInFlight = false
        }

        do {
            let image = try await Self.captureImage(for: request)
            guard refreshTask != nil else {
                return
            }

            store(
                frame: LiveDesktopPreviewFrame(
                    displayID: request.displayID,
                    image: image,
                    sourceGlobalRect: request.sourceGlobalRect
                )
            )
        } catch {
            // Keep the last usable live frame. The loupe draw path can still fall back to the
            // original desktop snapshot if no current capture is available.
        }
    }

    nonisolated private static func captureImage(for request: LiveDesktopPreviewCaptureRequest) async throws -> CGImage {
        let configuration = SCScreenshotConfiguration()
        configuration.width = max(Int(request.outputPixelSize.width.rounded(.up)), 1)
        configuration.height = max(Int(request.outputPixelSize.height.rounded(.up)), 1)
        configuration.showsCursor = false
        configuration.dynamicRange = .sdr

        return try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureScreenshot(rect: request.sourceGlobalRect, configuration: configuration) { output, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let image = output?.sdrImage else {
                    continuation.resume(throwing: ScreenCapturePlatformError.imageUnavailable)
                    return
                }

                continuation.resume(returning: image)
            }
        }
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
