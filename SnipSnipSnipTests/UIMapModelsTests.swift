import CoreGraphics
import XCTest
@testable import SnipSnipSnip

final class UIMapModelsTests: XCTestCase {
    func testOverlayOptionsDefaultToOutlineOnly() {
        let options = UIMapOverlayOptions()

        XCTAssertTrue(options.showsOutline)
        XCTAssertFalse(options.showsLabel)
        XCTAssertFalse(options.showsIdentifier)
        XCTAssertFalse(options.showsRole)
        XCTAssertFalse(options.showsCoordinates)
        XCTAssertFalse(options.showsDimensions)
    }

    func testSearchAndRoleFilteringUseMetadataFields() {
        let button = UIMapElement(
            name: "Save",
            accessibilityLabel: "Save Document",
            accessibilityIdentifier: "save-button",
            role: "AXButton",
            roleDescription: "Button",
            documentRect: CGRect(x: 10, y: 12, width: 80, height: 28),
            owningApplication: "Fixture"
        )
        let textField = UIMapElement(
            name: "Title",
            accessibilityIdentifier: "title-field",
            role: "AXTextField",
            roleDescription: "Text Field",
            documentRect: CGRect(x: 10, y: 52, width: 160, height: 24),
            owningApplication: "Fixture"
        )
        let window = UIMapElement(
            name: "Document",
            role: "AXWindow",
            roleDescription: "Window",
            documentRect: CGRect(x: 0, y: 0, width: 240, height: 180),
            owningApplication: "Fixture",
            children: [button, textField]
        )
        let snapshot = UIMapSnapshot(
            capturedAt: Date(timeIntervalSince1970: 10),
            sourceRect: CGRect(x: 100, y: 100, width: 240, height: 180),
            elements: [window]
        )

        XCTAssertEqual(snapshot.elementCount, 3)
        XCTAssertEqual(snapshot.availableRoles, ["AXButton", "AXTextField", "AXWindow"])
        XCTAssertTrue(button.matches(searchQuery: "save-button", roleFilter: "AXButton"))
        XCTAssertFalse(button.matches(searchQuery: "save-button", roleFilter: "AXTextField"))
        XCTAssertTrue(window.containsMatch(searchQuery: "title-field", roleFilter: nil))
        XCTAssertEqual(snapshot.parentHierarchy(for: textField.id).map(\.displayName), ["Document"])
        XCTAssertTrue(snapshot.searchableText().contains("Save Document"))
    }

    func testShowAllOverlayCandidatesSkipStructuralContainers() {
        let text = UIMapElement(
            name: "Privacy & Security",
            role: "AXStaticText",
            roleDescription: "text",
            documentRect: CGRect(x: 80, y: 20, width: 180, height: 24)
        )
        let button = UIMapElement(
            role: "AXButton",
            roleDescription: "close button",
            documentRect: CGRect(x: 12, y: 12, width: 14, height: 14)
        )
        let anonymousGroup = UIMapElement(
            role: "AXGroup",
            roleDescription: "group",
            documentRect: CGRect(x: 0, y: 0, width: 300, height: 200),
            children: [text]
        )
        let row = UIMapElement(
            name: "Blocked Contacts",
            role: "AXRow",
            roleDescription: "row",
            documentRect: CGRect(x: 40, y: 80, width: 260, height: 44),
            children: [button]
        )
        let anonymousText = UIMapElement(
            role: "AXStaticText",
            roleDescription: "text",
            documentRect: CGRect(x: 0, y: 0, width: 400, height: 52)
        )
        let internalIdentifierText = UIMapElement(
            name: "com.apple.wifi-settings-extension",
            role: "AXStaticText",
            roleDescription: "text",
            documentRect: CGRect(x: 12, y: 96, width: 180, height: 28)
        )
        let scrollValueIndicator = UIMapElement(
            role: "AXValueIndicator",
            roleDescription: "value indicator",
            documentRect: CGRect(x: 300, y: 0, width: 12, height: 180)
        )
        let pageIncrementButton = UIMapElement(
            role: "AXButton",
            roleDescription: "increment page button",
            documentRect: CGRect(x: 300, y: 180, width: 12, height: 180)
        )
        let recognizedSymbol = UIMapElement(
            name: "A",
            role: "AXStaticText",
            roleDescription: "recognized text",
            documentRect: CGRect(x: 320, y: 40, width: 12, height: 18)
        )

        XCTAssertTrue(text.isShowAllOverlayCandidate)
        XCTAssertTrue(button.isShowAllOverlayCandidate)
        XCTAssertFalse(anonymousGroup.isShowAllOverlayCandidate)
        XCTAssertFalse(row.isShowAllOverlayCandidate)
        XCTAssertFalse(anonymousText.isShowAllOverlayCandidate)
        XCTAssertFalse(internalIdentifierText.isShowAllOverlayCandidate)
        XCTAssertFalse(scrollValueIndicator.isShowAllOverlayCandidate)
        XCTAssertFalse(pageIncrementButton.isShowAllOverlayCandidate)
        XCTAssertFalse(recognizedSymbol.isShowAllOverlayCandidate)
        XCTAssertTrue(recognizedSymbol.isRecognizedTextSupplement)
        XCTAssertEqual(recognizedSymbol.source, .ocrSupplement)
        XCTAssertFalse(text.isRecognizedTextSupplement)
        XCTAssertEqual(text.source, .accessibility)
    }

    func testElementSourceCodableDefaultsMissingSourceForLegacyDocuments() throws {
        let sourceElement = UIMapElement(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Recognized",
            role: "AXStaticText",
            roleDescription: "recognized text",
            documentRect: CGRect(x: 10, y: 20, width: 30, height: 40)
        )
        let encodedSourceElement = try JSONEncoder().encode(sourceElement)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedSourceElement) as? [String: Any])
        object.removeValue(forKey: "source")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacyElement = try JSONDecoder().decode(UIMapElement.self, from: legacyData)

        XCTAssertEqual(legacyElement.source, .ocrSupplement)
        XCTAssertTrue(legacyElement.isRecognizedTextSupplement)

        let encoded = try JSONEncoder().encode(legacyElement)
        let decoded = try JSONDecoder().decode(UIMapElement.self, from: encoded)
        XCTAssertEqual(decoded.source, .ocrSupplement)
    }
}
