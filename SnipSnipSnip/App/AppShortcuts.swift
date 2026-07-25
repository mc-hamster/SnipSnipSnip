import SwiftUI

enum AppShortcut {
    static let modifiers: EventModifiers = [.command, .shift]
    static let openWindowKey: KeyEquivalent = "0"

    static let catalogSections: [ShortcutCatalogSection] = [
        ShortcutCatalogSection(title: "App", entries: [
            ShortcutCatalogEntry(keys: "Command-Shift-0", action: "Open SnipSnipSnip"),
            ShortcutCatalogEntry(keys: "Command-Shift-/", action: "Open Help"),
            ShortcutCatalogEntry(keys: "Command-W", action: "Minimize current SnipSnipSnip window"),
            ShortcutCatalogEntry(keys: "Command-Q", action: "Quit or run in background"),
            ShortcutCatalogEntry(keys: "Command-S", action: "Save"),
            ShortcutCatalogEntry(keys: "Shift-Command-S", action: "Save As"),
            ShortcutCatalogEntry(keys: "Command-C", action: "Copy Plain screenshot"),
            ShortcutCatalogEntry(keys: "Command-V", action: "Paste image overlay")
        ]),
        ShortcutCatalogSection(title: "Default Global Capture", entries: [
            ShortcutCatalogEntry(keys: "Command-Shift-1", action: "Capture Region"),
            ShortcutCatalogEntry(keys: "Command-Shift-2", action: "Capture Window"),
            ShortcutCatalogEntry(keys: "Command-Shift-3", action: "Capture Fullscreen"),
            ShortcutCatalogEntry(keys: "Command-Shift-4", action: "Capture Frontmost Window"),
            ShortcutCatalogEntry(keys: "Command-Shift-7", action: "Repeat Last Capture"),
            ShortcutCatalogEntry(keys: "Command-Shift-8", action: "Open Screen Inspector"),
            ShortcutCatalogEntry(keys: "Command-Shift-9", action: "Start or stop Guide")
        ]),
        ShortcutCatalogSection(title: "Editor", entries: [
            ShortcutCatalogEntry(keys: "Command-Z", action: "Undo"),
            ShortcutCatalogEntry(keys: "Shift-Command-Z", action: "Redo"),
            ShortcutCatalogEntry(keys: "Command-A", action: "Select all annotations"),
            ShortcutCatalogEntry(keys: "Shift-Command-A", action: "Unselect annotations"),
            ShortcutCatalogEntry(keys: "Delete", action: "Delete selection"),
            ShortcutCatalogEntry(keys: "Shift-Command-F", action: "Float current screenshot"),
            ShortcutCatalogEntry(keys: "Arrow Keys", action: "Nudge selected annotations 1 px"),
            ShortcutCatalogEntry(keys: "Shift-Arrow Keys", action: "Nudge selected annotations 10 px"),
            ShortcutCatalogEntry(keys: "Option-Arrow Keys", action: "Resize selected annotations 1 px"),
            ShortcutCatalogEntry(keys: "Shift-Option-Arrow Keys", action: "Resize selected annotations 10 px")
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
            ShortcutCatalogEntry(keys: "Return", action: "Paste selected item"),
            ShortcutCatalogEntry(keys: "Command-Return", action: "Copy selected item"),
            ShortcutCatalogEntry(keys: "Shift-Return", action: "Paste selected item as plain text"),
            ShortcutCatalogEntry(keys: "Arrow Keys", action: "Move selection"),
            ShortcutCatalogEntry(keys: "Escape", action: "Clear search, then close Clipboard History"),
            ShortcutCatalogEntry(keys: "Option-1 through Option-9", action: "Copy visible item")
        ])
    ]

    static func catalogSections(includesGuideCapture: Bool) -> [ShortcutCatalogSection] {
        guard !includesGuideCapture else {
            return catalogSections
        }

        return catalogSections.map { section in
            guard section.title == "Default Global Capture" else {
                return section
            }

            return ShortcutCatalogSection(
                title: section.title,
                entries: section.entries.filter { $0.action != "Start or stop Guide" }
            )
        }
    }

    static func catalogSections(
        preferences: CaptureAutomationPreferences,
        includesGuideCapture: Bool
    ) -> [ShortcutCatalogSection] {
        catalogSections(includesGuideCapture: includesGuideCapture).map { section in
            guard section.title == "Default Global Capture" else {
                return section
            }

            let actions = GlobalHotKeyAction.allCases.filter {
                includesGuideCapture || $0 != .guide
            }
            let entries = actions.map { action in
                ShortcutCatalogEntry(
                    keys: "Command-Shift-\(preferences.key(for: action).label)",
                    action: shortcutActionLabel(for: action)
                )
            }
            return ShortcutCatalogSection(title: section.title, entries: entries)
        }
    }

    private static func shortcutActionLabel(for action: GlobalHotKeyAction) -> String {
        switch action {
        case .region: "Capture Region"
        case .window: "Capture Window"
        case .fullscreen: "Capture Fullscreen"
        case .frontmostWindow: "Capture Frontmost Window"
        case .repeatLastCapture: "Repeat Last Capture"
        case .screenInspector: "Open Screen Inspector"
        case .guide: "Start or stop Guide"
        }
    }
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
