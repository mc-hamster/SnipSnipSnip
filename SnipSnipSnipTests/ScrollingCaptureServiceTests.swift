import CoreGraphics
import XCTest
@testable import SnipSnipSnip

final class ScrollingCaptureServiceTests: XCTestCase {
    func testCursorParkingLocationPrefersPointOutsideViewport() {
        let point = ScrollingCaptureService.cursorParkingLocation(
            avoiding: CGRect(x: 100, y: 100, width: 400, height: 300),
            on: CGRect(x: 0, y: 0, width: 1200, height: 900)
        )

        XCTAssertEqual(point, CGPoint(x: 524, y: 424))
    }

    func testCursorParkingLocationReturnsNilWhenViewportFillsVisibleFrame() {
        let point = ScrollingCaptureService.cursorParkingLocation(
            avoiding: CGRect(x: 0, y: 0, width: 1200, height: 900),
            on: CGRect(x: 0, y: 0, width: 1200, height: 900)
        )

        XCTAssertNil(point)
    }
}

final class ScreenCaptureServiceTests: XCTestCase {
    func testRepairTransparentArtifactRowsReplacesIsolatedTransparentRow() {
        let service = ScreenCaptureService()
        let image = makeImageWithTransparentRows(width: 16, height: 8, transparentRows: [3])

        let repaired = service.repairTransparentArtifactRows(in: image)

        XCTAssertEqual(
            samplePixel(in: repaired, topLeftX: 6, topLeftY: 3),
            samplePixel(in: repaired, topLeftX: 6, topLeftY: 2)
        )
    }

    func testRepairTransparentArtifactRowsLeavesOpaqueImageUnchanged() {
        let service = ScreenCaptureService()
        let image = makeCoordinateImage(
            width: 16,
            height: 8,
            pattern: .weighted(xMultiplier: 9, yMultiplier: 13, includeBlueSum: true)
        )

        let repaired = service.repairTransparentArtifactRows(in: image)

        XCTAssertEqual(samplePixel(in: repaired, topLeftX: 4, topLeftY: 5), samplePixel(in: image, topLeftX: 4, topLeftY: 5))
    }

    func testDirectDisplayCaptureRequestUsesDisplayLocalCrop() {
        let service = ScreenCaptureService()
        let displays = [
            DisplaySnapshot(
                displayID: 7,
                name: "Display",
                frame: CGRect(x: 100, y: 200, width: 1440, height: 900),
                scale: 2
            )
        ]

        let request = service.directDisplayCaptureRequest(
            for: CGRect(x: 140, y: 260, width: 320, height: 180),
            displays: displays
        )

        XCTAssertEqual(
            request,
            DirectDisplayCaptureRequest(
                displayID: 7,
                sourceRect: DisplayLocalRect(CGRect(x: 40, y: 60, width: 320, height: 180)),
                outputSize: CGSize(width: 640, height: 360)
            )
        )
    }

    func testDirectDisplayCaptureRequestReturnsNilWhenRegionSpansDisplays() {
        let service = ScreenCaptureService()
        let displays = [
            DisplaySnapshot(
                displayID: 1,
                name: "Left",
                frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                scale: 2
            ),
            DisplaySnapshot(
                displayID: 2,
                name: "Right",
                frame: CGRect(x: 800, y: 0, width: 800, height: 600),
                scale: 2
            )
        ]

        let request = service.directDisplayCaptureRequest(
            for: CGRect(x: 760, y: 100, width: 120, height: 200),
            displays: displays
        )

        XCTAssertNil(request)
    }

    func testRegionCapturePlanAllowsStillScreenshotAcrossDisplays() {
        let displays = [
            DisplaySnapshot(displayID: 1, name: "Left", frame: CGRect(x: 0, y: 0, width: 800, height: 600), scale: 1),
            DisplaySnapshot(displayID: 2, name: "Right", frame: CGRect(x: 800, y: 0, width: 800, height: 600), scale: 2)
        ]
        let region = CGRect(x: 760, y: 100, width: 120, height: 200)

        XCTAssertEqual(
            ScreenCaptureService().regionCapturePlan(for: region, displays: displays, requiresSingleDisplay: false),
            .screenRect(rect: region, scale: 2)
        )
        XCTAssertEqual(
            ScreenCaptureService().regionCapturePlan(for: region, displays: displays, requiresSingleDisplay: true),
            .rejectedSingleDisplay
        )
    }

    func testDirectDisplayCaptureRequestUsesTopLeftOffsetOnDisplayBelowPrimary() {
        let service = ScreenCaptureService()
        // Secondary monitor below primary (negative y), region slightly bleeds into primary (y > 0).
        let displays = [
            DisplaySnapshot(
                displayID: 1,
                name: "Primary",
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                scale: 2
            ),
            DisplaySnapshot(
                displayID: 2,
                name: "Secondary",
                frame: CGRect(x: -1920, y: -1080, width: 1920, height: 1080),
                scale: 2
            )
        ]

        let request = service.directDisplayCaptureRequest(
            for: CGRect(x: -1716, y: -447, width: 1198, height: 400),
            displays: displays
        )

        XCTAssertEqual(request?.displayID, 2)
        XCTAssertEqual(request?.sourceRect, DisplayLocalRect(CGRect(x: 204, y: 633, width: 1198, height: 400)))
    }
}

private func makeImageWithTransparentRows(width: Int, height: Int, transparentRows: Set<Int>) -> CGImage {
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

    for y in 0..<height {
        for x in 0..<width {
            let offset = y * bytesPerRow + x * bytesPerPixel
            let alpha: UInt8 = transparentRows.contains(y) ? 0 : 255

            pixels[offset] = alpha == 0 ? 0 : UInt8((x * 17) % 255)
            pixels[offset + 1] = alpha == 0 ? 0 : UInt8((y * 29) % 255)
            pixels[offset + 2] = alpha == 0 ? 0 : UInt8((x + y * 3) % 255)
            pixels[offset + 3] = alpha
        }
    }

    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: CGDataProvider(data: Data(pixels) as CFData)!,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}
