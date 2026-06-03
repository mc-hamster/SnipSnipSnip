import AppKit
import Foundation

struct CaptureAutomationPreferences: Codable, Equatable {
    var globalHotkeysEnabled = true
    var regionHotkey: GlobalHotKeyKey = .one
    var windowHotkey: GlobalHotKeyKey = .two
    var fullscreenHotkey: GlobalHotKeyKey = .three
    var frontmostWindowHotkey: GlobalHotKeyKey = .four
    var repeatLastCaptureHotkey: GlobalHotKeyKey = .r

    func key(for action: GlobalHotKeyAction) -> GlobalHotKeyKey {
        switch action {
        case .region:
            return regionHotkey
        case .window:
            return windowHotkey
        case .fullscreen:
            return fullscreenHotkey
        case .frontmostWindow:
            return frontmostWindowHotkey
        case .repeatLastCapture:
            return repeatLastCaptureHotkey
        }
    }

    mutating func setKey(_ key: GlobalHotKeyKey, for action: GlobalHotKeyAction) {
        switch action {
        case .region:
            regionHotkey = key
        case .window:
            windowHotkey = key
        case .fullscreen:
            fullscreenHotkey = key
        case .frontmostWindow:
            frontmostWindowHotkey = key
        case .repeatLastCapture:
            repeatLastCaptureHotkey = key
        }
    }

    var actionKeys: [GlobalHotKeyAction: GlobalHotKeyKey] {
        Dictionary(uniqueKeysWithValues: GlobalHotKeyAction.allCases.map { action in
            (action, key(for: action))
        })
    }
}