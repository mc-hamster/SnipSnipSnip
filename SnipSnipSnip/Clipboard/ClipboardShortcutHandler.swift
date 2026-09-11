import AppKit
import SwiftUI

struct ClipboardShortcutHandler: NSViewRepresentable {
    let onNumberShortcut: (Int) -> Void
    let onMove: (MoveCommandDirection) -> Void
    let onReturn: (NSEvent.ModifierFlags) -> Void
    let onUndoDeletion: () -> Void
    let hasDeletionUndo: Bool
    let onFocusSearch: () -> Void
    let isSearchFocused: Bool
    let onEscape: () -> Void

    func makeNSView(context: Context) -> ClipboardShortcutView {
        let view = ClipboardShortcutView()
        configure(view)
        return view
    }

    func updateNSView(_ view: ClipboardShortcutView, context: Context) { configure(view) }

    private func configure(_ view: ClipboardShortcutView) {
        view.onNumberShortcut = onNumberShortcut
        view.onMove = onMove
        view.onReturn = onReturn
        view.onEscape = onEscape
        view.onUndoDeletion = onUndoDeletion
        view.hasDeletionUndo = hasDeletionUndo
        view.onFocusSearch = onFocusSearch
        view.isSearchFocused = isSearchFocused
    }
}

final class ClipboardShortcutView: NSView {
    var onNumberShortcut: ((Int) -> Void)?
    var onMove: ((MoveCommandDirection) -> Void)?
    var onReturn: ((NSEvent.ModifierFlags) -> Void)?
    var onEscape: (() -> Void)?
    var onFocusSearch: (() -> Void)?
    var onUndoDeletion: (() -> Void)?
    var hasDeletionUndo = false
    var isSearchFocused = false
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, window.isKeyWindow,
                  event.window === window, window.attachedSheet == nil else { return event }
            return handle(event, focus: currentFocus) ? nil : event
        }
    }

    private var currentFocus: ClipboardShortcutFocus {
        if let text = window?.firstResponder as? NSTextView {
            if !text.isFieldEditor { return .textEditor }
            return isSearchFocused ? .search : .textField
        }
        return window?.firstResponder is NSControl ? .control : .browsing
    }

    /// Used by the local monitor and by event-level regression tests.
    @discardableResult
    func handle(_ event: NSEvent, focus: ClipboardShortcutFocus) -> Bool {
        guard let action = ClipboardShortcutPolicy.action(
            keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
            modifiers: event.modifierFlags, focus: focus, hasDeletionUndo: hasDeletionUndo
        ) else { return false }
        switch action {
        case .copy: onReturn?(event.modifierFlags)
        case .copyNumber(let number): onNumberShortcut?(number)
        case .previous: onMove?(.up)
        case .next: onMove?(.down)
        case .escape: onEscape?()
        case .focusSearch: onFocusSearch?()
        case .undoDeletion: onUndoDeletion?()
        }
        return true
    }

    deinit {
        MainActor.assumeIsolated {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
