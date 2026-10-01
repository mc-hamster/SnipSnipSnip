import XCTest
@testable import SnipSnipSnip

@MainActor
final class SettingsSearchTests: XCTestCase {
    private var capabilities: AppCapabilitySnapshot {
        AppCapabilitySnapshot(buildTarget: .current, enabledCapabilities: Set(AppCapability.allCases))
    }

    func testPhraseAndSeparatedTokensFindExactControlAndNestedClipboardPage() throws {
        let jpeg = try XCTUnwrap(SettingsSearchResult.search(" JPEG quality ", capabilities: capabilities).first)
        XCTAssertEqual(jpeg.id, "editorOutput.jpegQuality")
        XCTAssertEqual(jpeg.section, "Export & Sharing")
        XCTAssertEqual(SettingsSearchResult.search("quality jpeg", capabilities: capabilities).first?.id, jpeg.id)
        let clipboard = try XCTUnwrap(SettingsSearchResult.search("enable clipboard", capabilities: capabilities).first)
        XCTAssertEqual(clipboard.tab, .library)
        XCTAssertEqual(clipboard.libraryPage, .clipboard)
        XCTAssertEqual(clipboard.id, "library.clipboardEnabled")
        XCTAssertEqual(SettingsSearchResult.search("drag out format", capabilities: capabilities).first?.id,
                       "editorOutput.dragFormat")
    }

    func testSearchCatalogHasUniqueNavigationTargetsAndRespectsBuildCapabilities() {
        XCTAssertEqual(Set(SettingsSearchResult.catalog.map(\.id)).count, SettingsSearchResult.catalog.count)
        let limited = AppCapabilitySnapshot(buildTarget: .current, enabledCapabilities: [.editor, .export])
        XCTAssertTrue(SettingsSearchResult.search("guide", capabilities: limited).isEmpty)
        XCTAssertTrue(SettingsSearchResult.search("record keyboard", capabilities: limited).isEmpty)
        XCTAssertTrue(SettingsSearchResult.search("", capabilities: capabilities).isEmpty)
        XCTAssertTrue(SettingsSearchResult.search("never-a-setting", capabilities: capabilities).isEmpty)
    }

    func testWindowSearchMatchesAppAndTitleWithoutChangingWindowOrder() {
        func window(_ id: UInt32, app: String, title: String) -> CaptureWindowSummary {
            CaptureWindowSummary(id: id, ownerName: app, ownerPID: 100, title: title,
                frame: CGRect(x: 0, y: 0, width: 800, height: 600), layer: 0, focusRank: 0, thumbnail: nil)
        }
        let windows = [window(1, app: "Safari", title: "Design review"),
                       window(2, app: "Notes", title: "Design notes"),
                       window(3, app: "Safari", title: "Résumé")]
        XCTAssertEqual(windows.filter { CaptureWindowSearch.matches($0, query: "safari design") }.map(\.id), [1])
        XCTAssertEqual(windows.filter { CaptureWindowSearch.matches($0, query: "design") }.map(\.id), [1, 2])
        XCTAssertEqual(windows.filter { CaptureWindowSearch.matches($0, query: "resume") }.map(\.id), [3])
        XCTAssertEqual(windows.filter { CaptureWindowSearch.matches($0, query: " ") }.map(\.id), [1, 2, 3])
        XCTAssertTrue(windows.filter { CaptureWindowSearch.matches($0, query: "xcode") }.isEmpty)
        XCTAssertNotEqual(CaptureWindowPickerPurpose.screenshot.selectionHint, CaptureWindowPickerPurpose.video.selectionHint)
        XCTAssertTrue(WindowSelectionPrompt.video.instructionText.contains("Video"))
        XCTAssertNotEqual(WindowSelectionPrompt.video.targetActionHelp, WindowSelectionPrompt.capture.targetActionHelp)
    }
}
