import CoreGraphics
import Foundation

/// Observes user-driven scrolling using screen frames only. It deliberately has
/// no Accessibility dependency, event tap, cursor warp, or synthesized input.
struct ManualScrollingCaptureService {
    private static let pollingInterval: UInt64 = 16_000_000

    let captureService: any ScreenCaptureServiceType
    var scheduler: any Scheduling = SystemScheduler()
    var clock: any ClockProviding = SystemClock()
    var stitcher = ScrollingStitcher()

    static func resolveTarget(for request: ScrollingCaptureRequest) -> ScrollingCaptureTarget {
        ScrollingCaptureTarget(sourceName: "Scrolling Content", viewportRect: request.viewportRect, mode: .manual)
    }

    func capture(
        request: ScrollingCaptureRequest,
        cancellation: ScrollingCaptureCancellation,
        progressHandler: (@MainActor (ScrollingCaptureProgress) -> Void)? = nil
    ) async throws -> ScrollingCaptureResult {
        try cancellation.checkCancellation()
        guard request.viewportRect.gscIsFinite,
              request.viewportRect.width > 8, request.viewportRect.height > 8 else {
            throw ScrollingCaptureError.invalidViewport
        }
        let session = try await captureService.makeScrollingFrameSession(in: request.viewportRect)
        do {
            let result = try await capture(request: request, session: session, cancellation: cancellation, progressHandler: progressHandler)
            await session?.stop()
            try cancellation.checkCancellation()
            return result
        } catch {
            await session?.stop()
            throw error
        }
    }

    private func capture(
        request: ScrollingCaptureRequest, session: (any ScrollingFrameSession)?,
        cancellation: ScrollingCaptureCancellation,
        progressHandler: (@MainActor (ScrollingCaptureProgress) -> Void)?
    ) async throws -> ScrollingCaptureResult {
        let first: CGImage
        if let session {
            var initial: CGImage?
            for _ in 0..<300 {
                try cancellation.checkCancellation()
                if let frame = try session.nextFrame() { initial = frame; break }
                try await scheduler.sleep(nanoseconds: Self.pollingInterval)
            }
            guard let initial else { throw ScrollingCaptureError.firstFrameUnavailable }
            first = initial
        } else {
            first = try await captureService.captureRegionWithinSingleDisplayDirect(in: request.viewportRect).image
        }
        try cancellation.checkCancellation()
        let maximumHeight = ScreenshotRasterBudget.maximumHeight(forWidth: first.width, requestedHeight: request.maxOutputHeight)
        guard maximumHeight > 0 else { throw ScrollingCaptureError.firstFrameUnavailable }
        var accumulator = try ManualScrollingAccumulator(first: first, maximumHeight: maximumHeight, stitcher: stitcher)
        var unmatched = false
        var warnings: [String] = []
        var lastPreviewHeight = accumulator.state.outputHeight
        var framesSincePreview = 0
        await publish(accumulator.state, warning: nil, progressHandler: progressHandler)

        do {
            while accumulator.state.outputHeight < maximumHeight && accumulator.state.segmentCount < request.maxSegmentCount {
                try cancellation.checkCancellation()
                let finishing = cancellation.shouldFinish()
                if finishing {
                    if session == nil { break }
                    await session?.stop()
                }
                let image: CGImage
                if let session {
                    guard let frame = try session.nextFrame() else {
                        if finishing { break }
                        try await scheduler.sleep(nanoseconds: Self.pollingInterval)
                        continue
                    }
                    image = frame
                } else {
                    // Fallback for capture platforms without streaming support.
                    try await scheduler.sleep(nanoseconds: Self.pollingInterval)
                    image = try await captureService.captureRegionWithinSingleDisplayDirect(in: request.viewportRect).image
                }
                try cancellation.checkCancellation()
                let (updated, outcome) = await accumulator.processing(image)
                try cancellation.checkCancellation()
                accumulator = updated
                framesSincePreview += 1
                if outcome == .lowConfidence {
                    if !unmatched {
                        await publish(accumulator.state, warning: "Looking for overlapping content…", progressHandler: progressHandler)
                    }
                    // Keep the last connected reference and keep observing. A
                    // temporary reflow, overscroll, or reversal is not completion.
                    unmatched = true
                } else {
                    let reconnected = unmatched
                    unmatched = false
                    // Preview generation must not delay every incoming frame.
                    if reconnected || framesSincePreview >= 4 || outcome == .reachedMaximumHeight {
                        if reconnected || lastPreviewHeight != accumulator.state.outputHeight {
                            await publish(accumulator.state, warning: nil, progressHandler: progressHandler)
                            lastPreviewHeight = accumulator.state.outputHeight
                        }
                        framesSincePreview = 0
                    }
                }
                if cancellation.shouldFinish() && session == nil { break }
            }
        } catch ScrollingCaptureError.cancelled {
            throw ScrollingCaptureError.cancelled
        } catch is CancellationError {
            throw ScrollingCaptureError.cancelled
        } catch {
            try cancellation.checkCancellation()
            throw try await interruption(accumulator.state, request: request, warnings: warnings, reason: error.localizedDescription)
        }
        if accumulator.state.outputHeight >= maximumHeight { warnings.append(Self.capacityWarning) }
        else if accumulator.state.segmentCount >= request.maxSegmentCount {
            warnings.append("The scrolling capture reached its segment limit and stopped early.")
        }
        if unmatched {
            warnings.append("Some content could not be connected to the capture. Only connected content was kept.")
        }
        try cancellation.checkCancellation()
        let captured = try await result(accumulator.state, request: request, warnings: warnings)
        try cancellation.checkCancellation()
        return captured
    }

    private static let capacityWarning = "The scrolling capture reached its image capacity and stopped early. Capture the remaining content separately."

    private func publish(
        _ state: ScrollingStitchState, warning: String?,
        progressHandler: (@MainActor (ScrollingCaptureProgress) -> Void)?
    ) async {
        let preview = await stitcher.makePreview(for: state)
        progressHandler?(ScrollingCaptureProgress(
            segmentCount: state.segmentCount, outputHeight: state.outputHeight,
            maxOutputHeight: state.maxOutputHeight, warning: warning, previewImage: preview
        ))
    }

    private func result(
        _ state: ScrollingStitchState, request: ScrollingCaptureRequest, warnings: [String]
    ) async throws -> ScrollingCaptureResult {
        guard let image = await stitcher.makeOutput(for: state) else { throw ScrollingCaptureError.stitchingFailed }
        return ScrollingCaptureResult(
            image: image, sourceViewportRect: request.viewportRect, sourceName: "Scrolling Content",
            capturedAt: clock.now(), warnings: warnings
        )
    }

    private func interruption(
        _ state: ScrollingStitchState, request: ScrollingCaptureRequest, warnings: [String], reason: String
    ) async throws -> ScrollingCaptureInterruptedError {
        ScrollingCaptureInterruptedError(
            partialResult: try await result(state, request: request, warnings: warnings + ["Capture stopped before you finished scrolling."]),
            reason: reason
        )
    }
}
