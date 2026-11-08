import AppKit
import XCTest
@testable import SnipSnipSnip

@MainActor
final class ClipboardInteractionTests: XCTestCase {
    private func item(_ text: String) -> ClipboardItem {
        ClipboardItem(id: UUID(), kind: .text(text), previewText: text, searchableText: text,
                      sourceApp: nil, copiedAt: Date(), isPinned: false, contentHash: text,
                      byteSize: Int64(text.utf8.count))
    }

    func testDraftsSurviveSelectionChangesAndResetOnlyOneItem() {
        let first = item("one"), second = item("two")
        var drafts = ClipboardDraftStore()
        drafts.setText("edited one", for: first)
        drafts.setText("edited two", for: second)
        XCTAssertEqual(drafts.text(for: first), "edited one")
        drafts.reset(second)
        XCTAssertEqual(drafts.text(for: second), "two")
        XCTAssertEqual(drafts.text(for: first), "edited one")
        drafts.setText("", for: first)
        XCTAssertTrue(drafts.isEdited(first))
        XCTAssertEqual(drafts.text(for: first), "")
        drafts.retainItems([second.id])
        XCTAssertFalse(drafts.isEdited(first))
    }

    func testKeyboardDispatchCopiesDraftAndPreservesNativeEditingKeys() throws {
        let first = item("original"), second = item("second")
        var selected = first
        var drafts = ClipboardDraftStore()
        drafts.setText("edited", for: first)
        let view = ClipboardShortcutView()
        var copied: String?
        var focusedSearch = false
        view.onReturn = { _ in copied = drafts.text(for: selected) }
        view.onMove = { direction in selected = direction == .down ? second : first }
        view.onFocusSearch = { focusedSearch = true }
        func send(_ code: UInt16, _ text: String, _ flags: NSEvent.ModifierFlags = [], _ focus: ClipboardShortcutFocus = .browsing) throws -> Bool {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                isARepeat: false, keyCode: code))
            return view.handle(event, focus: focus)
        }
        XCTAssertTrue(try send(125, String(UnicodeScalar(NSDownArrowFunctionKey)!), [.function, .numericPad]))
        XCTAssertEqual(selected.id, second.id)
        XCTAssertTrue(try send(126, String(UnicodeScalar(NSUpArrowFunctionKey)!)))
        XCTAssertTrue(try send(36, "\r"))
        XCTAssertEqual(copied, "edited")
        copied = nil
        XCTAssertFalse(try send(36, "\r", [], .textEditor))
        XCTAssertNil(copied)
        XCTAssertTrue(try send(36, "\r", .command, .textEditor))
        XCTAssertEqual(copied, "edited")
        XCTAssertFalse(try send(125, String(UnicodeScalar(NSDownArrowFunctionKey)!), [], .textEditor))
        XCTAssertFalse(try send(18, "1", .option, .textEditor))
        XCTAssertFalse(try send(36, "\r", [], .textField))
        XCTAssertFalse(try send(36, "\r", [], .control))
        XCTAssertTrue(try send(53, "\u{1b}", [], .textEditor))
        XCTAssertTrue(focusedSearch)
    }

    func testTextUndoTakesPrecedenceOverDeletionUndo() {
        XCTAssertEqual(ClipboardShortcutPolicy.action(keyCode: 6, characters: "z", modifiers: .command,
            focus: .browsing, hasDeletionUndo: true), .undoDeletion)
        XCTAssertNil(ClipboardShortcutPolicy.action(keyCode: 6, characters: "z", modifiers: .command,
            focus: .textEditor, hasDeletionUndo: true))
        XCTAssertNil(ClipboardShortcutPolicy.action(keyCode: 6, characters: "z", modifiers: .command,
            focus: .textField, hasDeletionUndo: true))
        XCTAssertNil(ClipboardShortcutPolicy.action(keyCode: 6, characters: "z", modifiers: .command,
            focus: .search, hasDeletionUndo: true))
    }

    func testCopyAndReturnShortcutIsDistinctAndPreservesNativeReturn() {
        for focus in [ClipboardShortcutFocus.browsing, .search, .textEditor, .textField, .control] {
            XCTAssertEqual(ClipboardShortcutPolicy.action(keyCode: 36, characters: "\r", modifiers: [.command, .shift],
                focus: focus, hasDeletionUndo: false), .copyAndReturn)
            XCTAssertNil(ClipboardShortcutPolicy.action(keyCode: 36, characters: "\r", modifiers: .shift,
                focus: focus, hasDeletionUndo: false))
        }
        XCTAssertEqual(ClipboardShortcutPolicy.action(keyCode: 76, characters: "\r", modifiers: [.command, .shift],
            focus: .browsing, hasDeletionUndo: false), .copyAndReturn)
    }

    func testCopyAndReturnOnlyActivatesAfterSuccessfulExplicitCopy() {
        var activationCount = 0
        let activate = { activationCount += 1; return true }
        XCTAssertEqual(ClipboardCopyReturnPolicy.finish(copySucceeded: false, requestedReturn: true,
            returnToApplication: activate), .stayed)
        XCTAssertEqual(ClipboardCopyReturnPolicy.finish(copySucceeded: true, requestedReturn: false,
            returnToApplication: activate), .stayed)
        XCTAssertEqual(activationCount, 0)
        XCTAssertEqual(ClipboardCopyReturnPolicy.finish(copySucceeded: true, requestedReturn: true,
            returnToApplication: activate), .returned)
        XCTAssertEqual(activationCount, 1)
        XCTAssertEqual(ClipboardCopyReturnPolicy.finish(copySucceeded: true, requestedReturn: true,
            returnToApplication: { false }), .unavailable)
    }

    func testCopyReturnTargetRejectsSelfMissingAppAndReusedProcessIdentifier() throws {
        let target = WorkspaceRunningApplicationSnapshot(processIdentifier: 100, activationPolicy: .regular,
            bundleIdentifier: "com.example.editor", localizedName: "Editor", bundleURL: URL(fileURLWithPath: "/Applications/Editor.app"))
        XCTAssertNil(ClipboardReturnTarget(application: nil, ownProcessIdentifier: 200))
        XCTAssertNil(ClipboardReturnTarget(application: target, ownProcessIdentifier: 100))
        let captured = try XCTUnwrap(ClipboardReturnTarget(application: target, ownProcessIdentifier: 200))
        XCTAssertNil(captured.availableProcessIdentifier(in: []))
        XCTAssertEqual(captured.availableProcessIdentifier(in: [target]), 100)
        let reused = WorkspaceRunningApplicationSnapshot(processIdentifier: 100, activationPolicy: .regular,
            bundleIdentifier: "com.example.other", localizedName: "Other", bundleURL: URL(fileURLWithPath: "/Applications/Other.app"))
        XCTAssertNil(captured.availableProcessIdentifier(in: [reused]))
        let accessory = WorkspaceRunningApplicationSnapshot(processIdentifier: 300, activationPolicy: .accessory,
            bundleIdentifier: nil, localizedName: nil, bundleURL: nil)
        XCTAssertNil(ClipboardReturnTarget(application: accessory, ownProcessIdentifier: 200))
    }

    func testSpacePreviewsOnlyWhileBrowsing() {
        XCTAssertEqual(ClipboardShortcutPolicy.action(keyCode: 49, characters: " ", modifiers: [],
            focus: .browsing, hasDeletionUndo: false), .preview)
        for focus in [ClipboardShortcutFocus.search, .textEditor, .textField, .control] {
            XCTAssertNil(ClipboardShortcutPolicy.action(keyCode: 49, characters: " ", modifiers: [],
                focus: focus, hasDeletionUndo: false))
        }
    }

    func testSectionsPreservePinnedOrderAndNumberedShortcutTargets() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 12)))
        var entries = (0..<12).map { item("Item \($0)") }
        for index in entries.indices {
            entries[index].copiedAt = now.addingTimeInterval(-Double(index) * 3600)
        }
        entries[0].isPinned = true
        entries[0].copiedAt = now.addingTimeInterval(-86400 * 30)
        entries[1].isPinned = true
        entries[10].copiedAt = now.addingTimeInterval(-86400)
        entries[11].copiedAt = now.addingTimeInterval(-86400 * 2)

        let snapshot = ClipboardHistorySnapshot(items: entries, query: .init(), now: now, calendar: calendar)
        XCTAssertEqual(snapshot.sections.map { $0.entries.count }, [2, 8, 1, 1])
        XCTAssertEqual(snapshot.sections.first?.id, .pinned)
        XCTAssertEqual(snapshot.items.map(\.id), entries.map(\.id))
        let displayed = snapshot.sections.flatMap(\.entries)
        XCTAssertEqual(displayed.map(\.id), snapshot.items.map(\.id))
        XCTAssertEqual(displayed.prefix(9).compactMap(\.shortcutNumber), Array(1...9))
        XCTAssertTrue(displayed.dropFirst(9).allSatisfy { $0.shortcutNumber == nil })

        let filtered = ClipboardHistorySnapshot(items: entries, query: .init(text: "Item 1"), now: now, calendar: calendar)
        XCTAssertEqual(filtered.sections.flatMap(\.entries).map(\.id), [entries[1].id, entries[10].id, entries[11].id])
        XCTAssertEqual(filtered.sections.flatMap(\.entries).compactMap(\.shortcutNumber), [1, 2, 3])
    }

    func testNativeListKeepsBrowsingShortcutsWhileControlsKeepNativeInput() {
        let preview = NSTextView()
        preview.isEditable = false
        let responders: [NSResponder] = [NSTableView(), NSOutlineView(), preview]
        for responder in responders {
            let focus = ClipboardShortcutView.focus(for: responder, isSearchFocused: false)
            XCTAssertEqual(ClipboardShortcutPolicy.action(keyCode: 18, characters: "1", modifiers: .option,
                focus: focus, hasDeletionUndo: false), .copyNumber(1))
            XCTAssertEqual(ClipboardShortcutPolicy.action(keyCode: 36, characters: "\r", modifiers: [],
                focus: focus, hasDeletionUndo: false), .copy)
        }
        let controlFocus = ClipboardShortcutView.focus(for: NSButton(), isSearchFocused: false)
        XCTAssertNil(ClipboardShortcutPolicy.action(keyCode: 36, characters: "\r", modifiers: [],
            focus: controlFocus, hasDeletionUndo: false))
    }

    func testFiltersIntersectWithoutChangingStoredContent() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 12)))
        var matching = item("Original text")
        matching.copiedAt = now
        matching.sourceApp = ClipboardSourceApp(name: "Notes", bundleIdentifier: "com.apple.Notes")
        matching.collectionNames = ["Launch"]
        matching.isPinned = true
        var older = matching
        older.id = UUID()
        older.copiedAt = now.addingTimeInterval(-86400 * 8)
        var otherSource = matching
        otherSource.id = UUID()
        otherSource.sourceApp = nil
        let query = ClipboardHistoryQuery(text: "original", kind: .pinned, time: .sevenDays,
                                          source: "com.apple.Notes", collection: "launch")
        let snapshot = ClipboardHistorySnapshot(items: [matching, older, otherSource], query: query, now: now, calendar: calendar)
        XCTAssertEqual(snapshot.items, [matching])
        XCTAssertEqual(query.secondaryFilterCount, 3)
        XCTAssertTrue(query.isFiltering)
        XCTAssertFalse(ClipboardHistoryQuery().isFiltering)
        XCTAssertTrue(ClipboardHistoryQuery(source: "Notes").matches(matching, now: now, calendar: calendar))
        XCTAssertFalse(ClipboardHistoryQuery(kind: .images).matches(matching, now: now, calendar: calendar))
    }

    func testCalendarSectionsAndTodayFilterAcrossDaylightSavingBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 0, minute: 15)))
        var yesterday = item("Yesterday")
        yesterday.copiedAt = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 0, minute: 30)))
        var today = item("Today")
        today.copiedAt = now
        let snapshot = ClipboardHistorySnapshot(items: [today, yesterday], query: .init(), now: now, calendar: calendar)
        XCTAssertEqual(snapshot.sections.map { $0.title(now: now, calendar: calendar) }, ["Today", "Yesterday"])
        XCTAssertFalse(ClipboardTimeFilter.today.includes(yesterday.copiedAt, now: now, calendar: calendar))
        XCTAssertTrue(ClipboardTimeFilter.today.includes(today.copiedAt, now: now, calendar: calendar))
    }

    func testContentPresentationPreservesPayloadAndSupportsExistingColorFormats() throws {
        var code = item("  let value = 1\n  print(value)  ")
        code.semanticType = .code
        XCTAssertTrue(ClipboardItemPresentation.usesMonospacedText(code))
        XCTAssertTrue(ClipboardItemPresentation.title(for: code).contains("\n"))
        XCTAssertEqual(code.plainTextValue, "  let value = 1\n  print(value)  ")
        XCTAssertFalse(ClipboardItemPresentation.usesMonospacedText(item("A paragraph")))
        for text in ["#F80", "F80", "#FF8800", " #FF8800FF\n", "#F80F"] {
            let color = try XCTUnwrap(ClipboardColorComponents(text: text), text)
            XCTAssertEqual(color.red, 1)
            XCTAssertEqual(color.green, 136.0 / 255.0, accuracy: 0.0001)
            XCTAssertEqual(color.blue, 0)
            XCTAssertEqual(color.alpha, 1)
        }
        XCTAssertEqual(ClipboardColorComponents(text: "#F800")?.alpha, 0)
        XCTAssertEqual(ClipboardColorComponents(text: "#FFFFFF")?.prefersDarkText, true)
        XCTAssertEqual(ClipboardColorComponents(text: "#000000")?.prefersDarkText, false)
        XCTAssertEqual(ClipboardColorComponents(text: "#A3B18A")?.prefersDarkText, true)
        for text in ["", "#12", "#12345", "not a color", "#GGGGGG", "red"] {
            XCTAssertNil(ClipboardColorComponents(text: text))
        }
    }
}
