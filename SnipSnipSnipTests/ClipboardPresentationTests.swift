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
        XCTAssertTrue(fixture.model.actionMessage?.contains("preserved") == true)
        XCTAssertEqual(fixture.store.items.first?.plainTextValue, item.plainTextValue)
    }

    func testBrowserControlsFitDefaultAndMinimumSizesInBothAppearances() async throws {
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
                try await Task.sleep(for: .milliseconds(200))
                view.layoutSubtreeIfNeeded()
                let visible = window.convertToScreen(view.convert(view.bounds, to: nil)).insetBy(dx: -1, dy: -1)
                for identifier in ["clipboard.search", "clipboard.scope", "clipboard.filters", "clipboard.monitoring",
                                   "clipboard.actions", "clipboard.copy"] {
                    let element = try XCTUnwrap(HostedViewTestSupport.find(identifier, in: view), identifier)
                    let frame = element.accessibilityFrame()
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

    func testContentPreviewsInBothAppearances() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for (name, query) in [("Link", "developer.apple.com"), ("Image", "Design reference"),
                                  ("Color", "#A3B18A"), ("Text", "Keep the content")] {
                fixture.model.searchQuery = query
                let view = NSHostingView(rootView: ClipboardManagerView(clipboard: fixture.model))
                view.appearance = NSAppearance(named: appearance)
                let window = HostedViewTestSupport.host(view, size: CGSize(width: 520, height: 720))
                defer { window.close() }
                try await Task.sleep(for: .milliseconds(150))
                view.layoutSubtreeIfNeeded()
                let preview = try XCTUnwrap(HostedViewTestSupport.find("clipboard.preview", in: view))
                XCTAssertTrue(preview.accessibilityPerformPress())
                try await Task.sleep(for: .milliseconds(250))
                XCTAssertNotNil(HostedViewTestSupport.find("clipboard.inspector", in: view))
                XCTAssertNil(HostedViewTestSupport.find("clipboard.textEditor", in: view))
                add(try HostedViewTestSupport.attachment(of: view, name: "Clipboard \(name) \(appearance.rawValue)"))
            }
        }
    }

    func testFilterPopoverKeepsSelectedValuesAfterTheirLastItemDisappears() async throws {
        let view = NSHostingView(rootView: ClipboardFilterPopover(
            time: .constant(.sevenDays), source: .constant("Removed Source"), collection: .constant("Removed Collection"),
            sources: [], collections: [], dismiss: {}))
        let window = HostedViewTestSupport.host(view, size: CGSize(width: 370, height: 270))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        add(try HostedViewTestSupport.attachment(of: view, name: "Clipboard active filters"))
        XCTAssertLessThanOrEqual(view.fittingSize.width, 370)
        XCTAssertLessThanOrEqual(view.fittingSize.height, 270)
    }

    func testEditingFilteringCopyingAndResetUseTheSamePerItemDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let original = try XCTUnwrap(fixture.store.items.first)
        let view = NSHostingView(rootView: ClipboardManagerView(clipboard: fixture.model))
        let window = HostedViewTestSupport.host(view, size: CGSize(width: 520, height: 720))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        let preview = try XCTUnwrap(HostedViewTestSupport.find("clipboard.preview", in: view))
        XCTAssertTrue(preview.accessibilityPerformPress())
        try await Task.sleep(for: .milliseconds(250))
        let edit = try XCTUnwrap(HostedViewTestSupport.find("clipboard.editText", in: view))
        XCTAssertTrue(edit.accessibilityPerformPress())
        try await Task.sleep(for: .milliseconds(100))
        let editor = try XCTUnwrap(HostedViewTestSupport.descendants(NSTextView.self, in: view).first { !$0.isFieldEditor })
        editor.string = "A temporary draft"
        editor.didChangeText()
        try await Task.sleep(for: .milliseconds(100))
        let copy = try XCTUnwrap(HostedViewTestSupport.find("clipboard.copy", in: view))
        XCTAssertTrue(copy.accessibilityPerformPress())
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "A temporary draft")
        XCTAssertEqual(fixture.store.items.first?.plainTextValue, original.plainTextValue)

        let done = try XCTUnwrap(HostedViewTestSupport.find("clipboard.finishEditing", in: view))
        XCTAssertTrue(done.accessibilityPerformPress())
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(HostedViewTestSupport.find("clipboard.textEditor", in: view))
        XCTAssertTrue(copy.accessibilityPerformPress())
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "A temporary draft")

        let back = try XCTUnwrap(HostedViewTestSupport.find("clipboard.back", in: view))
        XCTAssertTrue(back.accessibilityPerformPress())
        try await Task.sleep(for: .milliseconds(250))
        let card = try XCTUnwrap(HostedViewTestSupport.find("clipboard.item.\(original.id.uuidString)", in: view))
        XCTAssertTrue(card.accessibilityPerformPress())
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "A temporary draft")
        fixture.model.searchQuery = "#A3B18A"
        try await Task.sleep(for: .milliseconds(100))
        fixture.model.searchQuery = "let count"
        try await Task.sleep(for: .milliseconds(100))
        let previewAgain = try XCTUnwrap(HostedViewTestSupport.find("clipboard.preview", in: view))
        XCTAssertTrue(previewAgain.accessibilityPerformPress())
        try await Task.sleep(for: .milliseconds(250))
        let editAgain = try XCTUnwrap(HostedViewTestSupport.find("clipboard.editText", in: view))
        XCTAssertTrue(editAgain.accessibilityPerformPress())
        try await Task.sleep(for: .milliseconds(100))
        let restored = try XCTUnwrap(HostedViewTestSupport.descendants(NSTextView.self, in: view).first { !$0.isFieldEditor })
        XCTAssertEqual(restored.string, "A temporary draft")
        let reset = try XCTUnwrap(HostedViewTestSupport.find("clipboard.resetDraft", in: view))
        XCTAssertTrue(reset.accessibilityPerformPress())
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(restored.string, original.plainTextValue)
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
            store.recordLink("https://developer.apple.com/design/", title: "Apple Design Resources", searchableText: "design",
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
