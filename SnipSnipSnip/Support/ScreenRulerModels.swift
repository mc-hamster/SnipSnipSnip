import AppKit
import CoreGraphics
import Foundation

enum ScreenRulerKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case horizontal
    case vertical

    var id: String { rawValue }

    var label: String {
        switch self {
        case .horizontal:
            return "Horizontal Ruler"
        case .vertical:
            return "Vertical Ruler"
        }
    }

    var systemImage: String {
        switch self {
        case .horizontal:
            return "ruler"
        case .vertical:
            return "ruler.fill"
        }
    }
}

struct ScreenRulerPreferences: Codable, Equatable, Sendable {
    static let `default` = ScreenRulerPreferences(
        opacity: 0.92,
        tickSpacing: 10,
        majorTickEvery: 5,
        showsHalfMarkers: true,
        showsMouseDistance: true
    )

    var opacity: Double
    var tickSpacing: CGFloat
    var majorTickEvery: Int
    var showsHalfMarkers: Bool
    var showsMouseDistance: Bool

    var opacityDescription: String {
        String(format: "%d%%", Int(round(opacity * 100)))
    }

    var tickSpacingDescription: String {
        "\(Int(round(tickSpacing))) px"
    }
}

extension ScreenRulerPreferences {
    func sanitized() -> ScreenRulerPreferences {
        ScreenRulerPreferences(
            opacity: min(max(opacity, 0.35), 1),
            tickSpacing: min(max(tickSpacing, 4), 50),
            majorTickEvery: min(max(majorTickEvery, 2), 20),
            showsHalfMarkers: showsHalfMarkers,
            showsMouseDistance: showsMouseDistance
        )
    }
}

enum ScreenRulerWindowID {
    static let prefix = "screen-ruler-"

    static func isScreenRulerWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix(prefix) == true
    }
}
