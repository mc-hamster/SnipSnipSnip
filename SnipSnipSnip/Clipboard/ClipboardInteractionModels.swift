import AppKit
import Foundation

/// Temporary edits belong to an item, not to the currently selected row.
struct ClipboardDraftStore {
    private var values: [UUID: String] = [:]

    func text(for item: ClipboardItem) -> String {
        values[item.id] ?? item.plainTextValue ?? ""
    }

    func isEdited(_ item: ClipboardItem) -> Bool {
        item.supportsPlainTextSanitization && text(for: item) != (item.plainTextValue ?? "")
    }

    mutating func setText(_ text: String, for item: ClipboardItem) {
        values[item.id] = text == item.plainTextValue ? nil : text
    }

    mutating func reset(_ item: ClipboardItem) { values[item.id] = nil }
    mutating func retainItems(_ ids: Set<UUID>) { values = values.filter { ids.contains($0.key) } }
    mutating func removeAll() { values.removeAll() }
}

enum ClipboardShortcutFocus {
    case browsing, search, textEditor, textField, control
}

enum ClipboardShortcutAction: Equatable {
    case copy, copyNumber(Int), previous, next, preview, escape, focusSearch, undoDeletion
}

enum ClipboardShortcutPolicy {
    static func action(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags,
                       focus: ClipboardShortcutFocus, hasDeletionUndo: Bool) -> ClipboardShortcutAction? {
        let modifiers = modifiers.intersection([.command, .control, .option, .shift])
        let browsing = focus == .browsing || focus == .search
        if modifiers == .option, browsing,
           let characters, let number = Int(characters), (1...9).contains(number) {
            return .copyNumber(number)
        }
        if modifiers == .command, characters == "z", focus == .browsing, hasDeletionUndo { return .undoDeletion }
        switch keyCode {
        case 49 where modifiers.isEmpty && focus == .browsing: return .preview
        case 125 where modifiers.isEmpty && browsing: return .next
        case 126 where modifiers.isEmpty && browsing: return .previous
        case 36, 76:
            if modifiers == .command || (modifiers.isEmpty && browsing) { return .copy }
        case 53 where modifiers.isEmpty:
            return focus == .textEditor || focus == .textField ? .focusSearch : .escape
        default: break
        }
        return nil
    }
}

struct ClipboardPendingDeletion: Codable {
    let item: ClipboardItem
    let expiresAt: Date
}
