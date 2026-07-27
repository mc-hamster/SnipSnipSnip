import AppKit
import Foundation

@MainActor
extension CaptureWorkflowModel {
    func performScrollingCapture(
        in region: CGRect,
        isPrivateCapture: Bool,
        runOptions: CaptureRunOptions,
        completionContext: CaptureCompletionContext
    ) async throws {
        let cancellation = ScrollingCaptureCancellation()
        let progressOverlay = ScrollingCaptureProgressOverlay(
            onCancel: { cancellation.cancel() },
            onDone: { cancellation.finish() }
        )
        var progressOverlayShown = false
        defer { progressOverlay.close() }

        let service = dependencies.makeScrollingCaptureService(captureService)
        let result: ScrollingCaptureResult
        do {
            result = try await service.capture(
                request: ScrollingCaptureRequest(
                    viewportRect: region,
                    isPrivateCapture: isPrivateCapture
                ),
                cancellation: cancellation,
                progressHandler: { progress in
                    if !progressOverlayShown {
                        progressOverlay.show(avoiding: region)
                        progressOverlayShown = true
                    }

                    progressOverlay.update(
                        segmentCount: progress.segmentCount,
                        outputHeight: progress.outputHeight,
                        capacityFraction: progress.capacityFraction,
                        warning: progress.warning,
                        previewImage: progress.previewImage
                    )
                }
            )
        } catch let interruption as ScrollingCaptureInterruptedError {
            pendingScrollingPartialCapture = (interruption.partialResult, isPrivateCapture)
            throw interruption
        }

        try completeCapture(
            result.capturedScreenshot,
            request: .scrolling(region),
            isPrivateCapture: isPrivateCapture,
            runOptions: runOptions,
            completionContext: completionContext
        )
        showCapturedFeedback()

        if let warning = result.warnings.last {
            dependencies.lifecycle.presentError(warning)
        }
    }
}
