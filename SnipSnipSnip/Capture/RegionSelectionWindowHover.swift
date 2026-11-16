import AppKit

nonisolated struct RegionSelectionWindowHover: Equatable {
    let window: CaptureWindowSummary

    static func resolve(
        at cursorGlobalPoint: CGPoint?,
        in windows: [CaptureWindowSummary],
        selectionRect: CGRect?,
        isInteracting: Bool
    ) -> Self? {
        guard selectionRect == nil, !isInteracting, let cursorGlobalPoint,
              let window = CaptureWindowTargetResolver.resolve(atCaptureGlobalPoint: cursorGlobalPoint, in: windows) else {
            return nil
        }
        return Self(window: window)
    }

    func localOutlineRect(on display: DisplaySnapshot) -> CGRect? {
        guard window.frame.intersects(display.frame) else { return nil }
        // Transform the full window before clipping in the view. A window spanning
        // displays must not acquire a false border at the seam between them.
        return display.captureDisplayTransform.overlayLocalRect(fromCaptureGlobalRect: window.frame)
    }
}
