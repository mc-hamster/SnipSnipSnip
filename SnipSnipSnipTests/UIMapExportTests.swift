import CoreGraphics
import XCTest
@testable import SnipSnipSnip

final class UIMapExportTests: XCTestCase {
    func testExportDocumentIncludesCaptureGeometryAndFlattenedElements() throws {
        let buttonID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let windowID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let button = UIMapElement(
            id: buttonID,
            name: "Advanced...",
            role: "AXButton",
            roleDescription: "button",
            documentRect: CGRect(x: 420, y: 500, width: 90, height: 28),
            owningApplication: "System Settings",
            bundleIdentifier: "com.apple.systempreferences"
        )
        let window = UIMapElement(
            id: windowID,
            name: "Privacy & Security",
            role: "AXWindow",
            roleDescription: "window",
            documentRect: CGRect(x: 0, y: 0, width: 600, height: 540),
            owningApplication: "System Settings",
            bundleIdentifier: "com.apple.systempreferences",
            children: [button]
        )
        let uiMap = UIMapSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            sourceRect: CGRect(x: 40, y: 120, width: 600, height: 540),
            elements: [window],
            diagnostics: UIMapCaptureDiagnosticsSummary(
                axWindowMatchConfidence: 0.92,
                accessibilityElementCount: 2,
                ocrSupplementElementCount: 0,
                didHitBudgetLimit: false,
                didHitTimeLimit: false
            )
        )
        let capture = makeCapturedScreenshot(
            image: makeCoordinateImage(width: 1200, height: 1080),
            kind: .window,
            sourceName: "System Settings - Privacy & Security",
            sourceRect: CGRect(x: 40, y: 120, width: 600, height: 540),
            sourceWindowIdentity: CaptureSourceWindowIdentity(
                windowID: 42,
                ownerName: "System Settings",
                ownerPID: 1234,
                bundleIdentifier: "com.apple.systempreferences",
                title: "Privacy & Security",
                frame: CGRect(x: 40, y: 120, width: 600, height: 540)
            ),
            capturedAt: Date(timeIntervalSince1970: 1_800_000_001),
            uiMap: uiMap
        )

        let export = UIMapExportDocument(
            exportedAt: Date(timeIntervalSince1970: 1_800_000_002),
            capture: capture,
            uiMap: uiMap,
            selectedElementID: buttonID
        )

        XCTAssertEqual(export.schemaVersion, 1)
        XCTAssertEqual(export.sourceName, "System Settings - Privacy & Security")
        XCTAssertEqual(export.captureKind, "window")
        XCTAssertEqual(export.sourceRect, UIMapExportRect(CGRect(x: 40, y: 120, width: 600, height: 540)))
        XCTAssertEqual(export.sourceWindowIdentity?.windowID, 42)
        XCTAssertEqual(export.sourceWindowIdentity?.ownerName, "System Settings")
        XCTAssertEqual(export.sourceWindowIdentity?.bundleIdentifier, "com.apple.systempreferences")
        XCTAssertEqual(export.sourceWindowIdentity?.frame, UIMapExportRect(CGRect(x: 40, y: 120, width: 600, height: 540)))
        XCTAssertEqual(export.documentRect, UIMapExportRect(CGRect(x: 0, y: 0, width: 1200, height: 1080)))
        XCTAssertEqual(export.pixelSize, UIMapExportSize(CGSize(width: 1200, height: 1080)))
        XCTAssertEqual(export.diagnostics?.axWindowMatchConfidence, 0.92)
        XCTAssertEqual(export.diagnostics?.accessibilityElementCount, 2)
        XCTAssertEqual(export.elementCount, 2)
        XCTAssertEqual(export.selectedElementID, buttonID)
        XCTAssertEqual(export.elements.first?.children.first?.id, buttonID)
        XCTAssertEqual(export.elements.first?.source, .accessibility)
        XCTAssertEqual(export.elements.first?.children.first?.source, .accessibility)
        XCTAssertEqual(export.flattenedElements.map(\.id), [windowID, buttonID])
        XCTAssertEqual(export.flattenedElements[1].parentIDs, [windowID])
        XCTAssertEqual(export.flattenedElements.map(\.source), [.accessibility, .accessibility])
        XCTAssertFalse(export.flattenedElements[0].showAllOverlayCandidate)
        XCTAssertTrue(export.flattenedElements[1].showAllOverlayCandidate)

        let encoded = try export.jsonData()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(UIMapExportDocument.self, from: encoded)
        XCTAssertEqual(decoded, export)
    }
}
