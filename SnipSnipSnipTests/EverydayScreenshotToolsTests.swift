import AppKit
import ImageIO
import XCTest
@testable import SnipSnipSnip

@MainActor
final class EverydayScreenshotToolsTests: XCTestCase {
    func testTextLayoutPreservesLinesIndentationAndParagraphGaps() {
        let layout = RecognizedTextLayout(lines: [
            line("done", x: 0, y: 65, width: 40),
            line("print()", x: 40, y: 20, width: 70),
            line("if ready:", x: 0, y: 0, width: 90)
        ])
        XCTAssertEqual(layout.formattedText, "if ready:\n    print()\n\ndone")
        XCTAssertEqual(RecognizedTextFormatting.paragraph(layout.formattedText), "if ready: print() done")
        XCTAssertEqual(RecognizedTextLayout(lines: []).formattedText, "")
    }

    func testVisionCoordinatesBecomeTopLeftPixels() {
        let rect = VisionTextLayoutRecognizer.pixelRect(CGRect(x: 0.1, y: 0.6, width: 0.3, height: 0.2), in: CGSize(width: 200, height: 100))
        XCTAssertEqual(rect.minX, 20, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 20, accuracy: 0.001)
        XCTAssertEqual(rect.width, 60, accuracy: 0.001)
        XCTAssertEqual(rect.height, 20, accuracy: 0.001)
    }

    func testDirectTextCaptureCopiesLinesAndMarksPrivateOutput() async throws {
        let pasteboard = TestPasteboardService()
        let service = TextCaptureService(recognizer: FixedTextRecognizer(text: "if ready:\n    run()"))
        try await service.copyText(in: makeCapturedScreenshot().image, isPrivate: true, pasteboard: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "if ready:\n    run()")
        XCTAssertTrue(ClipboardPasteboardReader.containsSensitiveOrTransientType(pasteboard.typeNames))
        XCTAssertNil(pasteboard.data(forType: .png))
        try await service.copyText(in: makeCapturedScreenshot().image, isPrivate: false, pasteboard: pasteboard)
        XCTAssertFalse(ClipboardPasteboardReader.containsSensitiveOrTransientType(pasteboard.typeNames))
    }

    func testEmptyTextAndFailedWriteDoNotClaimSuccessOrReplaceClipboard() async {
        let pasteboard = TestPasteboardService()
        pasteboard.setString("Keep me", forType: .string)
        let count = pasteboard.changeCount
        do {
            try await TextCaptureService(recognizer: FixedTextRecognizer(text: " \n ")).copyText(
                in: makeCapturedScreenshot().image, isPrivate: false, pasteboard: pasteboard)
            XCTFail("Empty OCR must not copy")
        } catch { XCTAssertTrue(error is TextCaptureError) }
        XCTAssertEqual(pasteboard.changeCount, count)
        pasteboard.failNextSnapshotWrite()
        XCTAssertThrowsError(try TextCaptureService.writeText("New", isPrivate: false, pasteboard: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "Keep me")
    }

    func testTextCaptureShortcutRoundTripsAndLegacyPreferencesDecode() throws {
        let decoded = try JSONDecoder().decode(CaptureAutomationPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.key(for: .textCapture), .t)
        var preferences = decoded
        preferences.setKey(.six, for: .textCapture)
        XCTAssertEqual(try JSONDecoder().decode(CaptureAutomationPreferences.self,
            from: JSONEncoder().encode(preferences)), preferences)
        XCTAssertEqual(GlobalHotKeyAction.defaultKeys[.textCapture], .t)
    }

    func testSmartHighlightFitsOnlyCrossedWordsAndSupportsReverseStrokes() {
        let words = [RecognizedTextWord(text: "one", rect: CGRect(x: 10, y: 10, width: 20, height: 12)),
                     RecognizedTextWord(text: "two", rect: CGRect(x: 50, y: 10, width: 20, height: 12))]
        let lines = [RecognizedTextLine(text: "one two", rect: CGRect(x: 10, y: 10, width: 60, height: 12), confidence: 1, words: words)]
        let points = [CGPoint(x: 8, y: 16), CGPoint(x: 31, y: 17)]
        let result = SmartHighlightGeometry.fittedRects(points: points, lines: lines)
        XCTAssertEqual(result.count, 1)
        XCTAssertLessThan(result[0].maxX, 40)
        XCTAssertGreaterThan(result[0].height, 12)
        XCTAssertEqual(result, SmartHighlightGeometry.fittedRects(points: Array(points.reversed()), lines: lines))
        XCTAssertTrue(SmartHighlightGeometry.fittedRects(points: [CGPoint(x: 0, y: 60), CGPoint(x: 80, y: 60)], lines: lines).isEmpty)
        let uncertain = RecognizedTextLine(text: "unclear", rect: lines[0].rect, confidence: 0.2, words: words)
        XCTAssertTrue(SmartHighlightGeometry.fittedRects(points: points, lines: [uncertain]).isEmpty)
    }

    func testSmartHighlightUsesOneUndoStepAndKeepsOriginalPixels() async {
        let controller = EditorController(capture: makeCapturedScreenshot(), capabilities: testCapabilities)
        let original = controller.capture.image
        controller.addDrawnAnnotation(stroke(), recognizer: FixedLayoutRecognizer(layout: highlightLayout))
        await waitUntil { controller.persistenceRevision >= 2 }
        XCTAssertEqual(controller.snapshot.annotations.count, 1)
        guard case let .highlighter(fitted) = controller.snapshot.annotations[0].kind else { return XCTFail("Expected highlighter") }
        XCTAssertEqual(fitted.points.count, 2)
        controller.undo()
        XCTAssertTrue(controller.snapshot.annotations.isEmpty)
        controller.redo()
        XCTAssertEqual(controller.snapshot.annotations.count, 1)
        XCTAssertEqual(normalizedRGBAPixels(controller.capture.image), normalizedRGBAPixels(original))
    }

    func testLateSmartHighlightCannotChangeNewerEdits() async {
        let controller = EditorController(capture: makeCapturedScreenshot(), capabilities: testCapabilities)
        let drawn = stroke()
        let recognizer = DelayedLayoutRecognizer(layout: highlightLayout)
        controller.addDrawnAnnotation(drawn, recognizer: recognizer)
        controller.addAnnotation(.makeHighlight(in: CGRect(x: 1, y: 1, width: 4, height: 4)))
        let expected = controller.snapshot
        await waitUntil { recognizer.finished }
        await Task.yield()
        XCTAssertEqual(controller.snapshot, expected)
        XCTAssertEqual(controller.snapshot.annotations.first, drawn)
    }

    func testManualHighlighterDoesNotRequestRecognition() async {
        let controller = EditorController(capture: makeCapturedScreenshot(), capabilities: testCapabilities)
        controller.smartHighlightEnabled = false
        let drawn = stroke()
        controller.addDrawnAnnotation(drawn, recognizer: FixedLayoutRecognizer(layout: highlightLayout))
        await Task.yield()
        XCTAssertEqual(controller.snapshot.annotations, [drawn])
        controller.undo()
        XCTAssertTrue(controller.snapshot.annotations.isEmpty)
    }

    func testOutputSizePreservesProportionsAndBoundsAllocations() throws {
        let size = CGSize(width: 1600, height: 900)
        XCTAssertEqual(try ScreenshotOutputSize.original.pixelSize(for: size), size)
        XCTAssertEqual(try ScreenshotOutputSize.half.pixelSize(for: size), CGSize(width: 800, height: 450))
        XCTAssertEqual(try ScreenshotOutputSize.customWidth(1200).pixelSize(for: size), CGSize(width: 1200, height: 675))
        XCTAssertEqual(try ScreenshotOutputSize.half.pixelSize(for: CGSize(width: 1, height: 1)), CGSize(width: 1, height: 1))
        XCTAssertThrowsError(try ScreenshotOutputSize.customWidth(0).pixelSize(for: size))
        XCTAssertThrowsError(try ScreenshotOutputSize.customWidth(Int.max).pixelSize(for: size))
        XCTAssertThrowsError(try ScreenshotOutputSize.customWidth(32_768).pixelSize(for: CGSize(width: 1, height: 1)))
        XCTAssertThrowsError(try ScreenshotOutputSize.half.pixelSize(for: CGSize(width: CGFloat.infinity, height: 10)))
    }

    func testCopyDragAndRenderUseSameSizeWithoutChangingDocumentOrAutomation() async throws {
        let controller = EditorController(capture: makeCapturedScreenshot(), capabilities: testCapabilities)
        let originalSession = controller.documentSession
        let originalPixels = normalizedRGBAPixels(controller.capture.image)
        controller.screenshotOutputSize = .half
        let rendered = try await controller.renderedImageForExport(appearance: .plain, usesOutputSize: true)
        XCTAssertEqual(rendered.width, controller.capture.image.width / 2)
        let pasteboard = TestPasteboardService()
        var copied: Bool?
        controller.copyAnnotatedImage(appearance: .plain, pasteboard: pasteboard) { copied = $0 }
        await waitUntil { copied != nil }
        XCTAssertEqual(copied, true)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(try XCTUnwrap(pasteboard.data(forType: .png)) as CFData, nil))
        let copiedImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(normalizedRGBAPixels(copiedImage), normalizedRGBAPixels(rendered))
        let payload = try XCTUnwrap(controller.promisedImagePayload(appearance: .plain, requestedFormat: .png, filenameTemplate: .default))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("EverydayTools-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: file) }
        try await payload.write(to: file)
        let fileSource = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
        let draggedImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(fileSource, 0, nil))
        XCTAssertEqual(normalizedRGBAPixels(draggedImage), normalizedRGBAPixels(rendered))
        XCTAssertEqual(controller.documentSession, originalSession)
        XCTAssertEqual(normalizedRGBAPixels(controller.capture.image), originalPixels)
        let automationImage = try await controller.renderedImageForExport(appearance: .plain)
        XCTAssertEqual(automationImage.width, controller.capture.image.width)
        XCTAssertEqual(try controller.exportedImage(appearance: .plain).width, controller.capture.image.width)
    }

    private func line(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat) -> RecognizedTextLine {
        RecognizedTextLine(text: text, rect: CGRect(x: x, y: y, width: width, height: 12), confidence: 1)
    }
    private var highlightLayout: RecognizedTextLayout {
        RecognizedTextLayout(lines: [line("hello", x: 10, y: 10, width: 30)])
    }
    private func stroke() -> Annotation {
        .makeHighlighter(points: [CGPoint(x: 8, y: 16), CGPoint(x: 25, y: 17), CGPoint(x: 42, y: 16)])
    }
}

nonisolated private struct FixedTextRecognizer: CaptureTextRecognizing {
    let text: String
    func recognizeText(in image: CGImage) async throws -> String { text }
}

nonisolated private struct FixedLayoutRecognizer: TextLayoutRecognizing {
    let layout: RecognizedTextLayout
    func recognizeLayout(in image: CGImage) async throws -> RecognizedTextLayout { layout }
}

@MainActor
private final class DelayedLayoutRecognizer: TextLayoutRecognizing {
    let layout: RecognizedTextLayout
    var finished = false
    init(layout: RecognizedTextLayout) { self.layout = layout }
    func recognizeLayout(in image: CGImage) async throws -> RecognizedTextLayout {
        try await Task.sleep(for: .milliseconds(30))
        return await MainActor.run {
            finished = true
            return layout
        }
    }
}
