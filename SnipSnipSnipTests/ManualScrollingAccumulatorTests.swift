import CoreGraphics
import XCTest
@testable import SnipSnipSnip

final class ManualScrollingAccumulatorTests: XCTestCase {
    func testReversalsRevisitRowsWithoutDuplication() async throws {
        try await replay([0, 30, 60, 40, 20, 50, 90], expectedStart: 0, expectedHeight: 170)
    }

    func testUpwardScrollingExtendsBeginningInDocumentOrder() async throws {
        try await replay([100, 80, 40, 20, 0, 40, 80, 100], expectedStart: 0, expectedHeight: 180)
    }

    func testUpwardExtensionKeepsStickyHeaderOnlyOnce() async throws {
        func sticky(_ offset: Int) -> CGImage {
            makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 < 12 ? $0 : $0 + offset })
        }
        var accumulator = try ManualScrollingAccumulator(first: sticky(100), maximumHeight: 1000, stitcher: ScrollingStitcher())
        for offset in [80, 40, 20, 0, 40, 80, 100] {
            let (updated, result) = await accumulator.processing(sticky(offset))
            XCTAssertNotEqual(result, .lowConfidence)
            accumulator = updated
        }
        assertScrollingRows(in: try XCTUnwrap(accumulator.state.makeImage()), expectedHeight: 180)
    }

    func testContinuousVariableSpeedAndIdleFramesPreserveEveryRow() async throws {
        try await replay([0, 1, 4, 4, 4, 20, 55, 110, 111, 153], expectedStart: 0, expectedHeight: 233)
    }

    func testAnimatedCornerDoesNotRequireIdenticalConsecutiveFrames() async throws {
        var accumulator = try ManualScrollingAccumulator(first: frame(0), maximumHeight: 1000, stitcher: ScrollingStitcher())
        for offset in stride(from: 5, through: 100, by: 5) {
            let image = makeRGBAImage(width: 48, height: 80) { x, y in
                x == 47 && y == 0 ? PixelSample(red: UInt8(offset), green: 0, blue: 0, alpha: 255)
                    : scrollingPixel(x: x, y: y + offset)
            }
            let (updated, result) = await accumulator.processing(image)
            accumulator = updated
            XCTAssertEqual(result, .appended)
        }
        assertScrollingRows(in: try XCTUnwrap(accumulator.state.makeImage()), expectedHeight: 180)
    }

    func testUnmatchedFramesDoNotChangeReferenceAndCanReconnect() async throws {
        var accumulator = try ManualScrollingAccumulator(first: frame(0), maximumHeight: 1000, stitcher: ScrollingStitcher())
        for offset in [5000, 10000, 15000] {
            let image = makeNonrepeatingScrollingFrame(width: 48, height: 80, rowMapper: { $0 + offset })
            let (updated, result) = await accumulator.processing(image)
            accumulator = updated
            XCTAssertEqual(result, .lowConfidence)
            XCTAssertEqual(accumulator.state.outputHeight, 80)
        }
        let (updated, result) = await accumulator.processing(frame(50))
        XCTAssertEqual(result, .appended)
        assertScrollingRows(in: try XCTUnwrap(updated.state.makeImage()), expectedHeight: 130)
    }

    func testPrependingAtCapacityKeepsAdjacentRowsWithoutGap() async throws {
        let initial = try ManualScrollingAccumulator(first: frame(100), maximumHeight: 100, stitcher: ScrollingStitcher())
        let (updated, result) = await initial.processing(frame(50))
        XCTAssertEqual(result, .reachedMaximumHeight)
        let image = try XCTUnwrap(updated.state.makeImage())
        XCTAssertEqual(image.height, 100)
        for y in 0..<100 { XCTAssertEqual(samplePixel(in: image, topLeftX: 10, topLeftY: y), scrollingPixel(x: 10, y: y + 80)) }
    }

    func testContinuousTextPageMatchingMeetsInteractiveFrameBudget() async throws {
        var accumulator = try ManualScrollingAccumulator(
            first: makeScrollingTextPage(width: 2590, height: 1236, offset: 0),
            maximumHeight: 60_000, stitcher: ScrollingStitcher()
        )
        var precedingOffset = 0
        for offset in [200, 500, 350, 650] {
            let frame = makeScrollingTextPage(width: 2590, height: 1236, offset: offset)
            let start = DispatchTime.now().uptimeNanoseconds
            let (updated, result) = await accumulator.processing(frame)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            XCTAssertTrue(PerformanceBudgetCatalog.scrollingFrameStitch.contains(elapsed), "Manual alignment took \(elapsed)s")
            let previous = makeScrollingTextPage(width: 2590, height: 1236, offset: precedingOffset)
            let matcher = ScrollingStitcher()
            XCTAssertNotEqual(result, .lowConfidence, "Offset \(offset), forward=\(String(describing: matcher.bestMatch(previous: previous, next: frame))), backward=\(String(describing: matcher.bestMatch(previous: frame, next: previous)))")
            accumulator = updated
            precedingOffset = offset
        }
        XCTAssertEqual(accumulator.state.outputHeight, 1886)
    }

    func testInvalidStripCannotBeClippedThenStretchedIntoInventedRows() {
        XCTAssertNil(ScrollingStitcher().ownedStrip(frame(0), startY: 70, height: 20))
        XCTAssertNil(ScrollingStitcher().ownedStrip(frame(0), startY: -1, height: 20))
    }

    func testFrameQueueIsBoundedAndRetainsChronologicalRecentFrames() throws {
        let buffer = ScrollingFrameBuffer(width: 1920, height: 1080)
        XCTAssertEqual(buffer.capacity, 8)
        for offset in 0..<12 { buffer.offer(frame(offset)) }
        for offset in 4..<12 {
            let image = try XCTUnwrap(buffer.take())
            XCTAssertEqual(samplePixel(in: image, topLeftX: 10, topLeftY: 0), scrollingPixel(x: 10, y: offset))
        }
        XCTAssertNil(try buffer.take())
        buffer.close()
        buffer.offer(frame(99))
        XCTAssertNil(try buffer.take())
        XCTAssertEqual(ScrollingFrameBuffer(width: 8000, height: 4000).capacity, 1)
    }

    private func replay(_ offsets: [Int], expectedStart: Int, expectedHeight: Int) async throws {
        var accumulator = try ManualScrollingAccumulator(first: frame(offsets[0]), maximumHeight: 1000, stitcher: ScrollingStitcher())
        for offset in offsets.dropFirst() {
            let (updated, result) = await accumulator.processing(frame(offset))
            XCTAssertNotEqual(result, .lowConfidence, "Offset \(offset)")
            accumulator = updated
        }
        let image = try XCTUnwrap(accumulator.state.makeImage())
        XCTAssertEqual(image.height, expectedHeight)
        for y in 0..<image.height {
            for x in [0, 24, 47] { XCTAssertEqual(samplePixel(in: image, topLeftX: x, topLeftY: y), scrollingPixel(x: x, y: y + expectedStart)) }
        }
    }
    private func frame(_ offset: Int) -> CGImage { makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 + offset }) }
}
