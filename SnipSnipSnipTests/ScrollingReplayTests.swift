import CoreGraphics
import ImageIO
import XCTest
@testable import SnipSnipSnip

/// Deterministic capture sequences: each frame is a viewport onto a known page.
/// Replay failures identify the frame and compare the complete composed raster,
/// including seams, instead of accepting only the final height.
final class ScrollingReplayTests: XCTestCase {
    func testVariableDistanceAndIdleReplayPreservesEveryPixel() throws {
        try replay(offsets: [0, 0, 1, 4, 19, 54, 55, 55, 102, 161, 162], header: 0)
    }

    func testStickyHeaderAndShortTerminalMovementReplay() throws {
        try replay(offsets: [0, 38, 45, 46, 46, 93, 94], header: 12)
    }

    func testLongSmallStepReplayRetainsOnlyAcceptedStrips() throws {
        let stitcher = ScrollingStitcher()
        var state = try stitcher.initialState(
            with: makeNonrepeatingScrollingFrame(width: 48, height: 80, rowMapper: { $0 }),
            maxOutputHeight: 1000
        )
        for offset in 1...200 {
            let frame = makeNonrepeatingScrollingFrame(width: 48, height: 80, rowMapper: { $0 + offset })
            XCTAssertEqual(stitcher.append(frame, to: &state), .appended, "Frame \(offset)")
        }
        XCTAssertEqual(state.outputHeight, 280)
        // Context row alignment is permitted, but retaining 201 full viewports
        // would exceed this by orders of magnitude.
        XCTAssertLessThanOrEqual(state.retainedSegmentBytes, 256 * state.outputHeight)
        let expected = makeNonrepeatingScrollingFrame(width: 48, height: 280, rowMapper: { $0 })
        assertPixels(try XCTUnwrap(state.makeImage()), equalTo: expected)
    }

    func testLocalLayoutShiftIsRejectedEvenWhenGlobalAverageLooksSimilar() throws {
        let stitcher = ScrollingStitcher()
        let first = makeNonrepeatingScrollingFrame(width: 48, height: 240, rowMapper: { $0 })
        // A late-loading element changes only 18 rows of the 72-row scored
        // overlap. The global average can be plausible; its local band is not.
        let next = makeNonrepeatingScrollingFrame(width: 48, height: 240, rowMapper: {
            (48..<66).contains($0) ? $0 + 10_000 : $0 + 120
        })
        var state = try stitcher.initialState(with: first, maxOutputHeight: 1000)
        XCTAssertEqual(stitcher.append(next, to: &state), .lowConfidence)
        XCTAssertEqual(state.outputHeight, 240)
        assertPixels(try XCTUnwrap(state.makeImage()), equalTo: first)
    }

    func testReverseScrollAndMissedOverlapKeepAcceptedContent() throws {
        let stitcher = ScrollingStitcher()
        let first = makeNonrepeatingScrollingFrame(width: 48, height: 80, rowMapper: { $0 + 200 })
        for offset in [150, 400] {
            var state = try stitcher.initialState(with: first, maxOutputHeight: 1000)
            let next = makeNonrepeatingScrollingFrame(width: 48, height: 80, rowMapper: { $0 + offset })
            XCTAssertEqual(stitcher.append(next, to: &state), .lowConfidence)
            assertPixels(try XCTUnwrap(state.makeImage()), equalTo: first)
        }
    }

    /// Opt-in real-app corpus. Keep captured pixels outside Git; use only
    /// disposable pages or explicitly approved captures without private content.
    func testExternalCaptureCorpus() throws {
        guard let path = ProcessInfo.processInfo.environment["SSS_SCROLL_REPLAY_CORPUS"] else {
            throw XCTSkip("Set SSS_SCROLL_REPLAY_CORPUS to a local replay manifest for real-app frames")
        }
        let url = URL(fileURLWithPath: path)
        let corpus = try JSONDecoder().decode(ReplayCorpus.self, from: Data(contentsOf: url))
        XCTAssertFalse(corpus.cases.isEmpty)
        let root = url.deletingLastPathComponent()
        func read(_ name: String) throws -> CGImage {
            let file = root.appendingPathComponent(name).standardizedFileURL
            guard file.path.hasPrefix(root.standardizedFileURL.path + "/") else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
            return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        }
        for sequence in corpus.cases {
            let stitcher = ScrollingStitcher()
            var state = try stitcher.initialState(with: read(sequence.first), maxOutputHeight: sequence.maximumHeight)
            for (index, frame) in sequence.frames.enumerated() {
                let result = stitcher.append(try read(frame.image), to: &state)
                XCTAssertEqual(String(describing: result), frame.result, "\(sequence.name), frame \(index)")
                if let expected = frame.expected { assertPixels(try XCTUnwrap(state.makeImage()), equalTo: try read(expected)) }
            }
            assertPixels(try XCTUnwrap(state.makeImage()), equalTo: try read(sequence.expected))
        }
    }

    private struct ReplayCorpus: Decodable {
        var cases: [Sequence]
        struct Sequence: Decodable {
            var name: String
            var first: String
            var frames: [Frame]
            var expected: String
            var maximumHeight: Int
        }
        struct Frame: Decodable {
            var image: String
            var result: String
            var expected: String?
        }
    }

    private func replay(offsets: [Int], header: Int) throws {
        let stitcher = ScrollingStitcher()
        let first = makeNonrepeatingScrollingFrame(width: 48, height: 80, rowMapper: { $0 })
        var state = try stitcher.initialState(with: first, maxOutputHeight: 1000)
        var acceptedOffset = 0
        for (index, offset) in offsets.dropFirst().enumerated() {
            let frame = makeNonrepeatingScrollingFrame(width: 48, height: 80, rowMapper: {
                $0 < header ? $0 : $0 + offset
            })
            XCTAssertEqual(stitcher.append(frame, to: &state), offset == acceptedOffset ? .unchanged : .appended,
                           "Replay frame \(index + 1), offset \(offset)")
            let expected = makeNonrepeatingScrollingFrame(width: 48, height: 80 + offset, rowMapper: { $0 })
            assertPixels(try XCTUnwrap(state.makeImage()), equalTo: expected)
            acceptedOffset = offset
        }
    }

    private func assertPixels(_ image: CGImage, equalTo expected: CGImage,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(image.width, expected.width, file: file, line: line)
        XCTAssertEqual(image.height, expected.height, file: file, line: line)
        // Normalize bitmap layout and compare all pixels in a single assertion.
        func raster(_ source: CGImage) -> Data? {
            var bytes = [UInt8](repeating: 0, count: source.width * source.height * 4)
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: &bytes, width: source.width, height: source.height,
                    bitsPerComponent: 8, bytesPerRow: source.width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
            return Data(bytes)
        }
        XCTAssertEqual(raster(image), raster(expected), file: file, line: line)
    }
}
