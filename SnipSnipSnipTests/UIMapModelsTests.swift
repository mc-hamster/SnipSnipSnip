import CoreGraphics
import XCTest
@testable import SnipSnipSnip

final class UIMapModelsTests: XCTestCase {
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
}
