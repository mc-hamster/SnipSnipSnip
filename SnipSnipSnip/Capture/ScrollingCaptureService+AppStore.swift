#if APP_STORE_BUILD
import CoreGraphics
import Foundation

enum ScrollingCaptureError: LocalizedError {
    case accessibilityPermissionDenied
    case invalidViewport
    case noScrollableTarget
    case firstFrameUnavailable
    case stitchingFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionDenied:
            return "Scrolling Capture is unavailable in this build."
        case .invalidViewport:
            return "The selected scrolling area was too small to capture."
        case .noScrollableTarget:
            return "No scrollable area was found at the selected location."
        case .firstFrameUnavailable:
            return "The first scrolling capture frame could not be captured."
        case .stitchingFailed:
            return "SnipSnipSnip could not stitch the scrolling capture with enough confidence."
        case .cancelled:
            return "Scrolling capture was cancelled."
        }
    }
}

final class ScrollingCaptureCancellation: @unchecked Sendable {
    func cancel() {}
    func finish() {}
}

struct ScrollingCaptureProgress: Equatable, Sendable {
    let segmentCount: Int
    let outputHeight: Int
    let maxOutputHeight: Int
    let warning: String?

    var capacityFraction: Double {
        guard maxOutputHeight > 0 else { return 0 }
        return min(Double(outputHeight) / Double(maxOutputHeight), 1.0)
    }
}

struct ScrollingCaptureService {
    var captureService: any ScreenCaptureServiceType = ScreenCaptureService()

    func capture(
        request: ScrollingCaptureRequest,
        cancellation: ScrollingCaptureCancellation,
        progressHandler: (@MainActor (ScrollingCaptureProgress) -> Void)? = nil
    ) async throws -> ScrollingCaptureResult {
        _ = request
        _ = cancellation
        _ = progressHandler
        throw ScrollingCaptureError.accessibilityPermissionDenied
    }
}
#endif