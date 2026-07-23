import AppKit
import XCTest
@testable import SnipSnipSnip

@MainActor
final class GlyphLineRendererTests: XCTestCase {
    func testCropDimensionTextResolvesEveryGlyphWithoutAttributedStringAttributes() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        let layout = try XCTUnwrap(GlyphLineRenderer.layout(text: "120 × 80 px", font: font))

        XCTAssertGreaterThan(layout.size.width, 0)
        XCTAssertGreaterThan(layout.size.height, 0)
    }

    func testLongerGlyphLineHasGreaterWidthAndSameHeight() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        let shortLayout = try XCTUnwrap(GlyphLineRenderer.layout(text: "80 × 60 px", font: font))
        let longLayout = try XCTUnwrap(GlyphLineRenderer.layout(text: "1920 × 1080 px", font: font))

        XCTAssertGreaterThan(longLayout.size.width, shortLayout.size.width)
        XCTAssertEqual(longLayout.size.height, shortLayout.size.height)
    }

    func testGlyphLineDrawsIntoBitmapContext() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        let layout = try XCTUnwrap(GlyphLineRenderer.layout(text: "120 × 80 px", font: font))
        let width = Int(layout.size.width) + 8
        let height = Int(layout.size.height) + 8
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(
            CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )

        GlyphLineRenderer.draw(layout, at: CGPoint(x: 4, y: 4), color: .white, in: context)

        XCTAssertTrue(stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 0 })
    }
}
