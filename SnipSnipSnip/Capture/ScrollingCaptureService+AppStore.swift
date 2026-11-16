#if APP_STORE_BUILD
import CoreGraphics
import Foundation

struct ScrollingCaptureService {
    var captureService: any ScreenCaptureServiceType
    let permissions: any CapturePermissionServicing
    var scheduler: any Scheduling = SystemScheduler()
    var clock: any ClockProviding = SystemClock()
    var stitcher = ScrollingStitcher()

    func resolveTarget(for request: ScrollingCaptureRequest) throws -> ScrollingCaptureTarget {
        guard request.viewportRect.width > 8, request.viewportRect.height > 8 else {
            throw ScrollingCaptureError.invalidViewport
        }
        guard request.mode == .manual else { throw ScrollingCaptureError.accessibilityPermissionDenied }
        return ManualScrollingCaptureService.resolveTarget(for: request)
    }

    func capture(
        request: ScrollingCaptureRequest,
        cancellation: ScrollingCaptureCancellation,
        progressHandler: (@MainActor (ScrollingCaptureProgress) -> Void)? = nil
    ) async throws -> ScrollingCaptureResult {
        try cancellation.checkCancellation()
        guard request.mode == .manual else { throw ScrollingCaptureError.accessibilityPermissionDenied }
        return try await CaptureContentDiagnostics.$current.withValue(
            CaptureContentDiagnostics(isPrivateCapture: request.isPrivateCapture)
        ) {
            try await ManualScrollingCaptureService(
                captureService: captureService, scheduler: scheduler, clock: clock, stitcher: stitcher
            ).capture(request: request, cancellation: cancellation, progressHandler: progressHandler)
        }
    }
}
#endif
