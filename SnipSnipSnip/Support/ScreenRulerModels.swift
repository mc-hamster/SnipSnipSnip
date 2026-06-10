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

enum ScreenRulerHorizontalTickEdge: String, CaseIterable, Codable, Identifiable, Sendable {
    case top
    case bottom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .top:
            return "Top"
        case .bottom:
            return "Bottom"
        }
    }

    var toggled: ScreenRulerHorizontalTickEdge {
        switch self {
        case .top:
            return .bottom
        case .bottom:
            return .top
        }
    }
}

enum ScreenRulerVerticalTickEdge: String, CaseIterable, Codable, Identifiable, Sendable {
    case left
    case right

    var id: String { rawValue }

    var label: String {
        switch self {
        case .left:
            return "Left"
        case .right:
            return "Right"
        }
    }

    var toggled: ScreenRulerVerticalTickEdge {
        switch self {
        case .left:
            return .right
        case .right:
            return .left
        }
    }
}

enum ScreenRulerHorizontalOrigin: String, CaseIterable, Codable, Identifiable, Sendable {
    case left
    case right

    var id: String { rawValue }

    var label: String {
        switch self {
        case .left:
            return "Left"
        case .right:
            return "Right"
        }
    }

    var toggled: ScreenRulerHorizontalOrigin {
        switch self {
        case .left:
            return .right
        case .right:
            return .left
        }
    }
}

enum ScreenRulerVerticalOrigin: String, CaseIterable, Codable, Identifiable, Sendable {
    case top
    case bottom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .top:
            return "Top"
        case .bottom:
            return "Bottom"
        }
    }

    var toggled: ScreenRulerVerticalOrigin {
        switch self {
        case .top:
            return .bottom
        case .bottom:
            return .top
        }
    }
}

struct ScreenRulerPreferences: Codable, Equatable, Sendable {
    static let `default` = ScreenRulerPreferences(
        opacity: 0.92,
        tickSpacing: 10,
        majorTickEvery: 5,
        showsHalfMarkers: true,
        showsMouseDistance: true,
        horizontalTickEdge: .bottom,
        verticalTickEdge: .left,
        horizontalOrigin: .left,
        verticalOrigin: .top
    )

    var opacity: Double
    var tickSpacing: CGFloat
    var majorTickEvery: Int
    var showsHalfMarkers: Bool
    var showsMouseDistance: Bool
    var horizontalTickEdge: ScreenRulerHorizontalTickEdge
    var verticalTickEdge: ScreenRulerVerticalTickEdge
    var horizontalOrigin: ScreenRulerHorizontalOrigin
    var verticalOrigin: ScreenRulerVerticalOrigin

    init(
        opacity: Double,
        tickSpacing: CGFloat,
        majorTickEvery: Int,
        showsHalfMarkers: Bool,
        showsMouseDistance: Bool,
        horizontalTickEdge: ScreenRulerHorizontalTickEdge = .bottom,
        verticalTickEdge: ScreenRulerVerticalTickEdge = .left,
        horizontalOrigin: ScreenRulerHorizontalOrigin = .left,
        verticalOrigin: ScreenRulerVerticalOrigin = .top
    ) {
        self.opacity = opacity
        self.tickSpacing = tickSpacing
        self.majorTickEvery = majorTickEvery
        self.showsHalfMarkers = showsHalfMarkers
        self.showsMouseDistance = showsMouseDistance
        self.horizontalTickEdge = horizontalTickEdge
        self.verticalTickEdge = verticalTickEdge
        self.horizontalOrigin = horizontalOrigin
        self.verticalOrigin = verticalOrigin
    }

    private enum CodingKeys: String, CodingKey {
        case opacity
        case tickSpacing
        case majorTickEvery
        case showsHalfMarkers
        case showsMouseDistance
        case horizontalTickEdge
        case verticalTickEdge
        case horizontalOrigin
        case verticalOrigin
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        opacity = try container.decode(Double.self, forKey: .opacity)
        tickSpacing = try container.decode(CGFloat.self, forKey: .tickSpacing)
        majorTickEvery = try container.decode(Int.self, forKey: .majorTickEvery)
        showsHalfMarkers = try container.decode(Bool.self, forKey: .showsHalfMarkers)
        showsMouseDistance = try container.decode(Bool.self, forKey: .showsMouseDistance)
        horizontalTickEdge = try container.decodeIfPresent(ScreenRulerHorizontalTickEdge.self, forKey: .horizontalTickEdge) ?? .bottom
        verticalTickEdge = try container.decodeIfPresent(ScreenRulerVerticalTickEdge.self, forKey: .verticalTickEdge) ?? .left
        horizontalOrigin = try container.decodeIfPresent(ScreenRulerHorizontalOrigin.self, forKey: .horizontalOrigin) ?? .left
        verticalOrigin = try container.decodeIfPresent(ScreenRulerVerticalOrigin.self, forKey: .verticalOrigin) ?? .top
    }

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
            showsMouseDistance: showsMouseDistance,
            horizontalTickEdge: horizontalTickEdge,
            verticalTickEdge: verticalTickEdge,
            horizontalOrigin: horizontalOrigin,
            verticalOrigin: verticalOrigin
        )
    }
}

enum ScreenRulerWindowID {
    static let prefix = "screen-ruler-"

    static func isScreenRulerWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix(prefix) == true
    }
}
