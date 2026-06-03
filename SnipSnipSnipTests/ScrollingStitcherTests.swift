import CoreGraphics
import XCTest
@testable import SnipSnipSnip

final class ScrollingStitcherTests: XCTestCase {
    func testStitchesPerfectOverlap() throws {
        let first = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 })
        let second = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 + 50 })
        let stitcher = ScrollingStitcher()
        var state = try stitcher.initialState(with: first, maxOutputHeight: 300)

        XCTAssertEqual(stitcher.append(second, to: &state), .appended)

        XCTAssertEqual(state.segmentCount, 2)
        XCTAssertEqual(state.image.width, 48)
        XCTAssertEqual(state.image.height, 130)
        XCTAssertEqual(samplePixel(in: state.image, topLeftX: 10, topLeftY: 5), scrollingPixel(x: 10, y: 5))
        XCTAssertEqual(samplePixel(in: state.image, topLeftX: 10, topLeftY: 125), scrollingPixel(x: 10, y: 125))
    }

    func testStitchesWithStickyHeaderAtTopOfNextFrame() throws {
        let first = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 })
        let second = makeScrollingFrame(width: 48, height: 80, rowMapper: { localY in
            localY < 12 ? localY : localY + 38
        })
        let stitcher = ScrollingStitcher()
        var state = try stitcher.initialState(with: first, maxOutputHeight: 300)

        XCTAssertEqual(stitcher.append(second, to: &state), .appended)

        XCTAssertEqual(state.segmentCount, 2)
        XCTAssertGreaterThanOrEqual(state.image.height, 118)
        XCTAssertLessThanOrEqual(state.image.height, 132)
    }

    func testDuplicateFramesAreDetectedAsEndOfScroll() throws {
        let frame = makeCoordinateImage(width: 48, height: 80, pattern: .weighted(xMultiplier: 7, yMultiplier: 23, includeBlueSum: true))
        let stitcher = ScrollingStitcher()

        XCTAssertTrue(stitcher.imagesAreDuplicate(frame, frame))
    }

    func testLowConfidenceMismatchIsRejected() throws {
        let first = makeSolidImage(width: 48, height: 80, red: 20, green: 40, blue: 60)
        let second = makeSolidImage(width: 48, height: 80, red: 220, green: 180, blue: 120)
        let stitcher = ScrollingStitcher()
        var state = try stitcher.initialState(with: first, maxOutputHeight: 300)

        XCTAssertEqual(stitcher.append(second, to: &state), .lowConfidence)
        XCTAssertEqual(state.segmentCount, 1)
    }

    func testMaxOutputHeightProducesPartialAppendAndStops() throws {
        let first = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 })
        let second = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 + 50 })
        let stitcher = ScrollingStitcher()
        var state = try stitcher.initialState(with: first, maxOutputHeight: 100)

        XCTAssertEqual(stitcher.append(second, to: &state), .reachedMaximumHeight)

        XCTAssertEqual(state.segmentCount, 2)
        XCTAssertEqual(state.image.height, 100)
    }

    func testAppendPerformanceLongScrollingSession() throws {
        let stitcher = ScrollingStitcher()
        let frames = (0..<14).map { index in
            makeScrollingFrame(width: 640, height: 900, rowMapper: { $0 + (index * 110) })
        }
        let options = XCTMeasureOptions.default
        options.iterationCount = 5

        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()], options: options) {
            guard var state = try? stitcher.initialState(with: frames[0], maxOutputHeight: 20_000) else {
                return XCTFail("Expected initial stitch state")
            }

            for frame in frames.dropFirst() {
                _ = stitcher.append(frame, to: &state)
            }

            XCTAssertGreaterThan(state.image.height, frames[0].height)
        }
    }

    func testAppendPerformanceManySmallScrollingFrames() throws {
        let stitcher = ScrollingStitcher()
        let frames = (0..<24).map { index in
            makeScrollingFrame(width: 540, height: 620, rowMapper: { localY in
                let overlap = 120 - ((index % 3) * 18)
                return localY + (index * 90) - overlap
            })
        }
        let options = XCTMeasureOptions.default
        options.iterationCount = 5

        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()], options: options) {
            guard var state = try? stitcher.initialState(with: frames[0], maxOutputHeight: 18_000) else {
                return XCTFail("Expected initial stitch state")
            }

            for frame in frames.dropFirst() {
                _ = stitcher.append(frame, to: &state)
            }

            XCTAssertGreaterThan(state.image.height, frames[0].height)
        }
    }

    private func makeScrollingFrame(width: Int, height: Int, rowMapper: (Int) -> Int) -> CGImage {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        for y in 0..<height {
            for x in 0..<width {
                let sample = scrollingPixel(x: x, y: rowMapper(y))
                let offset = y * bytesPerRow + x * bytesPerPixel
                pixels[offset] = sample.red
                pixels[offset + 1] = sample.green
                pixels[offset + 2] = sample.blue
                pixels[offset + 3] = sample.alpha
            }
        }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    private func scrollingPixel(x: Int, y: Int) -> PixelSample {
        PixelSample(
            red: UInt8(truncatingIfNeeded: x),
            green: UInt8(truncatingIfNeeded: y),
            blue: UInt8(truncatingIfNeeded: x * 3 + y / 2),
            alpha: 255
        )
    }

    private func makeSolidImage(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) -> CGImage {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                pixels[offset] = red
                pixels[offset + 1] = green
                pixels[offset + 2] = blue
                pixels[offset + 3] = 255
            }
        }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

}
