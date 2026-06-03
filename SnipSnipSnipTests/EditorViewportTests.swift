import CoreGraphics
import XCTest
@testable import SnipSnipSnip

final class EditorViewportTests: XCTestCase {
    func testZoomedViewportKeepsAnchorStable() {
        let viewport = EditorViewport(
            canvasSize: CGSize(width: 1000, height: 800),
            contentSize: CGSize(width: 500, height: 400)
        )
        let anchor = CGPoint(x: 250, y: 220)
        let initialRect = viewport.imageRect
        let relativePoint = CGPoint(
            x: (anchor.x - initialRect.minX) / initialRect.width,
            y: (anchor.y - initialRect.minY) / initialRect.height
        )

        let zoomed = viewport.zoomed(to: 2, anchoredAt: anchor)
        let zoomedRect = zoomed.imageRect
        let anchoredPoint = CGPoint(
            x: zoomedRect.minX + relativePoint.x * zoomedRect.width,
            y: zoomedRect.minY + relativePoint.y * zoomedRect.height
        )

        XCTAssertEqual(anchoredPoint.x, anchor.x, accuracy: 0.001)
        XCTAssertEqual(anchoredPoint.y, anchor.y, accuracy: 0.001)
    }

    func testPanningClampsToVisibleBounds() {
        let viewport = EditorViewport(
            canvasSize: CGSize(width: 800, height: 600),
            contentSize: CGSize(width: 400, height: 300),
            zoomScale: 3
        )

        let panned = viewport.panned(by: CGSize(width: 1200, height: -1200))

        XCTAssertEqual(panned.offset.width, 740, accuracy: 0.001)
        XCTAssertEqual(panned.offset.height, -560, accuracy: 0.001)
    }

    func testScrollingMapsScrollerPositionsToViewportOffsets() {
        let viewport = EditorViewport(
            canvasSize: CGSize(width: 800, height: 600),
            contentSize: CGSize(width: 400, height: 300),
            zoomScale: 3
        )

        let scrolled = viewport.scrolledTo(horizontalPosition: 1, verticalPosition: 0)

        XCTAssertEqual(scrolled.offset.width, 740, accuracy: 0.001)
        XCTAssertEqual(scrolled.offset.height, -560, accuracy: 0.001)
        XCTAssertEqual(scrolled.horizontalScrollPosition, 1, accuracy: 0.001)
        XCTAssertEqual(scrolled.verticalScrollPosition, 0, accuracy: 0.001)
        XCTAssertEqual(scrolled.horizontalScrollKnobProportion, 0.35714285714285715, accuracy: 0.001)
        XCTAssertEqual(scrolled.verticalScrollKnobProportion, 0.35714285714285715, accuracy: 0.001)
    }

    func testUpdatingContentSizeCanResetToFit() {
        let viewport = EditorViewport(
            canvasSize: CGSize(width: 1200, height: 800),
            contentSize: CGSize(width: 600, height: 400),
            zoomScale: 2.5,
            offset: CGSize(width: 120, height: -80)
        )

        let updated = viewport.updatingContentSize(CGSize(width: 300, height: 200), fitToWindow: true)

        XCTAssertEqual(updated.zoomScale, EditorViewport.fitZoomScale)
        XCTAssertEqual(updated.offset, .zero)
        XCTAssertEqual(updated.contentSize, CGSize(width: 300, height: 200))
    }

    func testInitialCanvasSizingCapsDisplayScaleForSmallContent() {
        let viewport = EditorViewport(
            contentSize: CGSize(width: 300, height: 200)
        )
        let updated = viewport.updatingCanvasSize(
            CGSize(width: 1200, height: 800),
            maxInitialDisplayScale: EditorViewport.maxInitialDisplayScale
        )

        XCTAssertEqual(updated.fitScale, 3.8, accuracy: 0.001)
        XCTAssertEqual(updated.displayScale, 1.0, accuracy: 0.001)
        XCTAssertEqual(updated.zoomPercentage, 100)
    }

    func testInitialDisplayScaleKeepsLargeContentFittedToCanvas() {
        let viewport = EditorViewport(
            canvasSize: CGSize(width: 1200, height: 800),
            contentSize: CGSize(width: 3000, height: 2000)
        )

        let updated = viewport.zoomedForInitialDisplay(maxDisplayScale: EditorViewport.maxInitialDisplayScale)

        XCTAssertEqual(updated.zoomScale, EditorViewport.fitZoomScale)
        XCTAssertEqual(updated.displayScale, viewport.fitScale, accuracy: 0.001)
        XCTAssertEqual(updated.zoomPercentage, 38)
    }

    func testZoomToFitStillUsesFullCanvasFitScale() {
        let viewport = EditorViewport(
            canvasSize: CGSize(width: 1200, height: 800),
            contentSize: CGSize(width: 300, height: 200),
            zoomScale: 0.375
        )

        let fit = viewport.zoomedToFit()

        XCTAssertEqual(fit.zoomScale, EditorViewport.fitZoomScale)
        XCTAssertEqual(fit.displayScale, 3.8, accuracy: 0.001)
        XCTAssertEqual(fit.zoomPercentage, 380)
    }

    func testImageRectLeavesInteractionInsetWhenFitted() {
        let viewport = EditorViewport(
            canvasSize: CGSize(width: 1200, height: 800),
            contentSize: CGSize(width: 3000, height: 2000)
        )

        let imageRect = viewport.imageRect

        XCTAssertGreaterThanOrEqual(imageRect.minX, EditorViewport.interactionInset - 0.001)
        XCTAssertGreaterThanOrEqual(imageRect.minY, EditorViewport.interactionInset - 0.001)
        XCTAssertLessThanOrEqual(imageRect.maxX, 1200 - EditorViewport.interactionInset + 0.001)
        XCTAssertLessThanOrEqual(imageRect.maxY, 800 - EditorViewport.interactionInset + 0.001)
    }

    func testFocusedViewportCentersCropRectWithinCanvas() {
        let viewport = EditorViewport(
            canvasSize: CGSize(width: 1200, height: 800),
            contentSize: CGSize(width: 1600, height: 1200)
        )

        let focused = viewport.focused(on: CGRect(x: 200, y: 150, width: 800, height: 600))
        let imageRect = focused.imageRect
        let displayScale = focused.displayScale
        let cropDisplayRect = CGRect(
            x: imageRect.minX + 200 * displayScale,
            y: imageRect.minY + 150 * displayScale,
            width: 800 * displayScale,
            height: 600 * displayScale
        )

        XCTAssertGreaterThanOrEqual(cropDisplayRect.minX, EditorViewport.interactionInset - 0.001)
        XCTAssertGreaterThanOrEqual(cropDisplayRect.minY, EditorViewport.interactionInset - 0.001)
        XCTAssertLessThanOrEqual(cropDisplayRect.maxX, 1200 - EditorViewport.interactionInset + 0.001)
        XCTAssertLessThanOrEqual(cropDisplayRect.maxY, 800 - EditorViewport.interactionInset + 0.001)
        XCTAssertEqual(cropDisplayRect.midX, 600, accuracy: 0.001)
        XCTAssertEqual(cropDisplayRect.midY, 400, accuracy: 0.001)
        XCTAssertTrue(focused.canScrollHorizontally)
        XCTAssertTrue(focused.canScrollVertically)
    }
}
