import CoreGraphics
import XCTest
@testable import SnipSnipSnip

final class CaptureWindowTargetResolverTests: XCTestCase {
    func testBothSelectorsPickSameForegroundWindowAcrossDisplayLayouts() throws {
        let layouts: [(capture: CGRect, overlay: CGRect, target: CGRect, expectedOverlay: CGRect)] = [
            (CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: 0, y: 0, width: 1920, height: 1080),
             CGRect(x: 120, y: 90, width: 600, height: 400), CGRect(x: 120, y: 590, width: 600, height: 400)),
            (CGRect(x: -1600, y: -900, width: 1600, height: 900), CGRect(x: -1600, y: 1080, width: 1600, height: 900),
             CGRect(x: -1500, y: -800, width: 400, height: 300), CGRect(x: -1500, y: 1580, width: 400, height: 300)),
            (CGRect(x: 0, y: 1080, width: 1280, height: 720), CGRect(x: 0, y: -720, width: 1280, height: 720),
             CGRect(x: 100, y: 1180, width: 400, height: 300), CGRect(x: 100, y: -400, width: 400, height: 300)),
            (CGRect(x: 1920, y: 100, width: 1440, height: 900), CGRect(x: 1920, y: 80, width: 1440, height: 900),
             CGRect(x: 2000, y: 200, width: 400, height: 300), CGRect(x: 2000, y: 580, width: 400, height: 300)),
            (CGRect(x: -2000, y: -100, width: 2000, height: 1000), CGRect(x: -1000, y: 100, width: 1000, height: 500),
             CGRect(x: -1800, y: 100, width: 800, height: 400), CGRect(x: -900, y: 300, width: 400, height: 200))
        ]
        for layout in layouts {
            let display = DisplaySnapshot(displayID: 1, name: "Display", frame: layout.capture, overlayFrame: layout.overlay, scale: 2)
            let foreground = makeCaptureWindow(id: 2, focusRank: 0, frame: layout.target)
            let background = makeCaptureWindow(id: 1, focusRank: 5, frame: layout.capture)
            let windows = [background, foreground]
            let capturePoint = CGPoint(x: layout.target.midX, y: layout.target.midY)
            let overlayPoint = CGPoint(x: layout.expectedOverlay.midX, y: layout.expectedOverlay.midY)
            let region = try XCTUnwrap(RegionSelectionWindowHover.resolve(at: capturePoint, in: windows, selectionRect: nil, isInteracting: false))
            let window = try XCTUnwrap(CaptureWindowTargetResolver.resolve(atOverlayScreenPoint: overlayPoint, in: windows, displayTransform: display.captureDisplayTransform))
            XCTAssertEqual(region.window.id, foreground.id)
            XCTAssertEqual(window.id, region.window.id)
            assertRectsEqual(display.captureDisplayTransform.overlayGlobalRect(fromCaptureGlobalRect: window.frame), layout.expectedOverlay)
            XCTAssertEqual(CaptureWindowTargetResolver.resolve(atCaptureGlobalPoint: capturePoint, in: windows)?.id, region.window.id)
        }
    }

    func testDisplayFilteringUsesCaptureCoordinatesInsteadOfAppKitCoordinates() {
        let display = DisplaySnapshot(displayID: 1, name: "Above", frame: CGRect(x: 0, y: -900, width: 1600, height: 900), overlayFrame: CGRect(x: 0, y: 1080, width: 1600, height: 900), scale: 2)
        let above = makeCaptureWindow(id: 1, frame: CGRect(x: 100, y: -800, width: 400, height: 300))
        let decoy = makeCaptureWindow(id: 2, frame: CGRect(x: 100, y: 1200, width: 400, height: 300))
        XCTAssertEqual(CaptureWindowTargetResolver.windows([above, decoy], intersecting: display).map(\.id), [above.id])
    }

    func testSpanningWindowResolvesToSameIdentityFromEitherDisplay() throws {
        let window = makeCaptureWindow(id: 3, focusRank: 0, frame: CGRect(x: -100, y: 40, width: 300, height: 180))
        let left = DisplaySnapshot(displayID: 1, name: "Left", frame: CGRect(x: -800, y: 0, width: 800, height: 600), scale: 1)
        let right = DisplaySnapshot(displayID: 2, name: "Right", frame: CGRect(x: 0, y: 0, width: 1000, height: 800), scale: 2)
        for (display, point) in [(left, CGPoint(x: -50, y: 100)), (right, CGPoint(x: 50, y: 100))] {
            let candidates = CaptureWindowTargetResolver.windows([window], intersecting: display)
            let overlayPoint = display.captureDisplayTransform.overlayGlobalPoint(fromCaptureGlobalPoint: point)
            let resolved = try XCTUnwrap(CaptureWindowTargetResolver.resolve(atOverlayScreenPoint: overlayPoint, in: candidates, displayTransform: display.captureDisplayTransform))
            XCTAssertEqual(resolved.id, window.id)
            XCTAssertEqual(resolved.frame, window.frame)
        }
    }

    func testFractionalWindowBoundsRemainIdenticalForBothHighlights() throws {
        let display = DisplaySnapshot(displayID: 1, name: "Scaled", frame: CGRect(x: 0, y: 0, width: 2000, height: 1000), overlayFrame: CGRect(x: 0, y: 0, width: 1000, height: 500), scale: 2)
        let window = makeCaptureWindow(frame: CGRect(x: 101.25, y: 73.5, width: 315.25, height: 180.75))
        let regionRect = try XCTUnwrap(RegionSelectionWindowHover(window: window).localOutlineRect(on: display))
        let screenRect = display.captureDisplayTransform.overlayGlobalRect(fromCaptureGlobalRect: window.frame)
        let windowRect = AppKitOverlayTransform(overlayFrame: display.overlayFrame).localRect(fromGlobalRect: screenRect)
        assertRectsEqual(regionRect, windowRect)
    }

    func testOutsidePointerDoesNotSelectAWindowInEitherCoordinateSpace() {
        let display = DisplaySnapshot(displayID: 1, name: "Display", frame: CGRect(x: 0, y: 0, width: 800, height: 600), scale: 1)
        let window = makeCaptureWindow(frame: CGRect(x: 100, y: 100, width: 200, height: 200))
        let point = CGPoint(x: 10, y: 10)
        XCTAssertNil(CaptureWindowTargetResolver.resolve(atCaptureGlobalPoint: point, in: [window]))
        XCTAssertNil(CaptureWindowTargetResolver.resolve(atOverlayScreenPoint: display.captureDisplayTransform.overlayGlobalPoint(fromCaptureGlobalPoint: point), in: [window], displayTransform: display.captureDisplayTransform))
    }

    func testFractionalBorderDoesNotExpandTheHitTargetIntoAdjacentContent() {
        let display = DisplaySnapshot(displayID: 1, name: "Display", frame: CGRect(x: 0, y: 0, width: 800, height: 600), scale: 2)
        let background = makeCaptureWindow(id: 1, focusRank: 5, frame: display.frame)
        let foreground = makeCaptureWindow(id: 2, focusRank: 0, frame: CGRect(x: 100.5, y: 100.5, width: 200, height: 200))
        let point = CGPoint(x: 100.25, y: 150)
        let windows = [foreground, background]
        XCTAssertEqual(CaptureWindowTargetResolver.resolve(atCaptureGlobalPoint: point, in: windows)?.id, background.id)
        XCTAssertEqual(CaptureWindowTargetResolver.resolve(atOverlayScreenPoint: display.captureDisplayTransform.overlayGlobalPoint(fromCaptureGlobalPoint: point), in: windows, displayTransform: display.captureDisplayTransform)?.id, background.id)
    }
}
