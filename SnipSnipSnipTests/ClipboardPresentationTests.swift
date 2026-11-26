import AppKit
import SwiftUI
import XCTest
@testable import SnipSnipSnip

@MainActor
final class ClipboardPresentationTests: XCTestCase {
    func testCopyFeedbackUsesActualOutcomeAndPreservesPreviousClipboardOnFailure() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let item = try XCTUnwrap(fixture.store.items.first)
        XCTAssertTrue(fixture.model.copyItem(item))
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), item.plainTextValue)
        XCTAssertTrue(fixture.model.copyEditedText("Edited draft"))
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "Edited draft")
        var unavailable = item
        unavailable.kind = .image(assetName: "missing.png")
        unavailable.storedPayload = nil
        XCTAssertFalse(fixture.model.copyItem(unavailable))
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "Edited draft")
        XCTAssertEqual(fixture.model.actionMessage, "This item could not be copied. Try again.")
        XCTAssertEqual(fixture.store.items.first?.plainTextValue, item.plainTextValue)
    }

    func testBrowserControlsFitDefaultAndMinimumSizesInBothAppearances() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for size in [CGSize(width: 520, height: 720), CGSize(width: 400, height: 460)] {
                let compact = size.width == 400
                let view = NSHostingView(rootView: ClipboardManagerView(clipboard: fixture.model))
                let resolvedAppearance = compact
                    ? (appearance == .aqua ? NSAppearance.Name.accessibilityHighContrastAqua : .accessibilityHighContrastDarkAqua)
                    : appearance
                view.appearance = NSAppearance(named: resolvedAppearance)
                let window = HostedViewTestSupport.host(view, size: size)
                defer { window.close() }
                for identifier in ["clipboard.search", "clipboard.scope", "clipboard.filters", "clipboard.monitoring",
                                   "clipboard.actions", "clipboard.copy", "clipboard.copyAndReturn"] {
                    let element = try control(identifier, in: view)
                    let frame = element.accessibilityFrame()
                    let visible = window.convertToScreen(view.convert(view.bounds, to: nil)).insetBy(dx: -1, dy: -1)
                    XCTAssertGreaterThan(frame.width, 0, identifier)
                    XCTAssertGreaterThan(frame.height, 0, identifier)
                    XCTAssertTrue(visible.contains(frame), "\(identifier) outside window: \(frame), visible: \(visible)")
                }
                XCTAssertNil(HostedViewTestSupport.find("clipboard.inspector", in: view))
                XCTAssertNil(HostedViewTestSupport.find("clipboard.textEditor", in: view))
                add(try HostedViewTestSupport.attachment(of: view,
                    name: "Clipboard \(appearance.rawValue) \(Int(size.width))x\(Int(size.height))"))
            }
        }
    }

    func testContentPreviewsInBothAppearances() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for (name, query) in [("Link", "developer.apple.com"), ("Image", "Design reference"),
                                  ("Color", "#A3B18A"), ("Text", "Keep the content")] {
                fixture.model.searchQuery = query
                XCTAssertEqual(fixture.model.items.filter { $0.matchesSearchQuery(query) }.count, 1,
                               "The \(name) preview fixture must match its search query.")
                let view = NSHostingView(rootView: ClipboardManagerView(clipboard: fixture.model))
                view.appearance = NSAppearance(named: appearance)
                let window = HostedViewTestSupport.host(view, size: CGSize(width: 520, height: 720))
                defer { window.close() }
                let preview = try control("clipboard.preview", in: view)
                XCTAssertTrue(preview.accessibilityPerformPress())
                _ = try control("clipboard.inspector", in: view)
                XCTAssertNil(HostedViewTestSupport.find("clipboard.textEditor", in: view))
                add(try HostedViewTestSupport.attachment(of: view, name: "Clipboard \(name) \(appearance.rawValue)"))
            }
        }
    }

    func testFilterPopoverKeepsSelectedValuesAfterTheirLastItemDisappears() throws {
        let view = NSHostingView(rootView: ClipboardFilterPopover(
            time: .constant(.sevenDays), source: .constant("Removed Source"), collection: .constant("Removed Collection"),
            sources: [], collections: [], dismiss: {}))
        let window = HostedViewTestSupport.host(view, size: CGSize(width: 370, height: 270))
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        add(try HostedViewTestSupport.attachment(of: view, name: "Clipboard active filters"))
        XCTAssertLessThanOrEqual(view.fittingSize.width, 370)
        XCTAssertLessThanOrEqual(view.fittingSize.height, 270)
    }

    func testEditingFilteringCopyingAndResetUseTheSamePerItemDraft() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let original = try XCTUnwrap(fixture.store.items.first)
        let view = NSHostingView(rootView: ClipboardManagerView(clipboard: fixture.model))
        let window = HostedViewTestSupport.host(view, size: CGSize(width: 520, height: 720))
        defer { window.close() }
        let preview = try control("clipboard.preview", in: view)
        XCTAssertTrue(preview.accessibilityPerformPress())
        let edit = try control("clipboard.editText", in: view)
        XCTAssertTrue(edit.accessibilityPerformPress())
        let editor = try presented(in: view, "Clipboard text editor") {
            HostedViewTestSupport.descendants(NSTextView.self, in: view).first { !$0.isFieldEditor }
        }
        editor.string = "A temporary draft"
        editor.didChangeText()
        _ = try presented(in: view, "Reset becomes available for an edited draft") {
            let button = HostedViewTestSupport.find("clipboard.resetDraft", in: view)
            return button?.isAccessibilityEnabled() == true ? button : nil
        }
        let copy = try control("clipboard.copy", in: view)
        XCTAssertTrue(copy.accessibilityPerformPress())
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "A temporary draft")
        XCTAssertEqual(fixture.store.items.first?.plainTextValue, original.plainTextValue)

        let done = try control("clipboard.finishEditing", in: view)
        XCTAssertTrue(done.accessibilityPerformPress())
        _ = try control("clipboard.textPreview", in: view)
        XCTAssertNil(HostedViewTestSupport.find("clipboard.textEditor", in: view))
        XCTAssertTrue(try control("clipboard.copy", in: view).accessibilityPerformPress())
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "A temporary draft")

        let back = try control("clipboard.back", in: view)
        XCTAssertTrue(back.accessibilityPerformPress())
        let cardID = "clipboard.item.\(original.id.uuidString)"
        let card = try control(cardID, in: view)
        XCTAssertTrue(card.accessibilityPerformPress())
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "A temporary draft")
        fixture.model.searchQuery = "#A3B18A"
        let color = try XCTUnwrap(fixture.store.items.first { $0.plainTextValue == "#A3B18A" })
        _ = try control("clipboard.item.\(color.id.uuidString)", in: view)
        fixture.model.searchQuery = "let count"
        _ = try control(cardID, in: view)
        let previewAgain = try control("clipboard.preview", in: view)
        XCTAssertTrue(previewAgain.accessibilityPerformPress())
        let editAgain = try control("clipboard.editText", in: view)
        XCTAssertTrue(editAgain.accessibilityPerformPress())
        let restored = try presented(in: view, "Reopened clipboard text editor") {
            HostedViewTestSupport.descendants(NSTextView.self, in: view).first { !$0.isFieldEditor }
        }
        XCTAssertEqual(restored.string, "A temporary draft")
        XCTAssertTrue(try control("clipboard.resetDraft", in: view).accessibilityPerformPress())
        _ = try presented(in: view, "Reset restores the original clipboard text") {
            restored.string == original.plainTextValue ? restored : nil
        }
    }

    private func control(
        _ identifier: String,
        in view: NSView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> any NSAccessibilityProtocol {
        try presented(in: view, identifier, file: file, line: line) {
            HostedViewTestSupport.find(identifier, in: view)
        }
    }

    private func presented<T>(
        in view: NSView,
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        value: () -> T?
    ) throws -> T {
        let deadline = ContinuousClock.now + .seconds(3)
        repeat {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            view.layoutSubtreeIfNeeded()
            if let result = value() { return result }
        } while ContinuousClock.now < deadline
        return try XCTUnwrap(nil as T?, description, file: file, line: line)
    }

    @MainActor private final class Fixture {
        let root: URL
        let suite: String
        let defaults: UserDefaults
        let pasteboard = TestPasteboardService()
        let store: ClipboardHistoryStore
        let model: ClipboardWorkflowModel

        init() throws {
            suite = "ClipboardPresentationTests-\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
            store = ClipboardHistoryStore(baseURL: root, keyProvider: TestClipboardEncryptionKeyProvider())
            let preferences = ClipboardPreferenceStore(storage: defaults)
            var enabled = ClipboardPreferences.default
            enabled.isEnabled = true
            preferences.savePreferences(enabled)
            let workspace = TestWorkspaceService()
            model = ClipboardWorkflowModel(dependencies: ClipboardWorkflowDependencies(
                systemServices: .live(permissions: TestCapturePermissionService()),
                ignoredAppPresenter: LiveClipboardIgnoredAppPresenter(),
                managerPresenter: LiveClipboardManagerPresenter(workspace: workspace)), historyStore: store,
                monitor: ClipboardMonitor(store: store, pasteboard: pasteboard, workspace: workspace),
                pasteboard: pasteboard, preferenceStore: preferences)
            let now = Date()
            store.recordText("Keep the content clear, and make the next action easy to find.",
                sourceApp: ClipboardSourceApp(name: "Notes", bundleIdentifier: "com.apple.Notes"),
                preferences: enabled, copiedAt: now.addingTimeInterval(-86400))
            store.recordText("#A3B18A", sourceApp: ClipboardSourceApp(name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode"),
                             preferences: enabled, copiedAt: now.addingTimeInterval(-240))
            store.recordLink("https://developer.apple.com/design/", title: "Apple Design Resources",
                sourceApp: ClipboardSourceApp(name: "Safari", bundleIdentifier: "com.apple.Safari"),
                preferences: enabled, copiedAt: now.addingTimeInterval(-180))
            store.recordText("{\"appearance\":\"system\",\"previews\":true}", sourceApp: nil,
                             preferences: enabled, copiedAt: now.addingTimeInterval(-120))
            store.recordImageData(try ImageExporter.pngData(for: CompositionUITestFixture.capture(ordinal: 0).image),
                sourceApp: ClipboardSourceApp(name: "Preview", bundleIdentifier: "com.apple.Preview"),
                preferences: enabled, copiedAt: now.addingTimeInterval(-90), title: "Design reference")
            store.recordText("let count = items.count\nprint(count)", sourceApp: ClipboardSourceApp(name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode"),
                             preferences: enabled, copiedAt: now.addingTimeInterval(-60))
            if let first = store.items.first {
                store.togglePinned(first)
                store.addCollection("Design", for: first)
            }
        }

        func cleanUp() {
            model.monitor.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
