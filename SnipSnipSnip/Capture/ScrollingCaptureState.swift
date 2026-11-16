import CoreGraphics
import Foundation

enum ScrollingCaptureError: LocalizedError {
    case accessibilityPermissionDenied
    case invalidViewport
    case noScrollableTarget
    case firstFrameUnavailable
    case stitchingFailed
    case contentDidNotSettle
    case cancelled

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionDenied:
            #if APP_STORE_BUILD
            return "Auto Scroll is unavailable in this edition. Use Manual Scroll to capture while you scroll."
            #else
            return "Auto Scroll needs Accessibility access so \(AppBranding.displayName) can scroll the selected app while capturing."
            #endif
        case .invalidViewport:
            return "The selected scrolling area was too small to capture."
        case .noScrollableTarget:
            return "No scrollable area was found at the selected location. Select inside a scrollable page, document, or list and try again."
        case .firstFrameUnavailable:
            return "The first scrolling capture frame could not be captured."
        case .stitchingFailed:
            return "\(AppBranding.displayName) could not stitch the scrolling capture with enough confidence."
        case .contentDidNotSettle:
            return "The content kept moving while it was being captured. Pause animations or use Manual Scroll with smaller movements."
        case .cancelled:
            return "Scrolling capture was cancelled."
        }
    }
}

nonisolated final class ScrollingCaptureCancellation: @unchecked Sendable {
    private enum RequestedAction {
        case none
        case cancel
        case finish
    }

    private let lock = NSLock()
    private var requestedAction = RequestedAction.none

    func cancel() {
        lock.lock()
        requestedAction = .cancel
        lock.unlock()
    }

    func finish() {
        lock.lock()
        if requestedAction == .none {
            requestedAction = .finish
        }
        lock.unlock()
    }

    func checkCancellation() throws {
        lock.lock()
        let action = requestedAction
        lock.unlock()

        if action == .cancel || Task.isCancelled {
            throw ScrollingCaptureError.cancelled
        }
    }

    func shouldFinish() -> Bool {
        lock.lock()
        let action = requestedAction
        lock.unlock()

        return action == .finish
    }
}

struct ScrollingCaptureProgress: @unchecked Sendable {
    let segmentCount: Int
    let outputHeight: Int
    let maxOutputHeight: Int
    let warning: String?
    let previewImage: CGImage?
    var scrollTargetPoint: CGPoint? = nil

    /// Fraction of the maximum capture capacity consumed, clamped to 0…1.
    var capacityFraction: Double {
        guard maxOutputHeight > 0 else { return 0 }
        return min(Double(outputHeight) / Double(maxOutputHeight), 1.0)
    }
}
