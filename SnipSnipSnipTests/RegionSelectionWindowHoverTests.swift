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

    func testEntryAnimationFinishesWithoutLoopingOrChangingBoundary() throws {
        let layer = CALayer()
        let frame = CGRect(x: 20, y: 20, width: 60, height: 60)
        layer.frame = frame
        let start = CACurrentMediaTime() + 60
        CaptureSelectionOutlineAnimation.update(on: layer, isVisible: true, animatesEntry: true, allowsAnimation: true, beginTime: start)
        let appear = try XCTUnwrap(layer.animation(forKey: CaptureSelectionOutlineAnimation.key) as? CABasicAnimation)
        XCTAssertEqual(appear.keyPath, "opacity")
        XCTAssertEqual((appear.fromValue as? NSNumber)?.floatValue, 0.7)
        XCTAssertEqual((appear.toValue as? NSNumber)?.floatValue, 1)
        XCTAssertEqual(appear.duration, 0.18)
        XCTAssertFalse(appear.autoreverses)
        XCTAssertEqual(appear.repeatCount, 0)
        XCTAssertTrue(appear.isRemovedOnCompletion)
        XCTAssertEqual(appear.beginTime, start)
        XCTAssertEqual(layer.opacity, 1, "The final outline remains fully visible after the animation is removed.")
        XCTAssertEqual(layer.frame, frame)
    }

    func testPointerMovementKeepsEntryTimingAndNewTargetRestartsIt() throws {
        let layer = CALayer()
        let start = CACurrentMediaTime() + 60
        CaptureSelectionOutlineAnimation.update(on: layer, isVisible: true, animatesEntry: true, allowsAnimation: true, beginTime: start)
        CaptureSelectionOutlineAnimation.update(on: layer, isVisible: true, animatesEntry: false, allowsAnimation: true, beginTime: start + 1)
        XCTAssertEqual(layer.animation(forKey: CaptureSelectionOutlineAnimation.key)?.beginTime, start)
        CaptureSelectionOutlineAnimation.update(on: layer, isVisible: true, animatesEntry: true, allowsAnimation: true, beginTime: start + 2)
        XCTAssertEqual(layer.animation(forKey: CaptureSelectionOutlineAnimation.key)?.beginTime, start + 2)
    }

    func testAccessibilityFallbackAndHiddenOutlineRemoveEntryAnimationImmediately() {
        let layer = CALayer()
        for (isVisible, allowsAnimation) in [(true, false), (false, true)] {
            CaptureSelectionOutlineAnimation.update(on: layer, isVisible: true, animatesEntry: true, allowsAnimation: true, beginTime: CACurrentMediaTime() + 60)
            XCTAssertNotNil(layer.animation(forKey: CaptureSelectionOutlineAnimation.key))
            CaptureSelectionOutlineAnimation.update(on: layer, isVisible: isVisible, animatesEntry: false, allowsAnimation: allowsAnimation, beginTime: 0)
            XCTAssertNil(layer.animation(forKey: CaptureSelectionOutlineAnimation.key))
            XCTAssertEqual(layer.opacity, 1)
        }
    }

    func testSpanningWindowEntryUsesSameClockOnEachDisplay() throws {
        let start = CACurrentMediaTime() + 60
        for layer in [CALayer(), CALayer()] {
            CaptureSelectionOutlineAnimation.update(on: layer, isVisible: true, animatesEntry: true, allowsAnimation: true, beginTime: start)
            XCTAssertEqual(layer.animation(forKey: CaptureSelectionOutlineAnimation.key)?.beginTime, start)
        }
    }

    func testOutlineStaysNeutralWithoutAccentColoredPixels() throws {
        let pixels = try renderedOutlinePixels(scale: 2, increaseContrast: false)
        for offset in stride(from: 0, to: pixels.count, by: 4) where pixels[offset + 3] > 0 {
            XCTAssertLessThanOrEqual(abs(Int(pixels[offset]) - Int(pixels[offset + 1])), 1)
            XCTAssertLessThanOrEqual(abs(Int(pixels[offset]) - Int(pixels[offset + 2])), 1)
        }
    }

    func testCrawlIsOneTaperedHighlightWithASeamlessFullPerimeterLoop() throws {
        let layers = (0..<CaptureSelectionBorderCrawl.layerCount).map { _ in CAShapeLayer() }
        let rect = CGRect(x: 20, y: 20, width: 300, height: 200)
        let start = CACurrentMediaTime() + 60
        CaptureSelectionBorderCrawl.update(on: layers, rect: rect, allowsAnimation: true, restarts: true, beginTime: start)
        var previousLength = CGFloat.infinity
        var previousOpacity: Float = 0
        for layer in layers {
            let pattern = try XCTUnwrap(layer.lineDashPattern)
            XCTAssertEqual(pattern.count, 2)
            let length = CGFloat(pattern[0].doubleValue)
            XCTAssertLessThan(length, previousLength)
            XCTAssertGreaterThan(layer.opacity, previousOpacity)
            XCTAssertEqual(pattern[0].doubleValue + pattern[1].doubleValue, 1000, accuracy: 0.001)
            XCTAssertEqual(layer.path?.boundingBoxOfPath, rect)
            XCTAssertFalse(layer.isHidden)
            XCTAssertNil(layer.fillColor)
            let crawl = try XCTUnwrap(layer.animation(forKey: CaptureSelectionBorderCrawl.key) as? CABasicAnimation)
            let from = try XCTUnwrap(crawl.fromValue as? NSNumber).doubleValue
            let to = try XCTUnwrap(crawl.toValue as? NSNumber).doubleValue
            XCTAssertEqual(from - to, 1000, accuracy: 0.001)
            XCTAssertEqual(crawl.duration, 4.8)
            XCTAssertEqual(crawl.repeatCount, .infinity)
            XCTAssertFalse(crawl.autoreverses)
            previousLength = length
            previousOpacity = layer.opacity
        }
    }

    func testReduceTransparencyKeepsCrawlWhileOnlyReduceMotionStopsIt() {
        for reduceMotion in [false, true] {
            for reduceTransparency in [false, true] {
                for increaseContrast in [false, true] {
                    let motion = CaptureSelectionMotionPolicy(reduceMotion: reduceMotion, reduceTransparency: reduceTransparency, increaseContrast: increaseContrast)
                    XCTAssertEqual(motion.allowsCrawl, !reduceMotion)
                    XCTAssertEqual(motion.allowsEntryFade, !reduceMotion && !reduceTransparency && !increaseContrast)
                    let layers = (0..<CaptureSelectionBorderCrawl.layerCount).map { _ in CAShapeLayer() }
                    CaptureSelectionBorderCrawl.update(on: layers, rect: CGRect(x: 20, y: 20, width: 300, height: 200), allowsAnimation: motion.allowsCrawl, increaseContrast: increaseContrast, restarts: true, beginTime: CACurrentMediaTime() + 60)
                    XCTAssertEqual(layers[0].animation(forKey: CaptureSelectionBorderCrawl.key) != nil, !reduceMotion)
                    if !reduceMotion {
                        XCTAssertEqual(layers[0].lineWidth, increaseContrast ? 3 : 1.5)
                        XCTAssertEqual(layers[0].strokeColor, (increaseContrast ? NSColor.black : NSColor(calibratedWhite: 0.12, alpha: 1)).cgColor)
                        XCTAssertEqual(layers.last?.strokeColor, NSColor.white.cgColor)
                    }
                }
            }
        }
    }

    func testCrawlKeepsItsClockDuringPointerMovementAndStopsForAccessibilityOrHiddenTarget() {
        let layers = (0..<CaptureSelectionBorderCrawl.layerCount).map { _ in CAShapeLayer() }
        let rect = CGRect(x: 20, y: 20, width: 300, height: 200)
        let start = CACurrentMediaTime() + 60
        CaptureSelectionBorderCrawl.update(on: layers, rect: rect, allowsAnimation: true, restarts: true, beginTime: start)
        CaptureSelectionBorderCrawl.update(on: layers, rect: rect, allowsAnimation: true, restarts: false, beginTime: start + 1)
        XCTAssertTrue(layers.allSatisfy { $0.animation(forKey: CaptureSelectionBorderCrawl.key)?.beginTime == start })
        for (target, allowsAnimation) in [(rect as CGRect?, false), (nil, true)] {
            CaptureSelectionBorderCrawl.update(on: layers, rect: target, allowsAnimation: allowsAnimation, restarts: false, beginTime: start)
            XCTAssertTrue(layers.allSatisfy { $0.isHidden && $0.animation(forKey: CaptureSelectionBorderCrawl.key) == nil })
        }
    }

    func testCrawlUsesMatchingNormalizedProgressAcrossDisplayScales() throws {
        let start = CACurrentMediaTime() + 60
        for scale in [CGFloat(1), 0.5] {
            let layers = (0..<CaptureSelectionBorderCrawl.layerCount).map { _ in CAShapeLayer() }
            let rect = CGRect(x: 20, y: 20, width: 300 * scale, height: 200 * scale)
            CaptureSelectionBorderCrawl.update(on: layers, rect: rect, allowsAnimation: true, restarts: true, beginTime: start)
            let crawl = try XCTUnwrap(layers[0].animation(forKey: CaptureSelectionBorderCrawl.key) as? CABasicAnimation)
            XCTAssertEqual(crawl.beginTime, start)
            XCTAssertEqual(crawl.duration, CaptureSelectionBorderCrawl.duration)
            let to = try XCTUnwrap(crawl.toValue as? NSNumber).doubleValue
            XCTAssertEqual(to / Double(1000 * scale), -1, accuracy: 0.001)
            XCTAssertEqual(try XCTUnwrap(layers[0].lineDashPattern)[0].doubleValue / Double(1000 * scale), 0.10, accuracy: 0.001)
        }
    }

    func testSharedHighlightIsClickThroughAndKeepsItsViewBounds() {
        let frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        let view = CaptureSelectionWindowHighlightView(frame: frame)
        view.refresh(windowID: 1, rect: CGRect(x: 20, y: 100, width: 120, height: 80), label: "App — Document", transitionStartTime: CACurrentMediaTime())
        XCTAssertNil(view.hitTest(CGPoint(x: 20, y: 100)))
        XCTAssertNil(view.hitTest(CGPoint(x: 40, y: 80)))
        XCTAssertEqual(view.frame, frame)
        view.refresh(windowID: nil, rect: nil, label: nil, transitionStartTime: 0)
        XCTAssertNil(view.layer?.animation(forKey: CaptureSelectionOutlineAnimation.key))
        let strokes = view.layer?.sublayers?.compactMap { $0 as? CAShapeLayer } ?? []
        XCTAssertTrue(strokes.allSatisfy { $0.isHidden && $0.animation(forKey: CaptureSelectionBorderCrawl.key) == nil })
    }

    func testHostedCrawlProducesClearlyDifferentBorderPixelsAtDifferentPositions() throws {
        let size = CGSize(width: 640, height: 480)
        let panel = NSPanel(contentRect: CGRect(x: -10000, y: -10000, width: size.width, height: size.height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.sharingType = .none
        defer { panel.orderOut(nil) }
        let parent = NSView(frame: CGRect(origin: .zero, size: size))
        parent.wantsLayer = true
        let view = CaptureSelectionWindowHighlightView(frame: parent.bounds)
        parent.addSubview(view)
        panel.contentView = parent
        panel.orderFrontRegardless()
        let target = CGRect(x: 60, y: 100, width: 400, height: 250)
        view.refresh(windowID: 1, rect: target, label: nil, transitionStartTime: CACurrentMediaTime())
        panel.displayIfNeeded()
        parent.layoutSubtreeIfNeeded()
        let layer = try XCTUnwrap(view.layer)
        let strokes = layer.sublayers?.compactMap { $0 as? CAShapeLayer } ?? []
        XCTAssertEqual(strokes.count, CaptureSelectionBorderCrawl.layerCount)
        var captures: [[UInt8]] = []
        for progress in [CGFloat(0), 0.5] {
            CaptureSelectionBorderCrawl.update(on: strokes, rect: target, allowsAnimation: true, restarts: true, beginTime: CACurrentMediaTime() + 60)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for stroke in strokes {
                let animation = try XCTUnwrap(stroke.animation(forKey: CaptureSelectionBorderCrawl.key) as? CABasicAnimation)
                let from = try XCTUnwrap(animation.fromValue as? NSNumber).doubleValue
                let to = try XCTUnwrap(animation.toValue as? NSNumber).doubleValue
                stroke.removeAllAnimations()
                stroke.lineDashPhase = CGFloat(from + (to - from) * Double(progress))
            }
            CATransaction.commit()
            captures.append(try renderedPixels(scale: 1, size: size) {
                layer.render(in: NSGraphicsContext.current!.cgContext)
            })
        }
        // Installed animations alone did not verify visibility. Compare actual
        // hosted-view RGB pixels; alpha remains unchanged over the opaque rail.
        let peakChange = captures[0].indices.filter { $0 % 4 != 3 }.map { abs(Int(captures[0][$0]) - Int(captures[1][$0])) }.max() ?? 0
        XCTAssertGreaterThanOrEqual(peakChange, 60)
    }

    func testSharedTargetLabelFitsDisplayAndAvoidsInstructionsWhenSpaceAllows() throws {
        for bounds in [CGRect(x: 0, y: 0, width: 800, height: 600), CGRect(x: -1920, y: 100, width: 1920, height: 1080)] {
            for target in [CGRect(x: bounds.minX - 100, y: bounds.minY, width: 300, height: 200), CGRect(x: bounds.maxX - 80, y: bounds.maxY - 60, width: 300, height: 200)] {
                let rect = try XCTUnwrap(CaptureSelectionAppearance.labelRect(for: CGSize(width: 900, height: 16), targetRect: target, in: bounds))
                XCTAssertTrue(bounds.contains(rect))
                XCTAssertLessThanOrEqual(rect.width, 384)
                XCTAssertGreaterThanOrEqual(rect.minY, bounds.minY + 96)
            }
        }
    }

    func testSharedDimmingKeepsTargetClearIncludingAcrossDisplaySeam() throws {
        for target in [CGRect(x: 20, y: 20, width: 60, height: 60), CGRect(x: -100, y: 20, width: 160, height: 60)] {
            let pixels = try renderedPixels(scale: 1) {
                CaptureSelectionAppearance.drawDimming(in: CGRect(x: 0, y: 0, width: 100, height: 100), excluding: target)
            }
            XCTAssertEqual(pixels[(50 * 100 + 30) * 4 + 3], 0)
            XCTAssertGreaterThan(pixels[(50 * 100 + 90) * 4 + 3], 0)
            if target.minX < 0 {
                XCTAssertEqual(pixels[(50 * 100) * 4 + 3], 0, "A spanning window must stay clear at the display seam.")
            }
        }
    }

    private func renderedOutlinePixels(scale: CGFloat, increaseContrast: Bool) throws -> [UInt8] {
        try renderedPixels(scale: scale) {
            CaptureSelectionOutlineRenderer().draw(in: CGRect(x: 20, y: 20, width: 60, height: 60), increaseContrast: increaseContrast)
        }
    }

    private func renderedPixels(scale: CGFloat, size: CGSize = CGSize(width: 100, height: 100), draw: () -> Void) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        draw()
        return try XCTUnwrap(normalizedRGBAPixels(try XCTUnwrap(context.makeImage())))
    }
}
