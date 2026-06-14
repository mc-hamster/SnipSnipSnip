import AppKit
import CoreGraphics

nonisolated enum EditorWorkspaceMode: String, CaseIterable, Identifiable {
    case edit
    case presentation

    var id: String { rawValue }

    var label: String {
        switch self {
        case .edit:
            return "Edit"
        case .presentation:
            return "Presentation"
        }
    }

    var systemImage: String {
        switch self {
        case .edit:
            return "pencil.and.outline"
        case .presentation:
            return "rectangle.on.rectangle.angled"
        }
    }
}

nonisolated enum ScreenshotPresentationPreset: String, CaseIterable, Identifiable {
    case plain
    case lifted
    case transparentShadow

    var id: String { rawValue }

    var label: String {
        switch self {
        case .plain:
            return "Plain"
        case .lifted:
            return "Canvas"
        case .transparentShadow:
            return "Drop Shadow"
        }
    }

    var settings: ScreenshotPresentation {
        switch self {
        case .plain:
            return .plain
        case .lifted:
            return ScreenshotPresentation(
                isEnabled: true,
                background: .solid(RGBAColor(red: 0.90, green: 0.92, blue: 0.95, alpha: 1)),
                padding: 52,
                cornerRadius: 18,
                shadow: .strong
            )
        case .transparentShadow:
            return ScreenshotPresentation(
                isEnabled: true,
                background: .transparent,
                padding: 24,
                cornerRadius: 8,
                shadow: .drop
            )
        }
    }
}

nonisolated enum PresentationCanvasPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case square
    case portraitFourFive
    case widescreen
    case story
    case landscapeWide

    var id: String { rawValue }

    var label: String {
        switch self {
        case .square:
            return "Square"
        case .portraitFourFive:
            return "4:5"
        case .widescreen:
            return "16:9"
        case .story:
            return "9:16"
        case .landscapeWide:
            return "1.91:1"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .square:
            return "Square canvas"
        case .portraitFourFive:
            return "Four by five portrait canvas"
        case .widescreen:
            return "Sixteen by nine widescreen canvas"
        case .story:
            return "Nine by sixteen vertical canvas"
        case .landscapeWide:
            return "One point nine one by one landscape canvas"
        }
    }

    var aspectRatio: CGFloat {
        switch self {
        case .square:
            return 1
        case .portraitFourFive:
            return 4 / 5
        case .widescreen:
            return 16 / 9
        case .story:
            return 9 / 16
        case .landscapeWide:
            return 1.91
        }
    }
}

/// Legacy/native style canvas sizing retained for `.sss` compatibility.
/// Current Presentation UI leaves native Styles at their default output size;
/// richer fixed layouts should be expressed as SVG Presentation Scenes.
nonisolated enum PresentationCanvas: Equatable, Codable, Sendable {
    case original
    case preset(PresentationCanvasPreset)
    case custom(width: Int, height: Int)

    private enum CodingKeys: String, CodingKey {
        case kind
        case preset
        case width
        case height
    }

    var label: String {
        switch self {
        case .original:
            return "Original"
        case let .preset(preset):
            return preset.label
        case let .custom(width, height):
            return "\(width)x\(height)"
        }
    }

    var fixedSize: CGSize? {
        switch self {
        case .original, .preset:
            return nil
        case let .custom(width, height):
            return CGSize(width: max(width, 1), height: max(height, 1))
        }
    }

    var aspectRatio: CGFloat? {
        switch self {
        case .original, .custom:
            return nil
        case let .preset(preset):
            return preset.aspectRatio
        }
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "original"

        switch kind {
        case "preset":
            self = .preset(try container.decodeIfPresent(PresentationCanvasPreset.self, forKey: .preset) ?? .square)
        case "custom":
            let width = max(try container.decodeIfPresent(Int.self, forKey: .width) ?? 1200, 1)
            let height = max(try container.decodeIfPresent(Int.self, forKey: .height) ?? 800, 1)
            self = .custom(width: width, height: height)
        default:
            self = .original
        }
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .original:
            try container.encode("original", forKey: .kind)
        case let .preset(preset):
            try container.encode("preset", forKey: .kind)
            try container.encode(preset, forKey: .preset)
        case let .custom(width, height):
            try container.encode("custom", forKey: .kind)
            try container.encode(max(width, 1), forKey: .width)
            try container.encode(max(height, 1), forKey: .height)
        }
    }
}

nonisolated enum PresentationSubjectFit: String, CaseIterable, Identifiable, Codable, Sendable {
    case contain
    case actualSize

    var id: String { rawValue }

    var label: String {
        switch self {
        case .contain:
            return "Contain"
        case .actualSize:
            return "Actual Size"
        }
    }
}

nonisolated enum PresentationSubjectAlignment: String, CaseIterable, Identifiable, Codable, Sendable {
    case topLeft
    case top
    case topRight
    case left
    case center
    case right
    case bottomLeft
    case bottom
    case bottomRight

    var id: String { rawValue }

    var label: String {
        switch self {
        case .topLeft:
            return "Top Left"
        case .top:
            return "Top"
        case .topRight:
            return "Top Right"
        case .left:
            return "Left"
        case .center:
            return "Center"
        case .right:
            return "Right"
        case .bottomLeft:
            return "Bottom Left"
        case .bottom:
            return "Bottom"
        case .bottomRight:
            return "Bottom Right"
        }
    }

    var xFactor: CGFloat {
        switch self {
        case .topLeft, .left, .bottomLeft:
            return 0
        case .top, .center, .bottom:
            return 0.5
        case .topRight, .right, .bottomRight:
            return 1
        }
    }

    var yFactor: CGFloat {
        switch self {
        case .topLeft, .top, .topRight:
            return 0
        case .left, .center, .right:
            return 0.5
        case .bottomLeft, .bottom, .bottomRight:
            return 1
        }
    }
}

/// Legacy/native subject placement retained for older `.sss` files and renderer
/// compatibility. Scene screenshot placement now uses
/// `PresentationSceneScreenshotSlotSettings`.
nonisolated struct PresentationSubjectPlacement: Equatable, Codable, Sendable {
    var fit: PresentationSubjectFit
    var alignment: PresentationSubjectAlignment
    var scale: CGFloat
    var offset: CGSize

    nonisolated init(
        fit: PresentationSubjectFit = .contain,
        alignment: PresentationSubjectAlignment = .center,
        scale: CGFloat = 1,
        offset: CGSize = .zero
    ) {
        self.fit = fit
        self.alignment = alignment
        self.scale = max(scale, 0.05)
        self.offset = offset
    }

    nonisolated static let `default` = PresentationSubjectPlacement()
}

nonisolated enum PresentationAppearanceScheme: String, CaseIterable, Identifiable, Codable, Sendable {
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }
}

nonisolated struct PresentationBrowserFrameStyle: Equatable, Codable, Sendable {
    var title: String
    var address: String
    var scheme: PresentationAppearanceScheme
    var showsTrafficLights: Bool

    nonisolated init(
        title: String = "SnipSnipSnip",
        address: String = "https://example.com",
        scheme: PresentationAppearanceScheme = .light,
        showsTrafficLights: Bool = true
    ) {
        self.title = title
        self.address = address
        self.scheme = scheme
        self.showsTrafficLights = showsTrafficLights
    }

    nonisolated static let `default` = PresentationBrowserFrameStyle()
}

nonisolated struct PresentationMacWindowFrameStyle: Equatable, Codable, Sendable {
    var title: String
    var scheme: PresentationAppearanceScheme
    var showsTrafficLights: Bool

    nonisolated init(
        title: String = "Screenshot",
        scheme: PresentationAppearanceScheme = .light,
        showsTrafficLights: Bool = true
    ) {
        self.title = title
        self.scheme = scheme
        self.showsTrafficLights = showsTrafficLights
    }

    nonisolated static let `default` = PresentationMacWindowFrameStyle()
}

nonisolated enum PresentationDeviceOrientation: String, CaseIterable, Identifiable, Codable, Sendable {
    case portrait
    case landscape

    var id: String { rawValue }

    var label: String {
        switch self {
        case .portrait:
            return "Portrait"
        case .landscape:
            return "Landscape"
        }
    }
}

nonisolated struct PresentationDeviceFrameStyle: Equatable, Codable, Sendable {
    var orientation: PresentationDeviceOrientation
    var bezelColor: RGBAColor
    var screenCornerRadius: CGFloat
    var showsSensorHousing: Bool
    var castsDeviceShadow: Bool

    nonisolated init(
        orientation: PresentationDeviceOrientation = .portrait,
        bezelColor: RGBAColor = RGBAColor(red: 0.05, green: 0.055, blue: 0.065, alpha: 1),
        screenCornerRadius: CGFloat = 28,
        showsSensorHousing: Bool = true,
        castsDeviceShadow: Bool = true
    ) {
        self.orientation = orientation
        self.bezelColor = bezelColor
        self.screenCornerRadius = max(screenCornerRadius, 0)
        self.showsSensorHousing = showsSensorHousing
        self.castsDeviceShadow = castsDeviceShadow
    }

    nonisolated static let phone = PresentationDeviceFrameStyle(
        orientation: .portrait,
        bezelColor: RGBAColor(red: 0.045, green: 0.048, blue: 0.056, alpha: 1),
        screenCornerRadius: 30,
        showsSensorHousing: true,
        castsDeviceShadow: true
    )

    nonisolated static let tablet = PresentationDeviceFrameStyle(
        orientation: .landscape,
        bezelColor: RGBAColor(red: 0.08, green: 0.085, blue: 0.095, alpha: 1),
        screenCornerRadius: 22,
        showsSensorHousing: false,
        castsDeviceShadow: true
    )
}

/// Legacy/native vector frames retained for `.sss` compatibility. Browser,
/// window, phone, tablet, and social layouts should be authored as SVG
/// Presentation Scenes so they remain extensible.
nonisolated enum PresentationFrame: Equatable, Codable, Sendable {
    case none
    case browser(PresentationBrowserFrameStyle)
    case macOSWindow(PresentationMacWindowFrameStyle)
    case phone(PresentationDeviceFrameStyle)
    case tablet(PresentationDeviceFrameStyle)

    private enum CodingKeys: String, CodingKey {
        case kind
        case browser
        case macOSWindow
        case device
    }

    var kindLabel: String {
        switch self {
        case .none:
            return "None"
        case .browser:
            return "Browser"
        case .macOSWindow:
            return "Mac Window"
        case .phone:
            return "Phone"
        case .tablet:
            return "Tablet"
        }
    }

    var isDevice: Bool {
        switch self {
        case .phone, .tablet:
            return true
        default:
            return false
        }
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "none"

        switch kind {
        case "browser":
            self = .browser(try container.decodeIfPresent(PresentationBrowserFrameStyle.self, forKey: .browser) ?? .default)
        case "macOSWindow":
            self = .macOSWindow(try container.decodeIfPresent(PresentationMacWindowFrameStyle.self, forKey: .macOSWindow) ?? .default)
        case "phone":
            self = .phone(try container.decodeIfPresent(PresentationDeviceFrameStyle.self, forKey: .device) ?? .phone)
        case "tablet":
            self = .tablet(try container.decodeIfPresent(PresentationDeviceFrameStyle.self, forKey: .device) ?? .tablet)
        default:
            self = .none
        }
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode("none", forKey: .kind)
        case let .browser(style):
            try container.encode("browser", forKey: .kind)
            try container.encode(style, forKey: .browser)
        case let .macOSWindow(style):
            try container.encode("macOSWindow", forKey: .kind)
            try container.encode(style, forKey: .macOSWindow)
        case let .phone(style):
            try container.encode("phone", forKey: .kind)
            try container.encode(style, forKey: .device)
        case let .tablet(style):
            try container.encode("tablet", forKey: .kind)
            try container.encode(style, forKey: .device)
        }
    }
}

nonisolated enum ScreenshotPresentationBackground: Equatable, Codable, Sendable {
    case transparent
    case solid(RGBAColor)
    case twoColorGradient(start: RGBAColor, end: RGBAColor)
    case radialSpotlight(base: RGBAColor, spotlight: RGBAColor)
    case blurredScreenshot(tint: RGBAColor)

    private enum CodingKeys: String, CodingKey {
        case kind
        case color
        case start
        case end
        case base
        case spotlight
        case tint
    }

    var label: String {
        switch self {
        case .transparent:
            return "Transparent"
        case .solid:
            return "Solid"
        case .twoColorGradient:
            return "Gradient"
        case .radialSpotlight:
            return "Spotlight"
        case .blurredScreenshot:
            return "Blurred Screenshot"
        }
    }

    var supportsAlphaExport: Bool {
        switch self {
        case .transparent:
            return true
        case .solid, .twoColorGradient, .radialSpotlight, .blurredScreenshot:
            return false
        }
    }

    var fillColor: RGBAColor {
        switch self {
        case .transparent:
            return .clear
        case let .solid(color):
            return color
        case let .twoColorGradient(start, _):
            return start
        case let .radialSpotlight(base, _):
            return base
        case let .blurredScreenshot(tint):
            return tint
        }
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "solid"

        switch kind {
        case "transparent":
            self = .transparent
        case "gradient", "twoColorGradient":
            self = .twoColorGradient(
                start: try container.decodeIfPresent(RGBAColor.self, forKey: .start)
                    ?? RGBAColor(red: 0.32, green: 0.55, blue: 0.94, alpha: 1),
                end: try container.decodeIfPresent(RGBAColor.self, forKey: .end)
                    ?? RGBAColor(red: 0.08, green: 0.12, blue: 0.20, alpha: 1)
            )
        case "radialSpotlight":
            self = .radialSpotlight(
                base: try container.decodeIfPresent(RGBAColor.self, forKey: .base)
                    ?? RGBAColor(red: 0.08, green: 0.10, blue: 0.14, alpha: 1),
                spotlight: try container.decodeIfPresent(RGBAColor.self, forKey: .spotlight)
                    ?? RGBAColor(red: 0.75, green: 0.86, blue: 1.0, alpha: 1)
            )
        case "blurredScreenshot":
            self = .blurredScreenshot(
                tint: try container.decodeIfPresent(RGBAColor.self, forKey: .tint)
                    ?? RGBAColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 0.35)
            )
        case "solid":
            self = .solid(
                try container.decodeIfPresent(RGBAColor.self, forKey: .color)
                    ?? RGBAColor(red: 0.95, green: 0.96, blue: 0.98, alpha: 1)
            )
        default:
            self = .solid(
                try container.decodeIfPresent(RGBAColor.self, forKey: .color)
                    ?? RGBAColor(red: 0.95, green: 0.96, blue: 0.98, alpha: 1)
            )
        }
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .transparent:
            try container.encode("transparent", forKey: .kind)
        case let .solid(color):
            try container.encode("solid", forKey: .kind)
            try container.encode(color, forKey: .color)
        case let .twoColorGradient(start, end):
            try container.encode("twoColorGradient", forKey: .kind)
            try container.encode(start, forKey: .start)
            try container.encode(end, forKey: .end)
        case let .radialSpotlight(base, spotlight):
            try container.encode("radialSpotlight", forKey: .kind)
            try container.encode(base, forKey: .base)
            try container.encode(spotlight, forKey: .spotlight)
        case let .blurredScreenshot(tint):
            try container.encode("blurredScreenshot", forKey: .kind)
            try container.encode(tint, forKey: .tint)
        }
    }
}

nonisolated enum ScreenshotShadowStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case off
    case soft
    case medium
    case strong
    case drop

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off:
            return "None"
        case .soft:
            return "Halo"
        case .medium:
            return "Lift"
        case .strong:
            return "Drama"
        case .drop:
            return "Drop"
        }
    }

    var inspectorDescription: String {
        switch self {
        case .off:
            return "Flat edge"
        case .soft:
            return "Soft ambient glow"
        case .medium:
            return "Directional drop shadow"
        case .strong:
            return "Bold lower-right cast shadow"
        case .drop:
            return "Classic neutral drop shadow"
        }
    }

    var blurRadius: CGFloat {
        switch self {
        case .off:
            return 0
        case .soft:
            return 24
        case .medium:
            return 34
        case .strong:
            return 46
        case .drop:
            return 12
        }
    }

    var offsetX: CGFloat {
        switch self {
        case .off, .soft:
            return 0
        case .medium:
            return 18
        case .strong:
            return 30
        case .drop:
            return 12
        }
    }

    var offsetY: CGFloat {
        switch self {
        case .off:
            return 0
        case .soft:
            return 12
        case .medium:
            return 18
        case .strong:
            return 30
        case .drop:
            return 12
        }
    }

    var opacity: CGFloat {
        switch self {
        case .off:
            return 0
        case .soft:
            return 0.24
        case .medium:
            return 0.38
        case .strong:
            return 0.52
        case .drop:
            return 0.36
        }
    }
}

nonisolated enum ScreenshotShadowDirection: String, CaseIterable, Identifiable, Codable, Sendable {
    case topLeft
    case top
    case topRight
    case left
    case center
    case right
    case bottomLeft
    case bottom
    case bottomRight

    var id: String { rawValue }

    var xSign: CGFloat {
        switch self {
        case .topLeft, .left, .bottomLeft:
            return -1
        case .topRight, .right, .bottomRight:
            return 1
        case .top, .center, .bottom:
            return 0
        }
    }

    var ySign: CGFloat {
        switch self {
        case .topLeft, .top, .topRight:
            return -1
        case .bottomLeft, .bottom, .bottomRight:
            return 1
        case .left, .center, .right:
            return 0
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .topLeft:
            return "Top left"
        case .top:
            return "Top"
        case .topRight:
            return "Top right"
        case .left:
            return "Left"
        case .center:
            return "Centered"
        case .right:
            return "Right"
        case .bottomLeft:
            return "Bottom left"
        case .bottom:
            return "Bottom"
        case .bottomRight:
            return "Bottom right"
        }
    }

    nonisolated static func from(offsetX: CGFloat, offsetY: CGFloat) -> ScreenshotShadowDirection {
        let x = offsetX < -0.5 ? -1 : (offsetX > 0.5 ? 1 : 0)
        let y = offsetY < -0.5 ? -1 : (offsetY > 0.5 ? 1 : 0)

        switch (x, y) {
        case (-1, -1):
            return .topLeft
        case (0, -1):
            return .top
        case (1, -1):
            return .topRight
        case (-1, 0):
            return .left
        case (0, 0):
            return .center
        case (1, 0):
            return .right
        case (-1, 1):
            return .bottomLeft
        case (0, 1):
            return .bottom
        default:
            return .bottomRight
        }
    }
}

nonisolated struct PresentationStyle: Equatable, Codable, Sendable {
    var background: ScreenshotPresentationBackground
    var canvas: PresentationCanvas
    var subjectPlacement: PresentationSubjectPlacement
    var frame: PresentationFrame
    var padding: CGFloat
    var cornerRadius: CGFloat
    var shadow: ScreenshotShadowStyle
    var shadowBlurRadius: CGFloat
    var shadowOffsetX: CGFloat
    var shadowOffsetY: CGFloat
    var shadowOpacity: CGFloat

    nonisolated init(
        background: ScreenshotPresentationBackground,
        canvas: PresentationCanvas = .original,
        subjectPlacement: PresentationSubjectPlacement = .default,
        frame: PresentationFrame = .none,
        padding: CGFloat,
        cornerRadius: CGFloat,
        shadow: ScreenshotShadowStyle,
        shadowBlurRadius: CGFloat? = nil,
        shadowOffsetX: CGFloat? = nil,
        shadowOffsetY: CGFloat? = nil,
        shadowOpacity: CGFloat? = nil
    ) {
        self.background = background
        self.canvas = canvas
        self.subjectPlacement = subjectPlacement
        self.frame = frame
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.shadowBlurRadius = max(shadowBlurRadius ?? shadow.blurRadius, 0)
        self.shadowOffsetX = shadowOffsetX ?? shadow.offsetX
        self.shadowOffsetY = shadowOffsetY ?? shadow.offsetY
        self.shadowOpacity = min(max(shadowOpacity ?? shadow.opacity, 0), 1)
    }

    nonisolated static let plain = PresentationStyle(
        background: .transparent,
        canvas: .original,
        subjectPlacement: .default,
        frame: .none,
        padding: 0,
        cornerRadius: 0,
        shadow: .off
    )

    var isTransparent: Bool {
        background.supportsAlphaExport
    }

    var shadowDirection: ScreenshotShadowDirection {
        ScreenshotShadowDirection.from(offsetX: shadowOffsetX, offsetY: shadowOffsetY)
    }

    var contentInsets: NSEdgeInsets {
        let value = max(padding, 0)
        return NSEdgeInsets(top: value, left: value, bottom: value, right: value)
    }

    var shadowInsets: NSEdgeInsets {
        let blur = max(shadowBlurRadius, 0)
        let offsetX = shadowOffsetX
        let offsetY = shadowOffsetY
        return NSEdgeInsets(
            top: ceil(max(blur * 0.95 + max(-offsetY, 0) * 1.6, 0)),
            left: ceil(max(blur * 1.15 + max(-offsetX, 0), 0)),
            bottom: ceil(max(blur * 1.35 + max(offsetY, 0) * 1.6, 0)),
            right: ceil(max(blur * 1.15 + max(offsetX, 0), 0))
        )
    }

    var totalInsets: NSEdgeInsets {
        let content = contentInsets
        let shadow = shadowInsets
        return NSEdgeInsets(
            top: content.top + shadow.top,
            left: content.left + shadow.left,
            bottom: content.bottom + shadow.bottom,
            right: content.right + shadow.right
        )
    }
}

nonisolated struct ScreenshotPresentation: Equatable, Codable, Sendable {
    var isEnabled: Bool
    var style: PresentationStyle
    var scene: AppliedPresentationScene?

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case style
        case scene
        case background
        case canvas
        case subjectPlacement
        case frame
        case padding
        case cornerRadius
        case shadow
        case shadowBlurRadius
        case shadowOffsetX
        case shadowOffsetY
        case shadowOpacity
    }

    nonisolated init(
        isEnabled: Bool,
        style: PresentationStyle,
        scene: AppliedPresentationScene? = nil
    ) {
        self.isEnabled = isEnabled
        self.style = style
        self.scene = scene
    }

    nonisolated init(
        isEnabled: Bool,
        background: ScreenshotPresentationBackground,
        canvas: PresentationCanvas = .original,
        subjectPlacement: PresentationSubjectPlacement = .default,
        frame: PresentationFrame = .none,
        padding: CGFloat,
        cornerRadius: CGFloat,
        shadow: ScreenshotShadowStyle,
        shadowBlurRadius: CGFloat? = nil,
        shadowOffsetX: CGFloat? = nil,
        shadowOffsetY: CGFloat? = nil,
        shadowOpacity: CGFloat? = nil,
        scene: AppliedPresentationScene? = nil
    ) {
        self.isEnabled = isEnabled
        self.style = PresentationStyle(
            background: background,
            canvas: canvas,
            subjectPlacement: subjectPlacement,
            frame: frame,
            padding: padding,
            cornerRadius: cornerRadius,
            shadow: shadow,
            shadowBlurRadius: shadowBlurRadius,
            shadowOffsetX: shadowOffsetX,
            shadowOffsetY: shadowOffsetY,
            shadowOpacity: shadowOpacity
        )
        self.scene = scene
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        scene = try container.decodeIfPresent(AppliedPresentationScene.self, forKey: .scene)

        if let decodedStyle = try container.decodeIfPresent(PresentationStyle.self, forKey: .style) {
            style = decodedStyle
        } else {
            let shadowStyle = try container.decodeIfPresent(ScreenshotShadowStyle.self, forKey: .shadow)
                ?? ScreenshotShadowStyle(rawValue: try container.decodeIfPresent(String.self, forKey: .shadow) ?? "")
                ?? .off
            let background = try container.decodeIfPresent(ScreenshotPresentationBackground.self, forKey: .background) ?? .transparent
            let canvas = try container.decodeIfPresent(PresentationCanvas.self, forKey: .canvas) ?? .original
            let subjectPlacement = try container.decodeIfPresent(PresentationSubjectPlacement.self, forKey: .subjectPlacement) ?? .default
            let frame = try container.decodeIfPresent(PresentationFrame.self, forKey: .frame) ?? .none
            let padding = CGFloat(try container.decodeIfPresent(Double.self, forKey: .padding) ?? 0)
            let cornerRadius = CGFloat(try container.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 0)
            let shadowBlurRadius = try container.decodeIfPresent(Double.self, forKey: .shadowBlurRadius).map { CGFloat($0) }
            let shadowOffsetX = try container.decodeIfPresent(Double.self, forKey: .shadowOffsetX).map { CGFloat($0) }
            let shadowOffsetY = try container.decodeIfPresent(Double.self, forKey: .shadowOffsetY).map { CGFloat($0) }
            let shadowOpacity = try container.decodeIfPresent(Double.self, forKey: .shadowOpacity).map { CGFloat($0) }
            style = PresentationStyle(
                background: background,
                canvas: canvas,
                subjectPlacement: subjectPlacement,
                frame: frame,
                padding: padding,
                cornerRadius: cornerRadius,
                shadow: shadowStyle,
                shadowBlurRadius: shadowBlurRadius,
                shadowOffsetX: shadowOffsetX,
                shadowOffsetY: shadowOffsetY,
                shadowOpacity: shadowOpacity
            )
        }
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(style, forKey: .style)
        try container.encodeIfPresent(scene, forKey: .scene)
    }

    nonisolated static let plain = ScreenshotPresentation(
        isEnabled: false,
        style: .plain
    )

    var background: ScreenshotPresentationBackground {
        get { style.background }
        set { style.background = newValue }
    }

    var canvas: PresentationCanvas {
        get { style.canvas }
        set { style.canvas = newValue }
    }

    var subjectPlacement: PresentationSubjectPlacement {
        get { style.subjectPlacement }
        set { style.subjectPlacement = newValue }
    }

    var frame: PresentationFrame {
        get { style.frame }
        set { style.frame = newValue }
    }

    var padding: CGFloat {
        get { style.padding }
        set { style.padding = newValue }
    }

    var cornerRadius: CGFloat {
        get { style.cornerRadius }
        set { style.cornerRadius = newValue }
    }

    var shadow: ScreenshotShadowStyle {
        get { style.shadow }
        set { style.shadow = newValue }
    }

    var shadowBlurRadius: CGFloat {
        get { style.shadowBlurRadius }
        set { style.shadowBlurRadius = newValue }
    }

    var shadowOffsetX: CGFloat {
        get { style.shadowOffsetX }
        set { style.shadowOffsetX = newValue }
    }

    var shadowOffsetY: CGFloat {
        get { style.shadowOffsetY }
        set { style.shadowOffsetY = newValue }
    }

    var shadowOpacity: CGFloat {
        get { style.shadowOpacity }
        set { style.shadowOpacity = newValue }
    }

    var isTransparent: Bool {
        background.supportsAlphaExport
    }

    var requiresPNGForFaithfulExport: Bool {
        isEnabled && scene == nil && isTransparent
    }

    var shadowDirection: ScreenshotShadowDirection {
        style.shadowDirection
    }

    var contentInsets: NSEdgeInsets {
        style.contentInsets
    }

    var shadowInsets: NSEdgeInsets {
        style.shadowInsets
    }

    var totalInsets: NSEdgeInsets {
        style.totalInsets
    }
}

nonisolated struct SavedPresentation: Identifiable, Equatable, Codable, Sendable {
    var id: UUID
    var name: String
    var presentation: ScreenshotPresentation
    var createdAt: Date
    var updatedAt: Date

    nonisolated init(
        id: UUID = UUID(),
        name: String,
        presentation: ScreenshotPresentation,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.presentation = presentation
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

nonisolated struct PresentationTemplate: Identifiable, Equatable, Codable, Sendable {
    var id: String
    var name: String
    var presentation: ScreenshotPresentation
    var createdAt: Date
    var updatedAt: Date
    var isBuiltIn: Bool

    nonisolated init(
        id: String,
        name: String,
        presentation: ScreenshotPresentation,
        createdAt: Date = Date(timeIntervalSince1970: 0),
        updatedAt: Date = Date(timeIntervalSince1970: 0),
        isBuiltIn: Bool
    ) {
        self.id = id
        self.name = name
        self.presentation = presentation
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isBuiltIn = isBuiltIn
    }

    nonisolated static let builtInTemplates: [PresentationTemplate] = [
        PresentationTemplate(
            id: "builtin.plain",
            name: ScreenshotPresentationPreset.plain.label,
            presentation: ScreenshotPresentationPreset.plain.settings,
            isBuiltIn: true
        ),
        PresentationTemplate(
            id: "builtin.canvas",
            name: ScreenshotPresentationPreset.lifted.label,
            presentation: ScreenshotPresentationPreset.lifted.settings,
            isBuiltIn: true
        ),
        PresentationTemplate(
            id: "builtin.drop-shadow",
            name: ScreenshotPresentationPreset.transparentShadow.label,
            presentation: ScreenshotPresentationPreset.transparentShadow.settings,
            isBuiltIn: true
        )
    ]
}
