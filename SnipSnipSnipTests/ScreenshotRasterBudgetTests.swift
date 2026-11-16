import CoreGraphics
import ImageIO
import XCTest
@testable import SnipSnipSnip

final class ScreenshotRasterBudgetTests: XCTestCase {
    func testCapacityDependsOnPixelWidthAndNeverOverflows() {
        XCTAssertEqual(ScreenshotRasterBudget.maximumHeight(forWidth: 400), 262_144)
        XCTAssertEqual(ScreenshotRasterBudget.maximumHeight(forWidth: 4000), 33_554)
        XCTAssertEqual(ScreenshotRasterBudget.maximumHeight(forWidth: 800, requestedHeight: 2000), 2000)
        XCTAssertEqual(ScreenshotRasterBudget.maximumHeight(forWidth: 0), 0)
        XCTAssertEqual(ScreenshotRasterBudget.maximumHeight(forWidth: Int.max), 0)
        XCTAssertFalse(ScreenshotRasterBudget.contains(CGSize(width: CGFloat.infinity, height: 1)))
        XCTAssertFalse(ScreenshotRasterBudget.contains(CGSize(width: 20_000, height: 20_000)))
    }

    func testTallResizePreservesFullAspectRatioWithinPixelBudget() throws {
        let size = CGSize(width: 800, height: 160_000)
        XCTAssertEqual(try ScreenshotOutputSize.half.pixelSize(for: size), CGSize(width: 400, height: 80_000))
        XCTAssertEqual(try ScreenshotOutputSize.customWidth(600).pixelSize(for: size), CGSize(width: 600, height: 120_000))
        XCTAssertThrowsError(try ScreenshotOutputSize.customWidth(1600).pixelSize(for: size))
    }

    func testTallPNGPreservesLastRowAndJPEGReportsItsFormatLimit() throws {
        let image = makeCoordinateImage(width: 2, height: 70_000)
        let data = try ImageExporter.pngData(for: image)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, image.width)
        XCTAssertEqual(decoded.height, image.height)
        XCTAssertEqual(samplePixel(in: decoded, topLeftX: 1, topLeftY: 69_999), samplePixel(in: image, topLeftX: 1, topLeftY: 69_999))
        XCTAssertThrowsError(try ImageExporter.jpegData(for: image)) { error in
            guard case ImageExportError.jpegDimensionsTooLarge = error else {
                return XCTFail("Expected actionable JPEG dimension error, received \(error)")
            }
        }
    }
}
