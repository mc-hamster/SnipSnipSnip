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
}
