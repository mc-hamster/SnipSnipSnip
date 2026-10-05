import AppKit
import XCTest
@testable import SnipSnipSnip

@MainActor
final class RegionSelectionWindowHoverTests: XCTestCase {
    func testHoverMatchesClickTargetAsPointerMovesAcrossOverlappingWindows() {
        let back = makeCaptureWindow(id: 1, focusRank: 3, frame: CGRect(x: 10, y: 10, width: 250, height: 200))
        let front = makeCaptureWindow(id: 2, focusRank: 0, frame: CGRect(x: 100, y: 80, width: 100, height: 100))
        let windows = [back, front]
        for (point, expectedID) in [(CGPoint(x: 20, y: 20), CGWindowID(1)), (CGPoint(x: 150, y: 150), CGWindowID(2))] {
            let hover = RegionSelectionWindowHover.resolve(at: point, in: windows, selectionRect: nil, isInteracting: false)
            XCTAssertEqual(hover?.window.id, expectedID)
            XCTAssertEqual(hover?.window.id, gscTopmostWindow(at: point, in: windows)?.id)
        }
        XCTAssertNil(RegionSelectionWindowHover.resolve(at: CGPoint(x: 400, y: 400), in: windows, selectionRect: nil, isInteracting: false))
    }

    func testHoverRequiresPointerAndAvailableWindows() {
        let window = makeCaptureWindow()
        XCTAssertNil(RegionSelectionWindowHover.resolve(at: nil, in: [window], selectionRect: nil, isInteracting: false))
        XCTAssertNil(RegionSelectionWindowHover.resolve(at: CGPoint(x: 50, y: 50), in: [], selectionRect: nil, isInteracting: false))
    }

    func testHoverIsHiddenDuringMouseGestureAndForExistingRegion() {
        let window = makeCaptureWindow()
        let point = CGPoint(x: 50, y: 50)
        XCTAssertNil(RegionSelectionWindowHover.resolve(at: point, in: [window], selectionRect: nil, isInteracting: true))
        for interacting in [false, true] {
            XCTAssertNil(RegionSelectionWindowHover.resolve(at: point, in: [window], selectionRect: window.frame, isInteracting: interacting))
        }
        // Clearing a region restores the hover hint without changing the click target.
        XCTAssertEqual(RegionSelectionWindowHover.resolve(at: point, in: [window], selectionRect: nil, isInteracting: false)?.window.id, window.id)
    }

    func testOutlineUsesFullWindowFrameAcrossDisplaySeamsAndScales() throws {
        let window = makeCaptureWindow(frame: CGRect(x: -100, y: 40, width: 300, height: 180))
        let hover = RegionSelectionWindowHover(window: window)
        let left = DisplaySnapshot(displayID: 1, name: "Left", frame: CGRect(x: -800, y: 0, width: 800, height: 600), scale: 1)
        let right = DisplaySnapshot(displayID: 2, name: "Right", frame: CGRect(x: 0, y: 0, width: 1000, height: 800), scale: 2)
        assertRectsEqual(try XCTUnwrap(hover.localOutlineRect(on: left)), CGRect(x: 700, y: 40, width: 300, height: 180))
        assertRectsEqual(try XCTUnwrap(hover.localOutlineRect(on: right)), CGRect(x: -100, y: 40, width: 300, height: 180))
        let remote = DisplaySnapshot(displayID: 3, name: "Above", frame: CGRect(x: 0, y: -800, width: 1000, height: 800), scale: 2)
        XCTAssertNil(hover.localOutlineRect(on: remote))
    }

    func testOutlineUsesDisplayTransformWhenOverlaySizeDiffers() throws {
        let display = DisplaySnapshot(
            displayID: 1, name: "Scaled", frame: CGRect(x: -2000, y: -100, width: 2000, height: 1000),
            overlayFrame: CGRect(x: -1000, y: 100, width: 1000, height: 500), scale: 2
        )
        let hover = RegionSelectionWindowHover(window: makeCaptureWindow(frame: CGRect(x: -1800, y: 100, width: 800, height: 400)))
        assertRectsEqual(try XCTUnwrap(hover.localOutlineRect(on: display)), CGRect(x: 100, y: 100, width: 400, height: 200))
    }

    func testOutlineRendersOnlyBoundaryAndStrengthensWithIncreaseContrast() throws {
        for scale in [CGFloat(1), 2] {
            let normal = try renderedOutlinePixels(scale: scale, increaseContrast: false)
            let highContrast = try renderedOutlinePixels(scale: scale, increaseContrast: true)
            let normalPainted = stride(from: 3, to: normal.count, by: 4).filter { normal[$0] > 0 }.count
            let highContrastPainted = stride(from: 3, to: highContrast.count, by: 4).filter { highContrast[$0] > 0 }.count
            XCTAssertGreaterThan(normalPainted, 0)
            XCTAssertGreaterThan(highContrastPainted, normalPainted)
            let width = Int(100 * scale)
            // The desktop stays visible inside and outside the outline.
            for pixels in [normal, highContrast] {
                XCTAssertEqual(pixels[(Int(50 * scale) * width + Int(50 * scale)) * 4 + 3], 0)
                XCTAssertEqual(pixels[(Int(5 * scale) * width + Int(5 * scale)) * 4 + 3], 0)
            }
        }
    }

    func testCrawlLoopsSeamlesslyWithoutChangingBoundaryOrRestarting() throws {
        let layer = CAShapeLayer()
        let path = CGPath(rect: CGRect(x: 20, y: 20, width: 60, height: 60), transform: nil)
        layer.path = path
        RegionSelectionWindowOutlineAnimation.update(on: layer, isVisible: true, reduceMotion: false, increaseContrast: false, beginTime: 42)
        let crawl = try XCTUnwrap(layer.animation(forKey: RegionSelectionWindowOutlineAnimation.key) as? CABasicAnimation)
        XCTAssertEqual(crawl.keyPath, "lineDashPhase")
        XCTAssertEqual((crawl.fromValue as? NSNumber)?.doubleValue, 0)
        XCTAssertEqual((crawl.toValue as? NSNumber)?.doubleValue, -16)
        XCTAssertEqual(layer.lineDashPattern, [6, 10])
        XCTAssertEqual(crawl.duration, 2.8)
        XCTAssertFalse(crawl.autoreverses)
        XCTAssertEqual(crawl.repeatCount, .infinity)
        XCTAssertEqual(crawl.beginTime, 42)
        XCTAssertEqual(layer.opacity, 1)
        XCTAssertEqual(layer.path, path)
        XCTAssertFalse(layer.isHidden)
        XCTAssertNil(layer.fillColor)

        RegionSelectionWindowOutlineAnimation.update(on: layer, isVisible: true, reduceMotion: false, increaseContrast: false, beginTime: 100)
        XCTAssertEqual(layer.animation(forKey: RegionSelectionWindowOutlineAnimation.key)?.beginTime, 42)
    }

    func testCrawlStopsImmediatelyForReduceMotionOrHiddenOutline() {
        let layer = CAShapeLayer()
        for (isVisible, reduceMotion) in [(true, true), (false, false)] {
            RegionSelectionWindowOutlineAnimation.update(on: layer, isVisible: true, reduceMotion: false, increaseContrast: false, beginTime: 42)
            XCTAssertNotNil(layer.animation(forKey: RegionSelectionWindowOutlineAnimation.key))
            RegionSelectionWindowOutlineAnimation.update(on: layer, isVisible: isVisible, reduceMotion: reduceMotion, increaseContrast: false, beginTime: 42)
            XCTAssertNil(layer.animation(forKey: RegionSelectionWindowOutlineAnimation.key))
            XCTAssertTrue(layer.isHidden, "Hide only the crawling highlights; the base outline stays visible.")
        }
        RegionSelectionWindowOutlineAnimation.update(on: layer, isVisible: true, reduceMotion: false, increaseContrast: false, beginTime: 42)
        XCTAssertNotNil(layer.animation(forKey: RegionSelectionWindowOutlineAnimation.key))
        XCTAssertFalse(layer.isHidden)
    }

    func testIncreaseContrastStrengthensCrawlWithoutChangingPhaseAcrossDisplays() throws {
        let layers = [CAShapeLayer(), CAShapeLayer()]
        for layer in layers {
            RegionSelectionWindowOutlineAnimation.update(on: layer, isVisible: true, reduceMotion: false, increaseContrast: false, beginTime: 42)
            XCTAssertEqual(layer.lineWidth, 1)
            RegionSelectionWindowOutlineAnimation.update(on: layer, isVisible: true, reduceMotion: false, increaseContrast: true, beginTime: 100)
            let crawl = try XCTUnwrap(layer.animation(forKey: RegionSelectionWindowOutlineAnimation.key) as? CABasicAnimation)
            XCTAssertEqual(layer.lineWidth, 3)
            XCTAssertEqual(crawl.beginTime, 42)
        }
    }

    private func renderedOutlinePixels(scale: CGFloat, increaseContrast: Bool) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(100 * scale), height: Int(100 * scale), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        RegionSelectionWindowOutlineRenderer().draw(in: CGRect(x: 20, y: 20, width: 60, height: 60), increaseContrast: increaseContrast)
        return try XCTUnwrap(normalizedRGBAPixels(try XCTUnwrap(context.makeImage())))
    }
}
