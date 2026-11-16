import CoreGraphics

/// Both selectors resolve identity and geometry from the same capture-space
/// metadata. AppKit input is converted once before the shared hit test.
nonisolated enum CaptureWindowTargetResolver {
    static func resolve(atCaptureGlobalPoint point: CGPoint, in windows: [CaptureWindowSummary]) -> CaptureWindowSummary? {
        gscTopmostWindow(at: point, in: windows)
    }

    static func resolve(
        atOverlayScreenPoint point: CGPoint,
        in windows: [CaptureWindowSummary],
        displayTransform: CaptureDisplayTransform
    ) -> CaptureWindowSummary? {
        resolve(atCaptureGlobalPoint: displayTransform.captureGlobalPoint(fromOverlayGlobalPoint: point), in: windows)
    }

    static func windows(_ windows: [CaptureWindowSummary], intersecting display: DisplaySnapshot) -> [CaptureWindowSummary] {
        windows.filter { $0.frame.intersects(display.frame) }
    }
}
