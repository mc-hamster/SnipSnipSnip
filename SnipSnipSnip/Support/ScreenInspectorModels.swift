import AppKit
import CoreGraphics
import Foundation

enum ScreenInspectorZoomLevel: Int, CaseIterable, Codable, Identifiable, Sendable {
    case two = 2
    case four = 4
    case eight = 8
    case sixteen = 16

    var id: Int { rawValue }

    var label: String {
        "\(rawValue)x"
    }
}

struct ScreenInspectorPreferences: Codable, Equatable, Sendable {
    static let `default` = ScreenInspectorPreferences(
        zoomLevel: .eight,
        showsPixelGrid: false,
        showsCrosshair: false
    )

    var zoomLevel: ScreenInspectorZoomLevel
    var showsPixelGrid: Bool
    var showsCrosshair: Bool

    func sanitized() -> ScreenInspectorPreferences {
        ScreenInspectorPreferences(
            zoomLevel: zoomLevel,
            showsPixelGrid: showsPixelGrid,
            showsCrosshair: showsCrosshair
        )
    }
}

struct ScreenInspectorPixelColor: Equatable, Sendable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var alpha: UInt8

    var hexString: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    var rgbString: String {
        "rgb(\(red), \(green), \(blue))"
    }

    var compactRGBString: String {
        "rgb(\(red),\(green),\(blue))"
    }
}

struct ScreenInspectorSample {
    var image: CGImage
    var cursorLocation: CGPoint
    var sourceRect: CGRect
    var color: ScreenInspectorPixelColor
}

enum ScreenInspectorWindowID {
    static let prefix = "screen-inspector-"
}
