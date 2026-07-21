import AppKit
import Foundation

nonisolated struct GuideObservedEvent: Equatable, Sendable {
    enum Payload: Equatable, Sendable {
        case mouseDown(button: Int, clickCount: Int)
        case selection
        case scroll(deltaX: Double, deltaY: Double)
        case swipe(deltaX: Double, deltaY: Double)
        case keyDown(keyCode: UInt16, modifiers: UInt64, characters: String?, isRepeat: Bool)
        case textChanged
        case manual
        case cursorMoved
    }

    var timestamp: TimeInterval
    var location: CGPoint
    var payload: Payload
}

nonisolated enum GuideClassifiedEvent: Equatable, Sendable {
    case click
    case doubleClick
    case selection
    case textEntry
    case scroll(direction: String, distance: Double)
    case gesture(direction: String)
    case shortcut(String)
    case manual
    case ignored
}

nonisolated struct GuideEventClassifier: Sendable {
    static let scrollQuietInterval: TimeInterval = 0.35
    static let gestureQuietInterval: TimeInterval = 0.5
    static let textEntryQuietInterval: TimeInterval = 0.65

    func classify(_ event: GuideObservedEvent, guideShortcutKeyCode: UInt16? = nil) -> GuideClassifiedEvent {
        switch event.payload {
        case .mouseDown(_, let clickCount):
            return clickCount >= 2 ? .doubleClick : .click
        case .selection:
            return .selection
        case .scroll(let deltaX, let deltaY):
            let isVertical = abs(deltaY) >= abs(deltaX)
            let distance = isVertical ? deltaY : deltaX
            let direction: String
            if isVertical {
                direction = distance < 0 ? "down" : "up"
            } else {
                direction = distance < 0 ? "right" : "left"
            }
            return .scroll(direction: direction, distance: abs(distance))
        case .swipe(let deltaX, let deltaY):
            guard deltaX != 0 || deltaY != 0 else { return .ignored }
            if abs(deltaX) >= abs(deltaY) {
                return .gesture(direction: deltaX > 0 ? "left" : "right")
            }
            return .gesture(direction: deltaY > 0 ? "up" : "down")
        case .keyDown(let keyCode, let modifiers, let characters, let isRepeat):
            let significantModifiers = modifiers & UInt64(
                NSEvent.ModifierFlags.command.rawValue
                    | NSEvent.ModifierFlags.option.rawValue
                    | NSEvent.ModifierFlags.control.rawValue
                    | NSEvent.ModifierFlags.shift.rawValue
            )
            let guideModifiers = UInt64(
                NSEvent.ModifierFlags.command.rawValue
                    | NSEvent.ModifierFlags.shift.rawValue
            )
            if keyCode == guideShortcutKeyCode, significantModifiers == guideModifiers { return .ignored }
            let shortcutModifiers = significantModifiers & UInt64(
                NSEvent.ModifierFlags.command.rawValue
                    | NSEvent.ModifierFlags.option.rawValue
                    | NSEvent.ModifierFlags.control.rawValue
            )
            if shortcutModifiers != 0 {
                guard !isRepeat else { return .ignored }
                return .shortcut(Self.shortcutLabel(characters: characters, modifiers: significantModifiers))
            }
            return Self.isTextInput(characters) ? .textEntry : .ignored
        case .textChanged:
            return .textEntry
        case .manual:
            return .manual
        case .cursorMoved:
            return .ignored
        }
    }

    private static func shortcutLabel(characters: String?, modifiers: UInt64) -> String {
        var parts: [String] = []
        if modifiers & UInt64(NSEvent.ModifierFlags.control.rawValue) != 0 { parts.append("Control") }
        if modifiers & UInt64(NSEvent.ModifierFlags.option.rawValue) != 0 { parts.append("Option") }
        if modifiers & UInt64(NSEvent.ModifierFlags.shift.rawValue) != 0 { parts.append("Shift") }
        if modifiers & UInt64(NSEvent.ModifierFlags.command.rawValue) != 0 { parts.append("Command") }
        if let characters, !characters.isEmpty { parts.append(characters.uppercased()) }
        return parts.joined(separator: "-")
    }

    private static func isTextInput(_ characters: String?) -> Bool {
        guard let characters, !characters.isEmpty else { return false }
        return characters.unicodeScalars.contains { !CharacterSet.controlCharacters.contains($0) }
    }
}
