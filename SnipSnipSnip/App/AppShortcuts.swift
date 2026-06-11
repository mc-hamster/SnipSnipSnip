import SwiftUI

enum AppShortcut {
    static let modifiers: EventModifiers = [.command, .shift]
    static let openWindowKey: KeyEquivalent = "o"

    static let catalogSections: [ShortcutCatalogSection] = [
        ShortcutCatalogSection(title: "App", entries: [
            ShortcutCatalogEntry(keys: "Command-Shift-O", action: "Open SnipSnipSnip"),
            ShortcutCatalogEntry(keys: "Command-Shift-/", action: "Open Help"),
            ShortcutCatalogEntry(keys: "Command-W", action: "Minimize current SnipSnipSnip window"),
            ShortcutCatalogEntry(keys: "Command-Q", action: "Minimize current SnipSnipSnip window"),
            ShortcutCatalogEntry(keys: "Command-S", action: "Save"),
            ShortcutCatalogEntry(keys: "Shift-Command-S", action: "Save As"),
            ShortcutCatalogEntry(keys: "Command-C", action: "Copy rendered screenshot"),
            ShortcutCatalogEntry(keys: "Command-V", action: "Paste image overlay")
        ]),
        ShortcutCatalogSection(title: "Default Global Capture", entries: [
            ShortcutCatalogEntry(keys: "Command-Shift-1", action: "Capture Region"),
            ShortcutCatalogEntry(keys: "Command-Shift-2", action: "Capture Window"),
            ShortcutCatalogEntry(keys: "Command-Shift-3", action: "Capture Fullscreen"),
            ShortcutCatalogEntry(keys: "Command-Shift-4", action: "Capture Frontmost Window"),
            ShortcutCatalogEntry(keys: "Command-Shift-R", action: "Repeat Last Capture"),
            ShortcutCatalogEntry(keys: "Command-Shift-I", action: "Open Screen Inspector")
        ]),
        ShortcutCatalogSection(title: "Editor", entries: [
            ShortcutCatalogEntry(keys: "Command-Z", action: "Undo"),
            ShortcutCatalogEntry(keys: "Shift-Command-Z", action: "Redo"),
            ShortcutCatalogEntry(keys: "Command-A", action: "Select all annotations"),
            ShortcutCatalogEntry(keys: "Delete", action: "Delete selection"),
            ShortcutCatalogEntry(keys: "Shift-Command-F", action: "Float current screenshot"),
            ShortcutCatalogEntry(keys: "Arrow Keys", action: "Nudge selected annotations 1 px"),
            ShortcutCatalogEntry(keys: "Shift-Arrow Keys", action: "Nudge selected annotations 10 px")
        ]),
        ShortcutCatalogSection(title: "Editor Tools", entries: [
            ShortcutCatalogEntry(keys: "V", action: "Select"),
            ShortcutCatalogEntry(keys: "R", action: "Rectangle"),
            ShortcutCatalogEntry(keys: "O", action: "Ellipse"),
            ShortcutCatalogEntry(keys: "L", action: "Line"),
            ShortcutCatalogEntry(keys: "A", action: "Arrow"),
            ShortcutCatalogEntry(keys: "P", action: "Freehand"),
            ShortcutCatalogEntry(keys: "H", action: "Highlighter"),
            ShortcutCatalogEntry(keys: "B", action: "Highlight Box"),
            ShortcutCatalogEntry(keys: "T", action: "Text"),
            ShortcutCatalogEntry(keys: "C", action: "Callout"),
            ShortcutCatalogEntry(keys: "M", action: "Ruler"),
            ShortcutCatalogEntry(keys: "S", action: "Spotlight"),
            ShortcutCatalogEntry(keys: "X", action: "Redaction")
        ]),
        ShortcutCatalogSection(title: "Layers", entries: [
            ShortcutCatalogEntry(keys: "Command-G", action: "Group selection"),
            ShortcutCatalogEntry(keys: "Shift-Command-G", action: "Ungroup selection"),
            ShortcutCatalogEntry(keys: "Command-]", action: "Bring forward"),
            ShortcutCatalogEntry(keys: "Command-[", action: "Send backward"),
            ShortcutCatalogEntry(keys: "Option-Command-]", action: "Bring to front"),
            ShortcutCatalogEntry(keys: "Option-Command-[", action: "Send to back"),
            ShortcutCatalogEntry(keys: "Shift-Command-L", action: "Show Layers")
        ]),
        ShortcutCatalogSection(title: "Screen Inspector", entries: [
            ShortcutCatalogEntry(keys: "Space", action: "Freeze or resume sampling"),
            ShortcutCatalogEntry(keys: "Option-Command-S", action: "Snip to editor"),
            ShortcutCatalogEntry(keys: "Option-Command-H", action: "Copy HEX color"),
            ShortcutCatalogEntry(keys: "Option-Command-R", action: "Copy RGB color"),
            ShortcutCatalogEntry(keys: "Option-Command-M", action: "Measure point-to-point distance"),
            ShortcutCatalogEntry(keys: "Escape", action: "Close Screen Inspector")
        ]),
        ShortcutCatalogSection(title: "Clipboard History", entries: [
            ShortcutCatalogEntry(keys: "Return", action: "Copy and paste selected item"),
            ShortcutCatalogEntry(keys: "Arrow Keys", action: "Move selection"),
            ShortcutCatalogEntry(keys: "Option-1 through Option-9", action: "Copy visible item")
        ])
    ]
}

struct ShortcutCatalogSection: Identifiable, Equatable {
    var id: String { title }
    let title: String
    let entries: [ShortcutCatalogEntry]
}

struct ShortcutCatalogEntry: Identifiable, Equatable {
    var id: String { "\(keys)-\(action)" }
    let keys: String
    let action: String
}
