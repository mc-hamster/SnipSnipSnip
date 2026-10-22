import CoreGraphics
import XCTest
@testable import SnipSnipSnip

final class ScrollingStitcherTests: XCTestCase {
    func testSparseUnrelatedTextEdgesDoNotMatchBecauseTheBackgroundIsWhite() throws {
        func frame(multiplier: Int) -> CGImage {
            makeRGBAImage(width: 48, height: 80) { x, y in
                let value: UInt8 = x == ((y * y + multiplier * y + multiplier) % 41) + 3 ? 0 : 255
                return PixelSample(red: value, green: value, blue: value, alpha: 255)
            }
        }
        let first = frame(multiplier: 3)
        let next = frame(multiplier: 11)
        let stitcher = ScrollingStitcher()
        var state = try stitcher.initialState(with: first, maxOutputHeight: 300)

        XCTAssertEqual(stitcher.append(next, to: &state), .lowConfidence)
        XCTAssertEqual(state.outputHeight, 80)
        XCTAssertEqual(state.segmentCount, 1)
    }
    func testChangedViewportHeightIsRejectedWithoutAppendingContent() throws {
        let first = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 })
        let next = makeScrollingFrame(width: 48, height: 90, rowMapper: { $0 + 50 })
        let stitcher = ScrollingStitcher()
        var state = try stitcher.initialState(with: first, maxOutputHeight: 300)

        XCTAssertEqual(stitcher.append(next, to: &state), .lowConfidence)
        XCTAssertNil(stitcher.bestMatch(previous: first, next: next))
        assertScrollingRows(in: state.image, expectedHeight: 80)
    }
    func testSmallViewportRetainsOverlapAtNormalScrollDistance() throws {
        let first = makeScrollingFrame(width: 12, height: 12, rowMapper: { $0 })
        let next = makeScrollingFrame(width: 12, height: 12, rowMapper: { $0 + 9 })
        let stitcher = ScrollingStitcher()
        var state = try stitcher.initialState(with: first, maxOutputHeight: 100)

        XCTAssertEqual(stitcher.append(next, to: &state), .appended)
        assertScrollingRows(in: state.image, expectedHeight: 21)
    }

    func testEqualLuminanceColorRowsDoNotLookStationary() throws {
        func pixel(at row: Int) -> PixelSample {
            (row * row + row / 3) % 5 < 2
                ? PixelSample(red: 255, green: 0, blue: 0, alpha: 255)
                : PixelSample(red: 0, green: 130, blue: 0, alpha: 255)
        }
        let first = makeRGBAImage(width: 48, height: 80) { _, y in pixel(at: y) }
        let next = makeRGBAImage(width: 48, height: 80) { _, y in pixel(at: y + 1) }
        let stitcher = ScrollingStitcher()
        var state = try stitcher.initialState(with: first, maxOutputHeight: 100)

        XCTAssertEqual(stitcher.append(next, to: &state), .appended)
        XCTAssertEqual(state.outputHeight, 81)
        for y in 0..<81 {
            XCTAssertEqual(samplePixel(in: state.image, topLeftX: 10, topLeftY: y), pixel(at: y))
        }
    }
    func testInitialFrameRespectsOutputHeightLimit() throws {
        let frame = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 })
        let state = try ScrollingStitcher().initialState(with: frame, maxOutputHeight: 25)

        XCTAssertEqual(state.outputHeight, 25)
        XCTAssertEqual(state.segmentCount, 1)
        assertScrollingRows(in: state.image, expectedHeight: 25)
    }

    func testProgressPreviewIsBoundedWithoutReducingOutputResolution() throws {
        let first = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 })
        let second = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 + 50 })
        let stitcher = ScrollingStitcher()
        var state = try stitcher.initialState(with: first, maxOutputHeight: 300)
        XCTAssertEqual(stitcher.append(second, to: &state), .appended)

        let preview = try XCTUnwrap(state.makePreviewImage(maximumDimension: 32))

        XCTAssertEqual(preview.width, 11)
        XCTAssertEqual(preview.height, 32)
        XCTAssertEqual(state.image.width, 48)
        assertScrollingRows(in: state.image, expectedHeight: 130)
    }

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

    func testSmallAndOddPixelScrollsPreserveEveryRow() throws {
        let stitcher = ScrollingStitcher()
        let first = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 })

        for distance in [1, 3, 7, 17, 25, 50, 67] {
            let next = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 + distance })
            var state = try stitcher.initialState(with: first, maxOutputHeight: 300)

            XCTAssertFalse(stitcher.imagesAreDuplicate(first, next), "Scroll distance: \(distance)")
            XCTAssertEqual(stitcher.append(next, to: &state), .appended)
            XCTAssertEqual(state.outputHeight, 80 + distance)
            assertScrollingRows(in: state.image, expectedHeight: 80 + distance)
        }
    }

    func testShortFinalScrollsAndRepeatedBottomDoNotLoseOrDuplicateRows() throws {
        let stitcher = ScrollingStitcher()
        let first = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 })
        var state = try stitcher.initialState(with: first, maxOutputHeight: 300)

        for offset in [50, 57, 58] {
            let frame = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 + offset })
            XCTAssertEqual(stitcher.append(frame, to: &state), .appended)
            XCTAssertEqual(state.outputHeight, 80 + offset)
            assertScrollingRows(in: state.image, expectedHeight: 80 + offset)
        }
        let last = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 + 58 })
        XCTAssertEqual(stitcher.append(last, to: &state), .unchanged)
        assertScrollingRows(in: state.image, expectedHeight: 138)
        XCTAssertEqual(state.segmentCount, 4)
    }

    func testStationaryFrameWithSmallVisualChangeDoesNotAppendADuplicateTail() throws {
        let stitcher = ScrollingStitcher()
        let first = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 })
        let changed = makeRGBAImage(width: 48, height: 80) { x, y in
            x == 47 && y == 79
                ? PixelSample(red: 255, green: 255, blue: 255, alpha: 255)
                : scrollingPixel(x: x, y: y)
        }
        var state = try stitcher.initialState(with: first, maxOutputHeight: 300)

        XCTAssertFalse(stitcher.imagesAreDuplicate(first, changed))
        XCTAssertEqual(stitcher.append(changed, to: &state), .unchanged)
        XCTAssertEqual(state.segmentCount, 1)
        assertScrollingRows(in: state.image, expectedHeight: 80)
    }

    func testStationaryBlankContentDoesNotInventScrollWhenHeaderChanges() throws {
        let stitcher = ScrollingStitcher()
        let first = makeSolidImage(width: 48, height: 80, color: PixelSample(red: 255, green: 255, blue: 255, alpha: 255))
        let changed = makeRGBAImage(width: 48, height: 80) { x, y in
            let value: UInt8 = x == 20 && y == 3 ? 0 : 255
            return PixelSample(red: value, green: value, blue: value, alpha: 255)
        }
        var state = try stitcher.initialState(with: first, maxOutputHeight: 300)

        XCTAssertEqual(stitcher.append(changed, to: &state), .unchanged)
        XCTAssertEqual(state.outputHeight, 80)
        XCTAssertEqual(state.segmentCount, 1)
    }

    func testStickyHeaderWithShortFinalScrollPreservesBottomRows() throws {
        let stitcher = ScrollingStitcher()
        let first = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 })
        var state = try stitcher.initialState(with: first, maxOutputHeight: 300)

        for offset in [38, 45, 46] {
            let frame = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 < 12 ? $0 : $0 + offset })
            XCTAssertEqual(stitcher.append(frame, to: &state), .appended)
            assertScrollingRows(in: state.image, expectedHeight: 80 + offset)
        }
    }

    func testDuplicateDetectionIncludesUnsampledFinalRowPixels() {
        let first = makeSolidImage(width: 200, height: 400, color: PixelSample(red: 255, green: 255, blue: 255, alpha: 255))
        let changed = makeRGBAImage(width: 200, height: 400) { x, y in
            let value: UInt8 = x == 199 && y == 399 ? 0 : 255
            return PixelSample(red: value, green: value, blue: value, alpha: 255)
        }

        XCTAssertFalse(ScrollingStitcher().imagesAreDuplicate(first, changed))
    }

    func testMaximumHeightDuringShortFinalScrollKeepsOnlyAvailableRows() throws {
        let stitcher = ScrollingStitcher()
        let first = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 })
        let next = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 + 7 })
        var state = try stitcher.initialState(with: first, maxOutputHeight: 85)

        XCTAssertEqual(stitcher.append(next, to: &state), .reachedMaximumHeight)
        assertScrollingRows(in: state.image, expectedHeight: 85)
    }

    func testLowConfidenceMismatchIsRejected() throws {
        let first = makeRGBSolidImage(width: 48, height: 80, red: 20, green: 40, blue: 60)
        let second = makeRGBSolidImage(width: 48, height: 80, red: 220, green: 180, blue: 120)
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

    private func makeRGBSolidImage(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) -> CGImage {
        makeSolidImage(
            width: width,
            height: height,
            color: PixelSample(red: red, green: green, blue: blue, alpha: 255)
        )
    }
}
