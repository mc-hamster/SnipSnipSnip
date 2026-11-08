import AppKit
import XCTest
@testable import SnipSnipSnip

@MainActor
final class RegionSelectionDimensionCaptionTests: XCTestCase {
    func testCaptionPreservesRoundedDimensionsAndMultiplicationSign() {
        XCTAssertEqual(
            RegionSelectionDimensionCaptionRenderer.caption(for: CGSize(width: 1279.6, height: 719.6)),
            "1280 × 720"
        )
    }

    func testInvalidDimensionsDoNotTrapOrProduceACaption() {
        for value in [CGFloat.nan, .infinity, -.infinity, -1, CGFloat.greatestFiniteMagnitude] {
            XCTAssertNil(RegionSelectionDimensionCaptionRenderer.caption(for: CGSize(width: value, height: 20)))
            XCTAssertNil(RegionSelectionDimensionCaptionRenderer.caption(for: CGSize(width: 20, height: value)))
        }
    }

    func testCaptionRendersInsideItsBoundsAtDifferentDisplayScalesAndOrigins() throws {
        let renderer = RegionSelectionDimensionCaptionRenderer()
        for scale in [CGFloat(1), 2] {
            // Match the local graphics transform of displays to the left, above, and
            // below the primary display, including transitions between Retina scales.
            for origin in [CGPoint.zero, CGPoint(x: -1920, y: 200), CGPoint(x: 0, y: -1080), CGPoint(x: 0, y: 1080)] {
                let context = try makeContext(scale: scale)
                context.translateBy(x: -origin.x, y: -origin.y)
                let rect = CGRect(x: origin.x + 12, y: origin.y + 16, width: 108, height: 14)
                renderer.draw(size: CGSize(width: 1280, height: 720), in: rect, context: context)
                let image = try XCTUnwrap(context.makeImage())
                let pixels = try XCTUnwrap(normalizedRGBAPixels(image))
                var paintedPixels = 0
                var pixelsOutsideCaption = 0
                let captionBounds = CGRect(x: 12 * scale, y: 16 * scale, width: 108 * scale, height: 14 * scale)
                for y in 0..<image.height {
                    for x in 0..<image.width where pixels[(y * image.width + x) * 4 + 3] > 0 {
                        paintedPixels += 1
                        if !captionBounds.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) {
                            pixelsOutsideCaption += 1
                        }
                    }
                }
                XCTAssertGreaterThan(paintedPixels, 30, "Caption must remain visible at scale \(scale), origin \(origin)")
                XCTAssertEqual(pixelsOutsideCaption, 0)
            }
        }
    }

    func testDrawingRestoresGraphicsAndTextState() throws {
        let context = try makeContext(scale: 2)
        context.textMatrix = CGAffineTransform(scaleX: 0.5, y: 0.75)
        context.textPosition = CGPoint(x: 7, y: 9)
        let transform = context.ctm
        let textMatrix = context.textMatrix
        let textPosition = context.textPosition
        let clip = context.boundingBoxOfClipPath
        RegionSelectionDimensionCaptionRenderer().draw(
            size: CGSize(width: 3840, height: 2160),
            in: CGRect(x: 12, y: 16, width: 108, height: 14),
            context: context
        )
        XCTAssertEqual(context.ctm, transform)
        XCTAssertEqual(context.textMatrix, textMatrix)
        XCTAssertEqual(context.textPosition, textPosition)
        XCTAssertEqual(context.boundingBoxOfClipPath, clip)
    }

    func testRepeatedCaptionUpdatesRemainVisible() throws {
        let renderer = RegionSelectionDimensionCaptionRenderer()
        let context = try makeContext(scale: 2)
        for dimension in 1...200 {
            context.clear(CGRect(x: 0, y: 0, width: 160, height: 64))
            renderer.draw(
                size: CGSize(width: dimension * 13, height: dimension * 7),
                in: CGRect(x: 12, y: 16, width: 108, height: 14),
                context: context
            )
            let pixels = try XCTUnwrap(normalizedRGBAPixels(try XCTUnwrap(context.makeImage())))
            XCTAssertTrue(stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 0 })
        }
    }

    private func makeContext(scale: CGFloat) throws -> CGContext {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: Int(160 * scale),
            height: Int(64 * scale),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: 64)
        context.scaleBy(x: 1, y: -1)
        return context
    }
}
