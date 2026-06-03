import CoreGraphics

nonisolated struct EditorViewport: Equatable {
    static let fitZoomScale: CGFloat = 1
    static let minZoomScale: CGFloat = 0.1
    static let maxZoomScale: CGFloat = 16
    static let maxInitialDisplayScale: CGFloat = 1.0
    static let interactionInset: CGFloat = 20

    var canvasSize: CGSize = .zero
    var contentSize: CGSize = .zero
    var zoomScale: CGFloat = fitZoomScale
    var offset: CGSize = .zero

    var fitScale: CGFloat {
        let effectiveCanvasSize = effectiveCanvasSize

        guard effectiveCanvasSize.width > 0,
              effectiveCanvasSize.height > 0,
              contentSize.width > 0,
              contentSize.height > 0
        else {
            return 1
        }

        return min(effectiveCanvasSize.width / contentSize.width, effectiveCanvasSize.height / contentSize.height)
    }

    var displayScale: CGFloat {
        fitScale * zoomScale
    }

    var zoomPercentage: Int {
        Int((displayScale * 100).rounded())
    }

    var imageRect: CGRect {
        rect(for: zoomScale, offset: offset)
    }

    var canZoomIn: Bool {
        zoomScale < Self.maxZoomScale
    }

    var canZoomOut: Bool {
        zoomScale > Self.minZoomScale
    }

    var actualSizeZoomScale: CGFloat {
        let fitScale = fitScale

        guard fitScale > 0 else {
            return Self.fitZoomScale
        }

        return clampedZoomScale(1 / fitScale)
    }

    var canScrollHorizontally: Bool {
        maxHorizontalOffset > 0
    }

    var canScrollVertically: Bool {
        maxVerticalOffset > 0
    }

    var horizontalScrollPosition: CGFloat {
        guard maxHorizontalOffset > 0 else {
            return 0.5
        }

        return (offset.width + maxHorizontalOffset) / (maxHorizontalOffset * 2)
    }

    var verticalScrollPosition: CGFloat {
        guard maxVerticalOffset > 0 else {
            return 0.5
        }

        return (offset.height + maxVerticalOffset) / (maxVerticalOffset * 2)
    }

    var horizontalScrollKnobProportion: CGFloat {
        scrollKnobProportion(visibleLength: canvasSize.width, contentLength: displayedContentSize(for: zoomScale).width)
    }

    var verticalScrollKnobProportion: CGFloat {
        scrollKnobProportion(visibleLength: canvasSize.height, contentLength: displayedContentSize(for: zoomScale).height)
    }

    func updatingCanvasSize(_ size: CGSize, maxInitialDisplayScale: CGFloat? = nil) -> EditorViewport {
        var updated = self
        let previousCanvasSize = updated.canvasSize
        updated.canvasSize = size

        if let maxInitialDisplayScale,
           previousCanvasSize == .zero,
           updated.zoomScale == Self.fitZoomScale,
           updated.offset == .zero {
            updated.zoomScale = updated.cappedInitialZoomScale(maxDisplayScale: maxInitialDisplayScale)
        }

        updated.offset = updated.clampedOffset(updated.offset)
        return updated
    }

    func updatingContentSize(_ size: CGSize, fitToWindow: Bool) -> EditorViewport {
        var updated = self
        updated.contentSize = size

        if fitToWindow {
            updated.zoomScale = Self.fitZoomScale
            updated.offset = .zero
        } else {
            updated.offset = updated.clampedOffset(updated.offset)
        }

        return updated
    }

    func zoomedToFit() -> EditorViewport {
        var updated = self
        updated.zoomScale = Self.fitZoomScale
        updated.offset = .zero
        return updated
    }

    func focused(on contentRect: CGRect) -> EditorViewport {
        let rect = contentRect.standardized.integral
        let effectiveCanvasSize = effectiveCanvasSize

        guard rect.width > 0,
              rect.height > 0,
              effectiveCanvasSize.width > 0,
              effectiveCanvasSize.height > 0,
              contentSize.width > 0,
              contentSize.height > 0
        else {
            return zoomedToFit()
        }

        let targetDisplayScale = min(
            effectiveCanvasSize.width / rect.width,
            effectiveCanvasSize.height / rect.height
        )
        let targetZoomScale = clampedZoomScale(targetDisplayScale / fitScale)
        let displayedSize = displayedContentSize(for: targetZoomScale)
        let centeredOrigin = centeredOrigin(for: displayedSize)
        let cropDisplayedSize = CGSize(width: rect.width * targetDisplayScale, height: rect.height * targetDisplayScale)
        let targetCropOrigin = CGPoint(
            x: Self.interactionInset + (effectiveCanvasSize.width - cropDisplayedSize.width) / 2,
            y: Self.interactionInset + (effectiveCanvasSize.height - cropDisplayedSize.height) / 2
        )
        let imageOrigin = CGPoint(
            x: targetCropOrigin.x - rect.minX * targetDisplayScale,
            y: targetCropOrigin.y - rect.minY * targetDisplayScale
        )

        var updated = self
        updated.zoomScale = targetZoomScale
        updated.offset = updated.clampedOffset(
            CGSize(
                width: imageOrigin.x - centeredOrigin.x,
                height: imageOrigin.y - centeredOrigin.y
            ),
            zoomScale: targetZoomScale
        )
        return updated
    }

    func zoomedForInitialDisplay(maxDisplayScale: CGFloat) -> EditorViewport {
        var updated = self
        updated.zoomScale = updated.cappedInitialZoomScale(maxDisplayScale: maxDisplayScale)
        updated.offset = .zero
        return updated
    }

    func zoomed(to requestedZoomScale: CGFloat, anchoredAt anchor: CGPoint? = nil) -> EditorViewport {
        let clampedZoomScale = clampedZoomScale(requestedZoomScale)

        guard clampedZoomScale != zoomScale else {
            return self
        }

        var updated = self
        let previousRect = imageRect
        updated.zoomScale = clampedZoomScale

        guard let anchor,
              previousRect.width > 0,
              previousRect.height > 0,
              canvasSize.width > 0,
              canvasSize.height > 0
        else {
            updated.offset = updated.clampedOffset(offset)
            return updated
        }

        let relativeX = (anchor.x - previousRect.minX) / previousRect.width
        let relativeY = (anchor.y - previousRect.minY) / previousRect.height
        let displayedSize = updated.displayedContentSize(for: clampedZoomScale)
        let centeredOrigin = updated.centeredOrigin(for: displayedSize)
        let anchoredOrigin = CGPoint(
            x: anchor.x - relativeX * displayedSize.width,
            y: anchor.y - relativeY * displayedSize.height
        )

        updated.offset = updated.clampedOffset(
            CGSize(
                width: anchoredOrigin.x - centeredOrigin.x,
                height: anchoredOrigin.y - centeredOrigin.y
            ),
            zoomScale: clampedZoomScale
        )
        return updated
    }

    func panned(by delta: CGSize) -> EditorViewport {
        var updated = self
        updated.offset = updated.clampedOffset(
            CGSize(width: offset.width + delta.width, height: offset.height + delta.height)
        )
        return updated
    }

    func scrolledTo(horizontalPosition: CGFloat? = nil, verticalPosition: CGFloat? = nil) -> EditorViewport {
        var updated = self
        var resolvedOffset = offset

        if let horizontalPosition, maxHorizontalOffset > 0 {
            let clampedPosition = min(max(horizontalPosition, 0), 1)
            resolvedOffset.width = (clampedPosition * 2 - 1) * maxHorizontalOffset
        }

        if let verticalPosition, maxVerticalOffset > 0 {
            let clampedPosition = min(max(verticalPosition, 0), 1)
            resolvedOffset.height = (clampedPosition * 2 - 1) * maxVerticalOffset
        }

        updated.offset = updated.clampedOffset(resolvedOffset)
        return updated
    }

    private func clampedZoomScale(_ value: CGFloat) -> CGFloat {
        min(max(value, Self.minZoomScale), Self.maxZoomScale)
    }

    private func cappedInitialZoomScale(maxDisplayScale: CGFloat) -> CGFloat {
        guard fitScale > 0 else {
            return Self.fitZoomScale
        }

        return clampedZoomScale(min(fitScale, maxDisplayScale) / fitScale)
    }

    private func rect(for zoomScale: CGFloat, offset: CGSize) -> CGRect {
        let displayedSize = displayedContentSize(for: zoomScale)
        let centeredOrigin = centeredOrigin(for: displayedSize)

        return CGRect(
            x: centeredOrigin.x + offset.width,
            y: centeredOrigin.y + offset.height,
            width: displayedSize.width,
            height: displayedSize.height
        )
    }

    private func displayedContentSize(for zoomScale: CGFloat) -> CGSize {
        let displayScale = fitScale * zoomScale

        return CGSize(
            width: contentSize.width * displayScale,
            height: contentSize.height * displayScale
        )
    }

    private func centeredOrigin(for displayedSize: CGSize) -> CGPoint {
        let effectiveCanvasSize = effectiveCanvasSize
        return CGPoint(
            x: (effectiveCanvasSize.width - displayedSize.width) / 2 + Self.interactionInset,
            y: (effectiveCanvasSize.height - displayedSize.height) / 2 + Self.interactionInset
        )
    }

    private func clampedOffset(_ offset: CGSize, zoomScale: CGFloat? = nil) -> CGSize {
        let effectiveCanvasSize = effectiveCanvasSize

        guard effectiveCanvasSize.width > 0,
              effectiveCanvasSize.height > 0,
              contentSize.width > 0,
              contentSize.height > 0
        else {
            return .zero
        }

        let displayedSize = displayedContentSize(for: zoomScale ?? self.zoomScale)
        let maxHorizontalOffset = max((displayedSize.width - effectiveCanvasSize.width) / 2, 0)
        let maxVerticalOffset = max((displayedSize.height - effectiveCanvasSize.height) / 2, 0)

        return CGSize(
            width: maxHorizontalOffset > 0 ? min(max(offset.width, -maxHorizontalOffset), maxHorizontalOffset) : 0,
            height: maxVerticalOffset > 0 ? min(max(offset.height, -maxVerticalOffset), maxVerticalOffset) : 0
        )
    }

    private var maxHorizontalOffset: CGFloat {
        let effectiveCanvasSize = effectiveCanvasSize

        guard effectiveCanvasSize.width > 0,
              contentSize.width > 0
        else {
            return 0
        }

        return max((displayedContentSize(for: zoomScale).width - effectiveCanvasSize.width) / 2, 0)
    }

    private var maxVerticalOffset: CGFloat {
        let effectiveCanvasSize = effectiveCanvasSize

        guard effectiveCanvasSize.height > 0,
              contentSize.height > 0
        else {
            return 0
        }

        return max((displayedContentSize(for: zoomScale).height - effectiveCanvasSize.height) / 2, 0)
    }

    private var effectiveCanvasSize: CGSize {
        CGSize(
            width: max(canvasSize.width - Self.interactionInset * 2, 1),
            height: max(canvasSize.height - Self.interactionInset * 2, 1)
        )
    }

    private func scrollKnobProportion(visibleLength: CGFloat, contentLength: CGFloat) -> CGFloat {
        guard visibleLength > 0, contentLength > 0 else {
            return 1
        }

        return min(max(visibleLength / contentLength, 0.08), 1)
    }
}
