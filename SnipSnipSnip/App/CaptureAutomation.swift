import AppKit
import Foundation

struct CaptureAutomationPreferences: Codable, Equatable {
    var globalHotkeysEnabled = true
    var regionHotkey: GlobalHotKeyKey = .one
    var windowHotkey: GlobalHotKeyKey = .two
    var fullscreenHotkey: GlobalHotKeyKey = .three
    var frontmostWindowHotkey: GlobalHotKeyKey = .four
    var repeatLastCaptureHotkey: GlobalHotKeyKey = .r
    var screenInspectorHotkey: GlobalHotKeyKey = .i

    private enum CodingKeys: String, CodingKey {
        case globalHotkeysEnabled
        case regionHotkey
        case windowHotkey
        case fullscreenHotkey
        case frontmostWindowHotkey
        case repeatLastCaptureHotkey
        case screenInspectorHotkey
    }

    init(
        globalHotkeysEnabled: Bool = true,
        regionHotkey: GlobalHotKeyKey = .one,
        windowHotkey: GlobalHotKeyKey = .two,
        fullscreenHotkey: GlobalHotKeyKey = .three,
        frontmostWindowHotkey: GlobalHotKeyKey = .four,
        repeatLastCaptureHotkey: GlobalHotKeyKey = .r,
        screenInspectorHotkey: GlobalHotKeyKey = .i
    ) {
        self.globalHotkeysEnabled = globalHotkeysEnabled
        self.regionHotkey = regionHotkey
        self.windowHotkey = windowHotkey
        self.fullscreenHotkey = fullscreenHotkey
        self.frontmostWindowHotkey = frontmostWindowHotkey
        self.repeatLastCaptureHotkey = repeatLastCaptureHotkey
        self.screenInspectorHotkey = screenInspectorHotkey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            globalHotkeysEnabled: try container.decodeIfPresent(Bool.self, forKey: .globalHotkeysEnabled) ?? true,
            regionHotkey: try container.decodeIfPresent(GlobalHotKeyKey.self, forKey: .regionHotkey) ?? .one,
            windowHotkey: try container.decodeIfPresent(GlobalHotKeyKey.self, forKey: .windowHotkey) ?? .two,
            fullscreenHotkey: try container.decodeIfPresent(GlobalHotKeyKey.self, forKey: .fullscreenHotkey) ?? .three,
            frontmostWindowHotkey: try container.decodeIfPresent(GlobalHotKeyKey.self, forKey: .frontmostWindowHotkey) ?? .four,
            repeatLastCaptureHotkey: try container.decodeIfPresent(GlobalHotKeyKey.self, forKey: .repeatLastCaptureHotkey) ?? .r,
            screenInspectorHotkey: try container.decodeIfPresent(GlobalHotKeyKey.self, forKey: .screenInspectorHotkey) ?? .i
        )
    }

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
        case .screenInspector:
            return screenInspectorHotkey
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
        case .screenInspector:
            screenInspectorHotkey = key
        }
    }

    var actionKeys: [GlobalHotKeyAction: GlobalHotKeyKey] {
        Dictionary(uniqueKeysWithValues: GlobalHotKeyAction.allCases.map { action in
            (action, key(for: action))
        })
    }
}
