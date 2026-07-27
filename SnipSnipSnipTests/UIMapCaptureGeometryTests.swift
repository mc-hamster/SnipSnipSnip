import CoreGraphics
import XCTest
@testable import SnipSnipSnip

final class UIMapCaptureGeometryTests: XCTestCase {
    func testPrivateUIMapCaptureEmitsNoContentDiagnostics() async {
        let sink = UIMapDiagnosticSinkSpy()
        let service = AccessibilityUIMapCaptureService(
            capabilities: testCapabilities,
            diagnosticSink: sink
        )
        let capture = makeCapturedScreenshot(kind: .region)

        _ = await service.captureUIMap(
            for: capture,
            isPrivateCapture: true
        )
        XCTAssertTrue(sink.messages.isEmpty)

        _ = await service.captureUIMap(
            for: capture,
            isPrivateCapture: false
        )
        XCTAssertTrue(
            sink.messages.contains {
                $0.contains(capture.sourceName)
            },
            "The spy must observe the normal diagnostic path so the private assertion is meaningful."
        )
    }

    func testSecureRoleAndSubrolePropagateSensitivityWithoutReadingValue() {
        XCTAssertTrue(
            UIMapAccessibilityPrivacy.isSensitive(
                role: "AXSecureTextField",
                subrole: nil,
                ancestorIsSensitive: false
            )
        )
        XCTAssertTrue(
            UIMapAccessibilityPrivacy.isSensitive(
                role: "AXTextField",
                subrole: "AXSecureTextField",
                ancestorIsSensitive: false
            )
        )
        XCTAssertTrue(
            UIMapAccessibilityPrivacy.isSensitive(
                role: "AXStaticText",
                subrole: nil,
                ancestorIsSensitive: true
            )
        )

        var valueWasRequested = false
        let value = UIMapAccessibilityPrivacy.readValueIfAllowed(isSensitive: true) {
            valueWasRequested = true
            return "secret"
        }

        XCTAssertNil(value)
        XCTAssertFalse(valueWasRequested)
    }

    func testCaptureServiceSkipsNonWindowCapturesBeforeAccessibilityWork() async {
        let service = AccessibilityUIMapCaptureService()

        let regionUIMap = await service.captureUIMap(for: makeCapturedScreenshot(kind: .region))
        let fullscreenUIMap = await service.captureUIMap(for: makeCapturedScreenshot(kind: .fullscreen))
        let scrollingUIMap = await service.captureUIMap(for: makeCapturedScreenshot(kind: .scrolling))
        let connectedDeviceUIMap = await service.captureUIMap(for: makeCapturedScreenshot(kind: .connectedDevice))

        XCTAssertNil(regionUIMap)
        XCTAssertNil(fullscreenUIMap)
        XCTAssertNil(scrollingUIMap)
        XCTAssertNil(connectedDeviceUIMap)
    }

    func testCaptureServiceSkipsWindowCaptureWithoutSourceIdentity() async {
        let service = AccessibilityUIMapCaptureService()

        let uiMap = await service.captureUIMap(for: makeCapturedScreenshot(kind: .window))
        XCTAssertNil(uiMap)
    }

    func testWindowRelativeMappingPreservesTopLeftYIntoDocumentSpace() {
        let mapping = UIMapWindowRelativeMapping(
            rootAccessibilityRect: CGRect(x: 100, y: 100, width: 400, height: 300),
            candidateDocumentRect: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        XCTAssertEqual(
            mapping.documentRect(fromAccessibilityRect: CGRect(x: 120, y: 120, width: 40, height: 20)),
            CGRect(x: 40, y: 40, width: 80, height: 40)
        )
        XCTAssertEqual(
            mapping.documentRect(fromAccessibilityRect: CGRect(x: 120, y: 350, width: 40, height: 30)),
            CGRect(x: 40, y: 500, width: 80, height: 60)
        )
    }

    func testWindowRelativeMappingKeepsWindowControlAtTopEdge() {
        let mapping = UIMapWindowRelativeMapping(
            rootAccessibilityRect: CGRect(x: 37, y: 240, width: 723, height: 634),
            candidateDocumentRect: CGRect(x: 0, y: 0, width: 1446, height: 1268)
        )

        XCTAssertEqual(
            mapping.documentRect(fromAccessibilityRect: CGRect(x: 55, y: 258, width: 16, height: 16)),
            CGRect(x: 36, y: 36, width: 32, height: 32)
        )
    }

    func testWindowRelativeMappingClipsToCandidateDocumentRect() {
        let mapping = UIMapWindowRelativeMapping(
            rootAccessibilityRect: CGRect(x: 100, y: 100, width: 400, height: 300),
            candidateDocumentRect: CGRect(x: 10, y: 20, width: 800, height: 600)
        )

        XCTAssertEqual(
            mapping.documentRect(fromAccessibilityRect: CGRect(x: 80, y: 80, width: 80, height: 40)),
            CGRect(x: 10, y: 20, width: 120, height: 40)
        )
    }

    func testWindowRelativeMappingClipsToVisibleDocumentFragments() {
        let mapping = UIMapWindowRelativeMapping(
            rootAccessibilityRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            candidateDocumentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            visibleDocumentRects: [
                CGRect(x: 0, y: 0, width: 200, height: 200),
                CGRect(x: 500, y: 300, width: 200, height: 200)
            ]
        )

        XCTAssertEqual(
            mapping.visibleDocumentRect(fromDocumentRect: CGRect(x: 100, y: 100, width: 100, height: 100)),
            CGRect(x: 100, y: 100, width: 100, height: 100)
        )
        XCTAssertEqual(
            mapping.visibleDocumentRect(fromDocumentRect: CGRect(x: 300, y: 100, width: 100, height: 100)),
            nil
        )
        XCTAssertEqual(
            mapping.visibleDocumentRect(fromDocumentRect: CGRect(x: 450, y: 250, width: 200, height: 200)),
            CGRect(x: 500, y: 300, width: 150, height: 150)
        )
    }

    func testWindowVisibilityPolicyKeepsSmallVisibleFragments() {
        XCTAssertTrue(UIMapWindowVisibilityPolicy.shouldCaptureWindow(visibleArea: 16))
        XCTAssertTrue(UIMapWindowVisibilityPolicy.shouldCaptureWindow(visibleArea: 24))
        XCTAssertFalse(UIMapWindowVisibilityPolicy.shouldCaptureWindow(visibleArea: 15.9))
    }

    func testTextRecognitionGeometryMapsVisionBoundingBoxToDocumentSpace() {
        let rect = UIMapTextRecognitionGeometry.documentRect(
            fromNormalizedBoundingBox: CGRect(x: 0.25, y: 0.70, width: 0.50, height: 0.20),
            imageSize: CGSize(width: 1000, height: 800),
            documentRect: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )

        XCTAssertEqual(rect, CGRect(x: 250, y: 80, width: 500, height: 160))
    }

    func testTextRecognitionGeometryScalesAndClipsToDocumentSpace() {
        let rect = UIMapTextRecognitionGeometry.documentRect(
            fromNormalizedBoundingBox: CGRect(x: 0.90, y: 0.90, width: 0.30, height: 0.30),
            imageSize: CGSize(width: 1000, height: 800),
            documentRect: CGRect(x: 0, y: 0, width: 500, height: 400)
        )

        XCTAssertEqual(rect, CGRect(x: 450, y: 0, width: 50, height: 40))
    }
}

private final class UIMapDiagnosticSinkSpy:
    CaptureContentDiagnosticSink,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedMessages: [String] = []

    var messages: [String] {
        lock.withLock { storedMessages }
    }

    nonisolated func emit(
        level: CaptureContentDiagnosticLevel,
        category: String,
        message: String
    ) {
        _ = level
        _ = category
        lock.withLock {
            storedMessages.append(message)
        }
    }
}
