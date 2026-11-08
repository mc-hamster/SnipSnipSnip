import CoreGraphics

/// Normalized source coordinates, top-left/y-down. Shared by export and target editing.
nonisolated struct VideoZoomGeometry: Equatable, Sendable {
    enum FocusSource: Equatable, Sendable { case fixed, cursor, fallback }
    let scale: Double
    let center: VideoPoint
    let focusSource: FocusSource

    var sourceRect: CGRect {
        let side = 1 / scale
        return CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
    }

    static func resolve(_ zoom: VideoZoom, at time: Double, interactions: VideoInteractionTrack?, atFullMagnification: Bool = false) -> Self {
        let amount = atFullMagnification ? 1 : zoom.amount(at: time)
        let scale = 1 + (zoom.scale - 1) * amount
        let cursor = zoom.followsCursor ? interactions?.cursor(at: time, smooth: true) : nil
        let focus = cursor ?? zoom.center
        let half = 0.5 / scale
        let boundedFocus = VideoPoint(x: min(max(focus.x, half), 1 - half), y: min(max(focus.y, half), 1 - half))
        return Self(scale: scale, center: VideoPoint.center.interpolated(to: boundedFocus, fraction: amount),
                    focusSource: cursor != nil ? .cursor : (zoom.followsCursor ? .fallback : .fixed))
    }

    func rect(in contentRect: CGRect) -> CGRect {
        let source = sourceRect
        return CGRect(x: contentRect.minX + source.minX * contentRect.width,
                      y: contentRect.minY + source.minY * contentRect.height,
                      width: source.width * contentRect.width, height: source.height * contentRect.height)
    }

    static func point(at location: CGPoint, in contentRect: CGRect) -> VideoPoint? {
        guard contentRect.width > 0, contentRect.height > 0,
              location.x.isFinite, location.y.isFinite else { return nil }
        return VideoPoint(x: (location.x - contentRect.minX) / contentRect.width,
                          y: (location.y - contentRect.minY) / contentRect.height).clamped
    }
}
