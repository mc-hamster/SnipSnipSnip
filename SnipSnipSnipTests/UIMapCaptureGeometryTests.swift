import CoreGraphics
import XCTest
@testable import SnipSnipSnip

final class UIMapCaptureGeometryTests: XCTestCase {
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
