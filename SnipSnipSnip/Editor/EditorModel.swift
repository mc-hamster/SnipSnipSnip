import AppKit
import CoreGraphics
import Foundation

private struct EditorToolMetadata {
    let label: String
    let systemImage: String
    let supportsStyleEditing: Bool
    let supportsFillEditing: Bool
    let defaultRedactionMode: RedactionMode?
    let defaultStyle: AnnotationStyle
}

nonisolated enum EditorTool: String, CaseIterable, Identifiable {
    case select
    case uiMapInspect
    case rectangle
    case ellipse
    case line
    case arrow
    case freehand
    case highlighter
    case highlight
    case text
    case callout
    case measure
    case spotlight
    case colorPicker
    case ocrText
    case blur
    case pixelate
    case redact
    case crop

    nonisolated var id: String { rawValue }

    nonisolated var label: String {
        metadata.label
    }

    nonisolated var systemImage: String {
        metadata.systemImage
    }

    nonisolated var supportsStyleEditing: Bool {
        metadata.supportsStyleEditing
    }

    nonisolated var supportsFillEditing: Bool {
        metadata.supportsFillEditing
    }

    nonisolated var defaultRedactionMode: RedactionMode? {
        metadata.defaultRedactionMode
    }

    nonisolated var defaultStyle: AnnotationStyle {
        metadata.defaultStyle
    }

    nonisolated func makeRectAnnotation(in rect: CGRect, style: AnnotationStyle) -> Annotation? {
        switch self {
        case .rectangle:
            return Annotation.makeRectangle(in: rect, style: style)
        case .ellipse:
            return Annotation.makeEllipse(in: rect, style: style)
        case .highlight:
            return Annotation.makeHighlight(in: rect, style: style)
        case .blur:
            return Annotation.makeBlur(in: rect, style: style)
        case .pixelate:
            return Annotation.makePixelate(in: rect, style: style)
        case .redact:
            return Annotation.makeSolidRedaction(in: rect, style: style)
        case .spotlight:
            return Annotation.makeSpotlight(in: rect, style: style)
        case .select, .uiMapInspect, .line, .arrow, .freehand, .highlighter, .text, .callout, .measure, .colorPicker, .ocrText, .crop:
            return nil
        }
    }

    nonisolated private var metadata: EditorToolMetadata {
        switch self {
        case .select:
            return EditorToolMetadata(
                label: "Select",
                systemImage: "cursorarrow",
                supportsStyleEditing: false,
                supportsFillEditing: false,
                defaultRedactionMode: nil,
                defaultStyle: AnnotationStyle(strokeColor: .rectangleStroke, fillColor: .clear, lineWidth: 4, fontSize: 0, effectRadius: 0)
            )
        case .uiMapInspect:
            return EditorToolMetadata(
                label: "Pin UI Map",
                systemImage: "cursorarrow.rays",
                supportsStyleEditing: false,
                supportsFillEditing: false,
                defaultRedactionMode: nil,
                defaultStyle: AnnotationStyle(strokeColor: .rectangleStroke, fillColor: .clear, lineWidth: 4, fontSize: 0, effectRadius: 0)
            )
        case .rectangle:
            return EditorToolMetadata(
                label: "Rectangle",
                systemImage: "square",
                supportsStyleEditing: true,
                supportsFillEditing: true,
                defaultRedactionMode: nil,
                defaultStyle: AnnotationStyle(strokeColor: .rectangleStroke, fillColor: .clear, lineWidth: 4, fontSize: 0, effectRadius: 0)
            )
        case .ellipse:
            return EditorToolMetadata(
                label: "Ellipse",
                systemImage: "circle",
                supportsStyleEditing: true,
                supportsFillEditing: true,
                defaultRedactionMode: nil,
                defaultStyle: AnnotationStyle(strokeColor: .ellipseStroke, fillColor: .clear, lineWidth: 4, fontSize: 0, effectRadius: 0)
            )
        case .line:
            return EditorToolMetadata(
                label: "Line",
                systemImage: "line.diagonal",
                supportsStyleEditing: true,
                supportsFillEditing: false,
                defaultRedactionMode: nil,
                defaultStyle: AnnotationStyle(strokeColor: .lineStroke, fillColor: .clear, lineWidth: 4, fontSize: 0, effectRadius: 0)
            )
        case .arrow:
            return EditorToolMetadata(
                label: "Arrow",
                systemImage: "arrow.up.right",
                supportsStyleEditing: true,
                supportsFillEditing: false,
                defaultRedactionMode: nil,
                defaultStyle: AnnotationStyle(strokeColor: .arrowStroke, fillColor: .clear, lineWidth: 5, fontSize: 0, effectRadius: 0)
            )
        case .freehand:
            return EditorToolMetadata(
                label: "Freehand",
                systemImage: "signature",
                supportsStyleEditing: true,
                supportsFillEditing: false,
                defaultRedactionMode: nil,
                defaultStyle: AnnotationStyle(strokeColor: .freehandStroke, fillColor: .clear, lineWidth: 5, fontSize: 0, effectRadius: 0)
            )
        case .highlighter:
            return EditorToolMetadata(
                label: "Highlighter",
                systemImage: "highlighter",
                supportsStyleEditing: true,
                supportsFillEditing: false,
                defaultRedactionMode: nil,
                defaultStyle: AnnotationStyle(
                    strokeColor: .highlighterStroke,
                    fillColor: .clear,
                    lineWidth: 16,
                    fontSize: 0,
                    effectRadius: 0,
                    freehandSmoothing: 1,
                    freehandSimplification: 8
                )
            )
        case .highlight:
            return EditorToolMetadata(
                label: "Highlight Box",
                systemImage: "rectangle.inset.filled",
                supportsStyleEditing: true,
                supportsFillEditing: true,
                defaultRedactionMode: nil,
                defaultStyle: AnnotationStyle(strokeColor: .highlightFill.withAlpha(0.6), fillColor: .highlightFill, lineWidth: 2, fontSize: 0, effectRadius: 0)
            )
        case .text:
            return EditorToolMetadata(
                label: "Text",
                systemImage: "character.cursor.ibeam",
                supportsStyleEditing: true,
                supportsFillEditing: true,
                defaultRedactionMode: nil,
                defaultStyle: AnnotationStyle(strokeColor: .textForeground, fillColor: .textBackground, lineWidth: 0, fontSize: 28, effectRadius: 0)
            )
        case .callout:
            return EditorToolMetadata(
                label: "Callout",
                systemImage: "text.bubble",
                supportsStyleEditing: true,
                supportsFillEditing: true,
                defaultRedactionMode: nil,
                defaultStyle: AnnotationStyle(strokeColor: .textForeground, fillColor: .calloutFill, lineWidth: 0, fontSize: 22, effectRadius: 0)
            )
        case .measure:
            return EditorToolMetadata(
                label: "Ruler",
                systemImage: "ruler",
                supportsStyleEditing: true,
                supportsFillEditing: true,
                defaultRedactionMode: nil,
                defaultStyle: AnnotationStyle(strokeColor: .measureStroke, fillColor: .textBackground, lineWidth: 3, fontSize: 18, effectRadius: 0)
            )
        case .spotlight:
            return EditorToolMetadata(
                label: "Spotlight",
                systemImage: "circle.dashed",
                supportsStyleEditing: true,
                supportsFillEditing: true,
                defaultRedactionMode: nil,
                defaultStyle: AnnotationStyle(strokeColor: .textForeground.withAlpha(0.85), fillColor: .redactionFill.withAlpha(0.55), lineWidth: 2, fontSize: 0, effectRadius: 55)
            )
        case .colorPicker:
            return EditorToolMetadata(
                label: "Color Picker",
                systemImage: "eyedropper",
                supportsStyleEditing: false,
                supportsFillEditing: false,
                defaultRedactionMode: nil,
                defaultStyle: AnnotationStyle(strokeColor: .rectangleStroke, fillColor: .clear, lineWidth: 4, fontSize: 0, effectRadius: 0)
            )
        case .ocrText:
            return EditorToolMetadata(
                label: "Copy Text",
                systemImage: "text.viewfinder",
                supportsStyleEditing: false,
                supportsFillEditing: false,
                defaultRedactionMode: nil,
                defaultStyle: AnnotationStyle(strokeColor: .rectangleStroke, fillColor: .clear, lineWidth: 2, fontSize: 0, effectRadius: 0)
            )
        case .blur:
            return EditorToolMetadata(
                label: "Blur",
                systemImage: "drop.degreesign",
                supportsStyleEditing: true,
                supportsFillEditing: false,
                defaultRedactionMode: .blur,
                defaultStyle: AnnotationStyle(strokeColor: .blurOutline, fillColor: .clear, lineWidth: 2, fontSize: 0, effectRadius: 20)
            )
        case .pixelate:
            return EditorToolMetadata(
                label: "Pixelate",
                systemImage: "square.grid.3x3.fill",
                supportsStyleEditing: true,
                supportsFillEditing: false,
                defaultRedactionMode: .pixelate,
                defaultStyle: AnnotationStyle(strokeColor: .pixelateOutline, fillColor: .clear, lineWidth: 2, fontSize: 0, effectRadius: 28)
            )
        case .redact:
            return EditorToolMetadata(
                label: "Redact",
                systemImage: "eye.slash.fill",
                supportsStyleEditing: true,
                supportsFillEditing: true,
                defaultRedactionMode: .solid,
                defaultStyle: AnnotationStyle(strokeColor: .redactionFill, fillColor: .redactionFill, lineWidth: 0, fontSize: 0, effectRadius: 0)
            )
        case .crop:
            return EditorToolMetadata(
                label: "Crop",
                systemImage: "crop",
                supportsStyleEditing: false,
                supportsFillEditing: false,
                defaultRedactionMode: nil,
                defaultStyle: AnnotationStyle(strokeColor: .rectangleStroke, fillColor: .clear, lineWidth: 4, fontSize: 0, effectRadius: 0)
            )
        }
    }
}

nonisolated enum TextAlignmentMode: String, CaseIterable, Identifiable {
    case left
    case center
    case right

    nonisolated var id: String { rawValue }

    nonisolated var label: String {
        switch self {
        case .left:
            return "Align Left"
        case .center:
            return "Align Center"
        case .right:
            return "Align Right"
        }
    }

    nonisolated var shortLabel: String {
        switch self {
        case .left:
            return "Left"
        case .center:
            return "Center"
        case .right:
            return "Right"
        }
    }

    nonisolated var systemImage: String {
        switch self {
        case .left:
            return "text.alignleft"
        case .center:
            return "text.aligncenter"
        case .right:
            return "text.alignright"
        }
    }

    nonisolated var nsTextAlignment: NSTextAlignment {
        switch self {
        case .left:
            return .left
        case .center:
            return .center
        case .right:
            return .right
        }
    }
}

nonisolated enum ResizeHandle: CaseIterable {
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left

    var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomRight, .bottomLeft:
            return true
        case .top, .right, .bottom, .left:
            return false
        }
    }

    @available(macOS 15.0, *)
    var frameResizeCursorPosition: NSCursor.FrameResizePosition {
        switch self {
        case .topLeft:
            return .topLeft
        case .top:
            return .top
        case .topRight:
            return .topRight
        case .right:
            return .right
        case .bottomRight:
            return .bottomRight
        case .bottom:
            return .bottom
        case .bottomLeft:
            return .bottomLeft
        case .left:
            return .left
        }
    }

    func position(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft:
            return CGPoint(x: rect.minX, y: rect.minY)
        case .top:
            return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight:
            return CGPoint(x: rect.maxX, y: rect.minY)
        case .right:
            return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight:
            return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom:
            return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft:
            return CGPoint(x: rect.minX, y: rect.maxY)
        case .left:
            return CGPoint(x: rect.minX, y: rect.midY)
        }
    }
}

nonisolated struct PaletteColorOption: Identifiable, Equatable {
    let id: String
    let label: String
    let color: RGBAColor
    let showsCheckerboard: Bool
}

nonisolated struct RGBAColor: Equatable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    var nsColor: NSColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    }

    nonisolated var cgColor: CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    nonisolated func withAlpha(_ alpha: CGFloat) -> RGBAColor {
        RGBAColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    nonisolated var complementary: RGBAColor {
        RGBAColor(red: 1 - red, green: 1 - green, blue: 1 - blue, alpha: alpha)
    }

    nonisolated static func == (lhs: RGBAColor, rhs: RGBAColor) -> Bool {
        lhs.red == rhs.red
            && lhs.green == rhs.green
            && lhs.blue == rhs.blue
            && lhs.alpha == rhs.alpha
    }

    nonisolated static let clear = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)
    nonisolated static let rectangleStroke = RGBAColor(red: 0.89, green: 0.20, blue: 0.24, alpha: 1)
    nonisolated static let ellipseStroke = RGBAColor(red: 0.24, green: 0.45, blue: 0.89, alpha: 1)
    nonisolated static let lineStroke = RGBAColor(red: 0.10, green: 0.68, blue: 0.56, alpha: 1)
    nonisolated static let arrowStroke = RGBAColor(red: 0.95, green: 0.56, blue: 0.14, alpha: 1)
    nonisolated static let highlightFill = RGBAColor(red: 1.00, green: 0.89, blue: 0.18, alpha: 0.35)
    nonisolated static let freehandStroke = RGBAColor(red: 0.22, green: 0.77, blue: 0.35, alpha: 1)
    nonisolated static let highlighterStroke = RGBAColor(red: 1.00, green: 0.92, blue: 0.20, alpha: 0.55)
    nonisolated static let textForeground = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
    nonisolated static let textBackground = RGBAColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 0.8)
    nonisolated static let calloutFill = RGBAColor(red: 0.88, green: 0.15, blue: 0.28, alpha: 1)
    nonisolated static let measureStroke = RGBAColor(red: 0.19, green: 0.78, blue: 0.92, alpha: 1)
    nonisolated static let blurOutline = RGBAColor(red: 0.19, green: 0.58, blue: 0.96, alpha: 1)
    nonisolated static let pixelateOutline = RGBAColor(red: 0.51, green: 0.29, blue: 0.78, alpha: 1)
    nonisolated static let redactionFill = RGBAColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1)

    nonisolated static let paletteOptions: [PaletteColorOption] = [
        PaletteColorOption(id: "red", label: "Red", color: .rectangleStroke, showsCheckerboard: false),
        PaletteColorOption(id: "blue", label: "Blue", color: .ellipseStroke, showsCheckerboard: false),
        PaletteColorOption(id: "green", label: "Green", color: .lineStroke, showsCheckerboard: false),
        PaletteColorOption(id: "orange", label: "Orange", color: .arrowStroke, showsCheckerboard: false),
        PaletteColorOption(id: "yellow", label: "Yellow", color: .highlightFill.withAlpha(1), showsCheckerboard: false),
        PaletteColorOption(id: "pink", label: "Pink", color: .calloutFill, showsCheckerboard: false),
        PaletteColorOption(id: "sky-blue", label: "Sky Blue", color: .blurOutline, showsCheckerboard: false),
        PaletteColorOption(id: "white", label: "White", color: .textForeground, showsCheckerboard: false),
        PaletteColorOption(id: "black", label: "Black", color: .redactionFill, showsCheckerboard: false),
        PaletteColorOption(id: "transparent", label: "Transparent", color: .clear, showsCheckerboard: true)
    ]

    nonisolated static func paletteOption(id: String) -> PaletteColorOption? {
        paletteOptions.first { $0.id == id }
    }

    nonisolated static func paletteOption(for color: RGBAColor) -> PaletteColorOption? {
        paletteOptions.first { $0.color == color }
    }

    nonisolated static let palette: [RGBAColor] = paletteOptions.map(\.color)
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

nonisolated enum ScreenshotPresentationBackground: Equatable {
    case transparent
    case solid(RGBAColor)

    var label: String {
        switch self {
        case .transparent:
            return "Transparent"
        case .solid:
            return "Solid"
        }
    }

    var supportsAlphaExport: Bool {
        switch self {
        case .transparent:
            return true
        case .solid:
            return false
        }
    }

    var fillColor: RGBAColor {
        switch self {
        case .transparent:
            return .clear
        case let .solid(color):
            return color
        }
    }
}

nonisolated enum ScreenshotShadowStyle: String, CaseIterable, Identifiable {
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

nonisolated enum ScreenshotShadowDirection: String, CaseIterable, Identifiable {
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

nonisolated struct ScreenshotPresentation: Equatable {
    var isEnabled: Bool
    var background: ScreenshotPresentationBackground
    var padding: CGFloat
    var cornerRadius: CGFloat
    var shadow: ScreenshotShadowStyle
    var shadowBlurRadius: CGFloat
    var shadowOffsetX: CGFloat
    var shadowOffsetY: CGFloat
    var shadowOpacity: CGFloat

    nonisolated init(
        isEnabled: Bool,
        background: ScreenshotPresentationBackground,
        padding: CGFloat,
        cornerRadius: CGFloat,
        shadow: ScreenshotShadowStyle,
        shadowBlurRadius: CGFloat? = nil,
        shadowOffsetX: CGFloat? = nil,
        shadowOffsetY: CGFloat? = nil,
        shadowOpacity: CGFloat? = nil
    ) {
        self.isEnabled = isEnabled
        self.background = background
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.shadowBlurRadius = max(shadowBlurRadius ?? shadow.blurRadius, 0)
        self.shadowOffsetX = shadowOffsetX ?? shadow.offsetX
        self.shadowOffsetY = shadowOffsetY ?? shadow.offsetY
        self.shadowOpacity = min(max(shadowOpacity ?? shadow.opacity, 0), 1)
    }

    nonisolated static let plain = ScreenshotPresentation(
        isEnabled: false,
        background: .transparent,
        padding: 0,
        cornerRadius: 0,
        shadow: .off
    )

    var isTransparent: Bool {
        background.supportsAlphaExport
    }

    var requiresPNGForFaithfulExport: Bool {
        isEnabled && isTransparent
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

nonisolated struct AnnotationStyle: Equatable {
    var strokeColor: RGBAColor
    var fillColor: RGBAColor
    var lineWidth: CGFloat
    var fontSize: CGFloat
    var effectRadius: CGFloat
    var cornerRadius: CGFloat = 0
    var dashStyle: StrokeDashStyle = .solid
    var freehandSmoothing: CGFloat = 0.65
    var freehandSimplification: CGFloat = 1.5

    nonisolated func scaledForDisplay(by scale: CGFloat) -> AnnotationStyle {
        let displayScale = max(scale, 0)

        return AnnotationStyle(
            strokeColor: strokeColor,
            fillColor: fillColor,
            lineWidth: lineWidth * displayScale,
            fontSize: fontSize * displayScale,
            effectRadius: effectRadius,
            cornerRadius: cornerRadius * displayScale,
            dashStyle: dashStyle,
            freehandSmoothing: freehandSmoothing,
            freehandSimplification: freehandSimplification * displayScale
        )
    }

    nonisolated static func `default`(for tool: EditorTool) -> AnnotationStyle {
        tool.defaultStyle
    }
}

nonisolated enum StrokeDashStyle: String, CaseIterable, Identifiable {
    case solid
    case dashed
    case dotted

    var id: String { rawValue }

    var label: String {
        switch self {
        case .solid:
            return "Solid"
        case .dashed:
            return "Dashed"
        case .dotted:
            return "Dotted"
        }
    }

    nonisolated var pattern: [CGFloat] {
        switch self {
        case .solid:
            return []
        case .dashed:
            return [10, 8]
        case .dotted:
            return [2, 6]
        }
    }
}

nonisolated enum CropAspectRatioPreset: String, CaseIterable, Identifiable {
    case freeform
    case square
    case threeTwo
    case twoThree
    case fourThree
    case threeFour
    case sixteenNine
    case nineSixteen

    var id: String { rawValue }

    var label: String {
        switch self {
        case .freeform:
            return "Freeform"
        case .square:
            return "1:1"
        case .threeTwo:
            return "3:2"
        case .twoThree:
            return "2:3"
        case .fourThree:
            return "4:3"
        case .threeFour:
            return "3:4"
        case .sixteenNine:
            return "16:9"
        case .nineSixteen:
            return "9:16"
        }
    }

    var ratio: CGFloat? {
        switch self {
        case .freeform:
            return nil
        case .square:
            return 1
        case .threeTwo:
            return 3 / 2
        case .twoThree:
            return 2 / 3
        case .fourThree:
            return 4 / 3
        case .threeFour:
            return 3 / 4
        case .sixteenNine:
            return 16 / 9
        case .nineSixteen:
            return 9 / 16
        }
    }
}

nonisolated struct RectangleShape: Equatable {
    var rect: CGRect
}

nonisolated struct EllipseShape: Equatable {
    var rect: CGRect
}

nonisolated struct LineShape: Equatable {
    var start: CGPoint
    var end: CGPoint
}

nonisolated enum ArrowHeadStyle: String, CaseIterable, Identifiable {
    case single
    case double

    var id: String { rawValue }

    var label: String {
        switch self {
        case .single:
            return "Single"
        case .double:
            return "Double"
        }
    }
}

nonisolated enum ArrowHeadShape: String, CaseIterable, Identifiable {
    case open
    case triangle
    case stealth
    case diamond

    var id: String { rawValue }

    var label: String {
        switch self {
        case .open:
            return "Open"
        case .triangle:
            return "Triangle"
        case .stealth:
            return "Stealth"
        case .diamond:
            return "Diamond"
        }
    }
}

nonisolated enum ArrowLabelPlacement: String, CaseIterable, Identifiable {
    case horizontal
    case parallelAbove
    case parallelBelow

    var id: String { rawValue }

    var label: String {
        switch self {
        case .horizontal:
            return "Horizontal"
        case .parallelAbove:
            return "Top"
        case .parallelBelow:
            return "Bottom"
        }
    }
}

nonisolated enum ArrowLabelTextColor: String, CaseIterable, Identifiable {
    case stroke
    case complementary

    var id: String { rawValue }

    var label: String {
        switch self {
        case .stroke:
            return "Stroke"
        case .complementary:
            return "Complementary"
        }
    }

    func resolvedColor(for strokeColor: RGBAColor) -> RGBAColor {
        switch self {
        case .stroke:
            return strokeColor
        case .complementary:
            return strokeColor.complementary
        }
    }
}

nonisolated struct ArrowShape: Equatable {
    var start: CGPoint
    var end: CGPoint
    var curvature: CGFloat = 0
    var headStyle: ArrowHeadStyle = .single
    var label: String = ""
    var labelBoxColor: RGBAColor = .clear
    var labelPlacement: ArrowLabelPlacement = .parallelAbove
    var labelFontSize: CGFloat = 14
    var labelTextColor: ArrowLabelTextColor = .stroke
    var headShape: ArrowHeadShape = .open
}

nonisolated struct FreehandShape: Equatable {
    var points: [CGPoint]
}

nonisolated struct HighlighterShape: Equatable {
    var points: [CGPoint]
}

nonisolated struct TextShape: Equatable {
    var rect: CGRect
    var text: String
    var alignment: TextAlignmentMode = .left
}

nonisolated struct HighlightShape: Equatable {
    var rect: CGRect
}

nonisolated struct CalloutShape: Equatable {
    var rect: CGRect
    var number: Int
    var text: String
    var alignment: TextAlignmentMode = .left
    var style: CalloutVisualStyle = .filled
    var leaderPoint: CGPoint?
}

nonisolated enum CalloutVisualStyle: String, CaseIterable, Identifiable {
    case filled
    case outlined

    var id: String { rawValue }

    var label: String {
        switch self {
        case .filled:
            return "Filled"
        case .outlined:
            return "Outlined"
        }
    }
}

nonisolated struct MeasurementShape: Equatable {
    var start: CGPoint
    var end: CGPoint

    nonisolated var length: CGFloat {
        hypot(end.x - start.x, end.y - start.y)
    }
}

nonisolated struct SpotlightShape: Equatable {
    var rect: CGRect
    var isEllipse: Bool = true
}

nonisolated struct ImageOverlayShape: Equatable {
    enum Role: String {
        case importedImage
        case capturedCursor
    }

    var assetID: UUID
    var rect: CGRect
    var image: CGImage
    var opacity: CGFloat = 1
    var role: Role = .importedImage

    static func == (lhs: ImageOverlayShape, rhs: ImageOverlayShape) -> Bool {
        lhs.assetID == rhs.assetID
            && lhs.rect == rhs.rect
            && lhs.opacity == rhs.opacity
            && lhs.role == rhs.role
            && lhs.image.width == rhs.image.width
            && lhs.image.height == rhs.image.height
    }
}

nonisolated enum RedactionMode: String, CaseIterable, Identifiable {
    case blur
    case pixelate
    case solid

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blur:
            return "Blur"
        case .pixelate:
            return "Pixelate"
        case .solid:
            return "Redact"
        }
    }

    var editorTool: EditorTool {
        switch self {
        case .blur:
            return .blur
        case .pixelate:
            return .pixelate
        case .solid:
            return .redact
        }
    }

    var toolbarSystemImage: String {
        editorTool.systemImage
    }
}

nonisolated struct RedactionShape: Equatable {
    var rect: CGRect
    var mode: RedactionMode
}

nonisolated enum AnnotationKind: Equatable {
    case rectangle(RectangleShape)
    case ellipse(EllipseShape)
    case line(LineShape)
    case arrow(ArrowShape)
    case freehand(FreehandShape)
    case highlighter(HighlighterShape)
    case highlight(HighlightShape)
    case text(TextShape)
    case callout(CalloutShape)
    case measurement(MeasurementShape)
    case spotlight(SpotlightShape)
    case imageOverlay(ImageOverlayShape)
    case redaction(RedactionShape)
}

nonisolated extension AnnotationKind {
    var editorTool: EditorTool {
        switch self {
        case .rectangle:
            return .rectangle
        case .ellipse:
            return .ellipse
        case .line:
            return .line
        case .arrow:
            return .arrow
        case .freehand:
            return .freehand
        case .highlighter:
            return .highlighter
        case .highlight:
            return .highlight
        case .text:
            return .text
        case .callout:
            return .callout
        case .measurement:
            return .measure
        case .spotlight:
            return .spotlight
        case .imageOverlay:
            return .select
        case let .redaction(shape):
            return shape.mode.editorTool
        }
    }

    var isTextEditable: Bool {
        switch self {
        case .text, .callout:
            return true
        default:
            return false
        }
    }

    var redactionMode: RedactionMode? {
        guard case let .redaction(shape) = self else {
            return nil
        }

        return shape.mode
    }

    var textAlignmentMode: TextAlignmentMode? {
        switch self {
        case let .text(shape):
            return shape.alignment
        case let .callout(shape):
            return shape.alignment
        default:
            return nil
        }
    }

    var supportsFillEditing: Bool {
        switch self {
        case .rectangle, .ellipse, .highlight, .text, .callout, .measurement, .spotlight, .imageOverlay, .redaction:
            return true
        default:
            return false
        }
    }

    var displayName: String {
        switch self {
        case .imageOverlay(let shape):
            return shape.role == .capturedCursor ? "Cursor" : "Image"
        case .redaction(let shape):
            return shape.mode.label
        default:
            return editorTool.label
        }
    }

    func transformingGeometry(
        rect transformRect: (CGRect) -> CGRect,
        point transformPoint: (CGPoint) -> CGPoint
    ) -> AnnotationKind {
        switch self {
        case let .rectangle(shape):
            return .rectangle(RectangleShape(rect: transformRect(shape.rect)))
        case let .ellipse(shape):
            return .ellipse(EllipseShape(rect: transformRect(shape.rect)))
        case let .line(shape):
            return .line(LineShape(
                start: transformPoint(shape.start),
                end: transformPoint(shape.end)
            ))
        case let .arrow(shape):
            return .arrow(ArrowShape(
                start: transformPoint(shape.start),
                end: transformPoint(shape.end),
                curvature: shape.curvature,
                headStyle: shape.headStyle,
                label: shape.label,
                labelBoxColor: shape.labelBoxColor,
                labelPlacement: shape.labelPlacement,
                labelFontSize: shape.labelFontSize,
                labelTextColor: shape.labelTextColor,
                headShape: shape.headShape
            ))
        case let .freehand(shape):
            return .freehand(FreehandShape(points: shape.points.map(transformPoint)))
        case let .highlighter(shape):
            return .highlighter(HighlighterShape(points: shape.points.map(transformPoint)))
        case let .highlight(shape):
            return .highlight(HighlightShape(rect: transformRect(shape.rect)))
        case let .text(shape):
            return .text(TextShape(rect: transformRect(shape.rect), text: shape.text, alignment: shape.alignment))
        case let .callout(shape):
            return .callout(CalloutShape(
                rect: transformRect(shape.rect),
                number: shape.number,
                text: shape.text,
                alignment: shape.alignment,
                style: shape.style,
                leaderPoint: shape.leaderPoint.map(transformPoint)
            ))
        case let .measurement(shape):
            return .measurement(MeasurementShape(
                start: transformPoint(shape.start),
                end: transformPoint(shape.end)
            ))
        case let .spotlight(shape):
            return .spotlight(SpotlightShape(rect: transformRect(shape.rect), isEllipse: shape.isEllipse))
        case let .imageOverlay(shape):
            return .imageOverlay(ImageOverlayShape(assetID: shape.assetID, rect: transformRect(shape.rect), image: shape.image, opacity: shape.opacity, role: shape.role))
        case let .redaction(shape):
            return .redaction(RedactionShape(rect: transformRect(shape.rect), mode: shape.mode))
        }
    }

    func unrotatedBoundingRect(style: AnnotationStyle) -> CGRect {
        switch self {
        case let .rectangle(shape):
            return standardizedRect(shape.rect)
        case let .ellipse(shape):
            return standardizedRect(shape.rect)
        case let .line(shape):
            return lineBounds(from: shape.start, to: shape.end, padding: 10)
        case let .arrow(shape):
            let lineRect = lineBounds(from: shape.start, to: shape.end, padding: 18)
            return gscBoundingRect(of: [lineRect, arrowLabelRect(for: shape)]).integral
        case let .measurement(shape):
            return lineBounds(from: shape.start, to: shape.end, padding: 10)
        case let .freehand(shape):
            return polylineBounds(for: shape.points, style: style)
        case let .highlighter(shape):
            return polylineBounds(for: shape.points, style: style)
        case let .highlight(shape):
            return standardizedRect(shape.rect)
        case let .text(shape):
            return standardizedRect(shape.rect)
        case let .callout(shape):
            if let leaderPoint = shape.leaderPoint {
                let leaderRect = lineBounds(from: shape.rect.center, to: leaderPoint, padding: 12)
                return gscBoundingRect(of: [standardizedRect(shape.rect), leaderRect]).integral
            }
            return standardizedRect(shape.rect)
        case let .spotlight(shape):
            return standardizedRect(shape.rect)
        case let .imageOverlay(shape):
            return standardizedRect(shape.rect)
        case let .redaction(shape):
            return standardizedRect(shape.rect)
        }
    }

    private func standardizedRect(_ rect: CGRect) -> CGRect {
        rect.standardized.integral
    }

    private func lineBounds(from start: CGPoint, to end: CGPoint, padding: CGFloat) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        .insetBy(dx: -padding, dy: -padding)
        .integral
    }

    private func polylineBounds(for points: [CGPoint], style: AnnotationStyle) -> CGRect {
        let rect = gscBoundingRect(of: points.map { CGRect(origin: $0, size: .zero) })
        let padding = style.lineWidth + 6
        return rect.insetBy(dx: -padding, dy: -padding).integral
    }
}

nonisolated struct Annotation: Identifiable, Equatable {
    let id: UUID
    var groupID: UUID?
    var kind: AnnotationKind
    var style: AnnotationStyle
    var rotationDegrees: CGFloat = 0

    var editorTool: EditorTool {
        kind.editorTool
    }

    var isTextEditable: Bool {
        kind.isTextEditable
    }

    var redactionMode: RedactionMode? {
        kind.redactionMode
    }

    var textAlignmentMode: TextAlignmentMode? {
        kind.textAlignmentMode
    }

    var supportsFillEditing: Bool {
        kind.supportsFillEditing
    }

    nonisolated var boundingRect: CGRect {
        gscRotatedBoundingRect(unrotatedBoundingRect, degrees: rotationDegrees).integral
    }

    func contains(_ point: CGPoint) -> Bool {
        let point = gscPoint(point, rotatedByDegrees: -rotationDegrees, around: unrotatedBoundingRect.center)

        switch kind {
        case let .ellipse(shape):
            let rect = shape.rect.insetBy(dx: -6, dy: -6)

            guard rect.width > 0, rect.height > 0 else {
                return false
            }

            let normalizedX = (point.x - rect.midX) / (rect.width / 2)
            let normalizedY = (point.y - rect.midY) / (rect.height / 2)
            return normalizedX * normalizedX + normalizedY * normalizedY <= 1.1
        case let .line(shape):
            return gscDistanceFromPoint(point, toSegmentFrom: shape.start, to: shape.end) <= max(style.lineWidth * 1.5, 8)
        case let .arrow(shape):
            let lineHit = gscDistanceFromPoint(point, toSegmentFrom: shape.start, to: shape.end) <= max(style.lineWidth * 1.5, 10)
            let labelHit = !shape.label.isEmpty && arrowLabelRect(for: shape).insetBy(dx: -6, dy: -6).contains(point)
            return lineHit || labelHit
        case let .measurement(shape):
            return gscDistanceFromPoint(point, toSegmentFrom: shape.start, to: shape.end) <= max(style.lineWidth * 1.5, 8)
        case let .freehand(shape):
            return gscDistanceFromPoint(point, toPolyline: shape.points) <= max(style.lineWidth * 1.5, 8)
        case let .highlighter(shape):
            return gscDistanceFromPoint(point, toPolyline: shape.points) <= max(style.lineWidth * 1.5, 8)
        default:
            return unrotatedBoundingRect.insetBy(dx: -6, dy: -6).contains(point)
        }
    }

    func translated(by delta: CGSize) -> Annotation {
        transformingGeometry(
            rect: { $0.offsetBy(dx: delta.width, dy: delta.height) },
            point: { $0.gscOffsetting(x: delta.width, y: delta.height) }
        )
    }

    func scaled(from oldBounds: CGRect, to newBounds: CGRect) -> Annotation {
        transformingGeometry(
            rect: { gscScaledRect($0, from: oldBounds, to: newBounds) },
            point: { gscScaledPoint($0, from: oldBounds, to: newBounds) }
        )
    }

    func scaled(from oldBounds: CGRect, to newBounds: SignedScaleBounds) -> Annotation {
        transformingGeometry(
            rect: { gscScaledRect($0, from: oldBounds, to: newBounds) },
            point: { gscScaledPoint($0, from: oldBounds, to: newBounds) }
        )
    }

    func resized(to rect: CGRect) -> Annotation {
        scaled(from: boundingRect, to: rect.standardized.integral)
    }

    func updatingRotationDegrees(_ degrees: CGFloat) -> Annotation {
        var copy = self
        copy.rotationDegrees = degrees.truncatingRemainder(dividingBy: 360)
        return copy
    }

    func updatingText(_ text: String) -> Annotation {
        updatingText(text, refittingBounds: true)
    }

    func updatingText(_ text: String, refittingBounds: Bool = true) -> Annotation {
        var copy = self

        switch kind {
        case let .text(shape):
            let fittedRect = refittingBounds
                ? gscFittedTextRect(
                    for: text,
                    currentRect: shape.rect,
                    font: NSFont.systemFont(ofSize: style.fontSize, weight: .semibold),
                    horizontalPadding: 24,
                    verticalPadding: 20,
                    minSize: CGSize(width: 180, height: 60),
                    maxWidth: 520
                )
                : shape.rect.gscIntegralStandardized
            copy.kind = .text(TextShape(rect: fittedRect, text: text, alignment: shape.alignment))
        case let .callout(shape):
            let fittedRect: CGRect

            if refittingBounds {
                let bodyRect = CGRect(
                    x: shape.rect.minX,
                    y: shape.rect.minY,
                    width: max(shape.rect.width - 54, 140),
                    height: shape.rect.height
                )
                let fittedBodyRect = gscFittedTextRect(
                    for: text,
                    currentRect: bodyRect,
                    font: NSFont.systemFont(ofSize: style.fontSize, weight: .semibold),
                    horizontalPadding: 40,
                    verticalPadding: 24,
                    minSize: CGSize(width: 140, height: 72),
                    maxWidth: 420
                )
                fittedRect = CGRect(
                    x: shape.rect.minX,
                    y: shape.rect.minY,
                    width: fittedBodyRect.width + 54,
                    height: max(fittedBodyRect.height, 72)
                ).gscIntegralStandardized
            } else {
                fittedRect = shape.rect.gscIntegralStandardized
            }

            copy.kind = .callout(CalloutShape(
                rect: fittedRect,
                number: shape.number,
                text: text,
                alignment: shape.alignment,
                style: shape.style,
                leaderPoint: shape.leaderPoint
            ))
        default:
            return self
        }

        return copy
    }

    func refittingTextBounds() -> Annotation {
        switch kind {
        case let .text(shape):
            return updatingText(shape.text, refittingBounds: true)
        case let .callout(shape):
            return updatingText(shape.text, refittingBounds: true)
        default:
            return self
        }
    }

    func updatingStyle(_ style: AnnotationStyle) -> Annotation {
        var copy = self
        copy.style = style
        return copy
    }

    func updatingRedactionMode(_ mode: RedactionMode) -> Annotation {
        guard case let .redaction(shape) = kind else {
            return self
        }

        var copy = self
        copy.kind = .redaction(RedactionShape(rect: shape.rect, mode: mode))
        return copy
    }

    func updatingGroup(_ groupID: UUID?) -> Annotation {
        var copy = self
        copy.groupID = groupID
        return copy
    }

    func updatingTextAlignment(_ alignment: TextAlignmentMode) -> Annotation {
        var copy = self

        switch kind {
        case let .text(shape):
            copy.kind = .text(TextShape(rect: shape.rect, text: shape.text, alignment: alignment))
        case let .callout(shape):
            copy.kind = .callout(CalloutShape(
                rect: shape.rect,
                number: shape.number,
                text: shape.text,
                alignment: alignment,
                style: shape.style,
                leaderPoint: shape.leaderPoint
            ))
        default:
            return self
        }

        return copy
    }

    func updatingCalloutNumber(_ number: Int) -> Annotation {
        guard case let .callout(shape) = kind else {
            return self
        }

        var copy = self
        copy.kind = .callout(CalloutShape(
            rect: shape.rect,
            number: number,
            text: shape.text,
            alignment: shape.alignment,
            style: shape.style,
            leaderPoint: shape.leaderPoint
        ))
        return copy
    }

    func updatingArrow(
        curvature: CGFloat? = nil,
        headStyle: ArrowHeadStyle? = nil,
        label: String? = nil,
        labelBoxColor: RGBAColor? = nil,
        labelPlacement: ArrowLabelPlacement? = nil,
        labelFontSize: CGFloat? = nil,
        labelTextColor: ArrowLabelTextColor? = nil,
        headShape: ArrowHeadShape? = nil
    ) -> Annotation {
        guard case let .arrow(shape) = kind else {
            return self
        }

        var copy = self
        copy.kind = .arrow(ArrowShape(
            start: shape.start,
            end: shape.end,
            curvature: curvature ?? shape.curvature,
            headStyle: headStyle ?? shape.headStyle,
            label: label ?? shape.label,
            labelBoxColor: labelBoxColor ?? shape.labelBoxColor,
            labelPlacement: labelPlacement ?? shape.labelPlacement,
            labelFontSize: labelFontSize ?? shape.labelFontSize,
            labelTextColor: labelTextColor ?? shape.labelTextColor,
            headShape: headShape ?? shape.headShape
        ))
        return copy
    }

    func updatingArrow(curvature: CGFloat? = nil, headStyle: ArrowHeadStyle? = nil, label: String? = nil) -> Annotation {
        updatingArrow(
            curvature: curvature,
            headStyle: headStyle,
            label: label,
            labelBoxColor: nil,
            labelPlacement: nil,
            labelFontSize: nil,
            labelTextColor: nil,
            headShape: nil
        )
    }

    func updatingCalloutStyle(_ style: CalloutVisualStyle) -> Annotation {
        guard case let .callout(shape) = kind else {
            return self
        }

        var copy = self
        copy.kind = .callout(CalloutShape(
            rect: shape.rect,
            number: shape.number,
            text: shape.text,
            alignment: shape.alignment,
            style: style,
            leaderPoint: shape.leaderPoint
        ))
        return copy
    }

    private func transformingGeometry(
        rect transformRect: (CGRect) -> CGRect,
        point transformPoint: (CGPoint) -> CGPoint
    ) -> Annotation {
        var copy = self
        copy.kind = kind.transformingGeometry(rect: transformRect, point: transformPoint)
        return copy
    }

    nonisolated static func makeRectangle(in rect: CGRect, style: AnnotationStyle = .default(for: .rectangle)) -> Annotation {
        Annotation(id: UUID(), groupID: nil, kind: .rectangle(RectangleShape(rect: rect.standardized.integral)), style: style)
    }

    nonisolated static func makeEllipse(in rect: CGRect, style: AnnotationStyle = .default(for: .ellipse)) -> Annotation {
        Annotation(id: UUID(), groupID: nil, kind: .ellipse(EllipseShape(rect: rect.standardized.integral)), style: style)
    }

    nonisolated static func makeLine(from start: CGPoint, to end: CGPoint, style: AnnotationStyle = .default(for: .line)) -> Annotation {
        Annotation(id: UUID(), groupID: nil, kind: .line(LineShape(start: start, end: end)), style: style)
    }

    nonisolated static func makeArrow(from start: CGPoint, to end: CGPoint, style: AnnotationStyle = .default(for: .arrow)) -> Annotation {
        Annotation(id: UUID(), groupID: nil, kind: .arrow(ArrowShape(start: start, end: end)), style: style)
    }

    nonisolated static func makeFreehand(points: [CGPoint], style: AnnotationStyle = .default(for: .freehand)) -> Annotation {
        Annotation(id: UUID(), groupID: nil, kind: .freehand(FreehandShape(points: points)), style: style)
    }

    nonisolated static func makeHighlighter(points: [CGPoint], style: AnnotationStyle = .default(for: .highlighter)) -> Annotation {
        Annotation(id: UUID(), groupID: nil, kind: .highlighter(HighlighterShape(points: points)), style: style)
    }

    nonisolated static func makeHighlight(in rect: CGRect, style: AnnotationStyle = .default(for: .highlight)) -> Annotation {
        Annotation(id: UUID(), groupID: nil, kind: .highlight(HighlightShape(rect: rect.standardized.integral)), style: style)
    }

    nonisolated static func makeText(at point: CGPoint, style: AnnotationStyle = .default(for: .text)) -> Annotation {
        Annotation(
            id: UUID(),
            groupID: nil,
            kind: .text(TextShape(rect: CGRect(x: point.x, y: point.y, width: 260, height: 80), text: "Text", alignment: .left)),
            style: style
        )
    }

    nonisolated static func makeCallout(at point: CGPoint, number: Int, style: AnnotationStyle = .default(for: .callout)) -> Annotation {
        let rect = CGRect(x: point.x + 24, y: point.y + 18, width: 260, height: 72)
        return Annotation(
            id: UUID(),
            groupID: nil,
            kind: .callout(CalloutShape(rect: rect, number: number, text: "Callout \(number)", alignment: .left, style: .filled, leaderPoint: point)),
            style: style
        )
    }

    nonisolated static func makeMeasurement(from start: CGPoint, to end: CGPoint, style: AnnotationStyle = .default(for: .measure)) -> Annotation {
        Annotation(id: UUID(), groupID: nil, kind: .measurement(MeasurementShape(start: start, end: end)), style: style)
    }

    nonisolated static func makeSpotlight(in rect: CGRect, style: AnnotationStyle = .default(for: .spotlight)) -> Annotation {
        Annotation(id: UUID(), groupID: nil, kind: .spotlight(SpotlightShape(rect: rect.standardized.integral)), style: style)
    }

    nonisolated static func makeImageOverlay(image: CGImage, in rect: CGRect, assetID: UUID = UUID(), role: ImageOverlayShape.Role = .importedImage, style: AnnotationStyle = AnnotationStyle(strokeColor: .clear, fillColor: .clear, lineWidth: 0, fontSize: 0, effectRadius: 0)) -> Annotation {
        Annotation(id: UUID(), groupID: nil, kind: .imageOverlay(ImageOverlayShape(assetID: assetID, rect: rect.standardized.integral, image: image, role: role)), style: style)
    }

    nonisolated static func makeRedaction(in rect: CGRect, mode: RedactionMode, style: AnnotationStyle) -> Annotation {
        Annotation(id: UUID(), groupID: nil, kind: .redaction(RedactionShape(rect: rect.standardized.integral, mode: mode)), style: style)
    }

    nonisolated static func makeBlur(in rect: CGRect, style: AnnotationStyle = .default(for: .blur)) -> Annotation {
        makeRedaction(in: rect, mode: .blur, style: style)
    }

    nonisolated static func makePixelate(in rect: CGRect, style: AnnotationStyle = .default(for: .pixelate)) -> Annotation {
        makeRedaction(in: rect, mode: .pixelate, style: style)
    }

    nonisolated static func makeSolidRedaction(in rect: CGRect, style: AnnotationStyle = .default(for: .redact)) -> Annotation {
        makeRedaction(in: rect, mode: .solid, style: style)
    }

    private var unrotatedBoundingRect: CGRect {
        kind.unrotatedBoundingRect(style: style)
    }
}

nonisolated private func arrowLabelRect(for shape: ArrowShape) -> CGRect {
    guard !shape.label.isEmpty else {
        return CGRect(origin: shape.end, size: .zero)
    }

    let geometry = arrowLabelGeometry(for: shape)
    guard geometry.rotationDegrees != 0 else {
        return geometry.rect.integral
    }

    return gscRotatedBoundingRect(geometry.rect, degrees: geometry.rotationDegrees).integral
}

nonisolated private func arrowLabelGeometry(for shape: ArrowShape) -> (rect: CGRect, rotationDegrees: CGFloat) {
    let fontSize = max(shape.labelFontSize, 8)
    let height = max(fontSize + 14, 28)
    let width = max(CGFloat(shape.label.count) * fontSize * 0.58 + 24, 64)
    let midpoint = arrowPoint(on: shape, at: 0.5)
    let angle = atan2(shape.end.y - shape.start.y, shape.end.x - shape.start.x)
    let offset = height / 2 + 8
    let center: CGPoint
    let rotationDegrees: CGFloat

    switch shape.labelPlacement {
    case .horizontal:
        center = midpoint
        rotationDegrees = 0
    case .parallelAbove:
        let labelOffset = gscArrowLabelOffset(angle: angle, distance: offset, placeAbove: true, yAxisPointsDown: true)
        center = CGPoint(x: midpoint.x + labelOffset.x, y: midpoint.y + labelOffset.y)
        rotationDegrees = gscUprightTextRotationDegrees(for: angle * 180 / .pi)
    case .parallelBelow:
        let labelOffset = gscArrowLabelOffset(angle: angle, distance: offset, placeAbove: false, yAxisPointsDown: true)
        center = CGPoint(x: midpoint.x + labelOffset.x, y: midpoint.y + labelOffset.y)
        rotationDegrees = gscUprightTextRotationDegrees(for: angle * 180 / .pi)
    }

    return (
        CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height),
        rotationDegrees
    )
}

nonisolated private func arrowPoint(on shape: ArrowShape, at t: CGFloat) -> CGPoint {
    guard abs(shape.curvature) > 0.5 else {
        return CGPoint(
            x: shape.start.x + (shape.end.x - shape.start.x) * t,
            y: shape.start.y + (shape.end.y - shape.start.y) * t
        )
    }

    let control = arrowControlPoint(for: shape)
    let mt = 1 - t
    return CGPoint(
        x: mt * mt * shape.start.x + 2 * mt * t * control.x + t * t * shape.end.x,
        y: mt * mt * shape.start.y + 2 * mt * t * control.y + t * t * shape.end.y
    )
}

nonisolated private func arrowControlPoint(for shape: ArrowShape) -> CGPoint {
    let midpoint = CGPoint(x: (shape.start.x + shape.end.x) / 2, y: (shape.start.y + shape.end.y) / 2)
    let dx = shape.end.x - shape.start.x
    let dy = shape.end.y - shape.start.y
    let length = max(hypot(dx, dy), 1)
    let normal = CGPoint(x: -dy / length, y: dx / length)
    return CGPoint(x: midpoint.x + normal.x * shape.curvature, y: midpoint.y + normal.y * shape.curvature)
}

extension CGRect {
    nonisolated var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

nonisolated func gscPoint(_ point: CGPoint, rotatedByDegrees degrees: CGFloat, around center: CGPoint) -> CGPoint {
    guard degrees != 0 else {
        return point
    }

    let radians = degrees * .pi / 180
    let translated = CGPoint(x: point.x - center.x, y: point.y - center.y)
    return CGPoint(
        x: center.x + translated.x * cos(radians) - translated.y * sin(radians),
        y: center.y + translated.x * sin(radians) + translated.y * cos(radians)
    )
}

nonisolated func gscRotatedBoundingRect(_ rect: CGRect, degrees: CGFloat) -> CGRect {
    guard degrees != 0 else {
        return rect
    }

    let center = rect.center
    let points = [
        CGPoint(x: rect.minX, y: rect.minY),
        CGPoint(x: rect.maxX, y: rect.minY),
        CGPoint(x: rect.maxX, y: rect.maxY),
        CGPoint(x: rect.minX, y: rect.maxY)
    ].map { gscPoint($0, rotatedByDegrees: degrees, around: center) }

    return gscBoundingRect(of: points.map { CGRect(origin: $0, size: .zero) })
}

nonisolated enum AlignmentMode: String, CaseIterable, Identifiable {
    case left
    case horizontalCenter
    case right
    case top
    case verticalCenter
    case bottom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .left:
            return "Left"
        case .horizontalCenter:
            return "Center"
        case .right:
            return "Right"
        case .top:
            return "Top"
        case .verticalCenter:
            return "Middle"
        case .bottom:
            return "Bottom"
        }
    }

    var systemImage: String {
        switch self {
        case .left:
            return "align.horizontal.left"
        case .horizontalCenter:
            return "align.horizontal.center"
        case .right:
            return "align.horizontal.right"
        case .top:
            return "align.vertical.top"
        case .verticalCenter:
            return "align.vertical.center"
        case .bottom:
            return "align.vertical.bottom"
        }
    }
}

nonisolated struct EditorSnapshot: Equatable {
    var cropRect: CGRect
    var annotations: [Annotation]
    var selectedAnnotationIDs: [UUID]
    var nextCalloutNumber: Int
    var presentation: ScreenshotPresentation = .plain
    var pinnedUIMapElementIDs: [UUID] = []

    // MARK: - Layer Reordering

    nonisolated func selectedAnnotationIndices(in annotationIDs: [UUID]? = nil) -> [Int] {
        let idSet = Set(annotationIDs ?? selectedAnnotationIDs)
        return annotations.enumerated().compactMap { index, annotation in
            idSet.contains(annotation.id) ? index : nil
        }
    }

    nonisolated var canReorderForward: Bool {
        let selectedIndices = selectedAnnotationIndices()
        guard let maxIndex = selectedIndices.max() else { return false }
        return maxIndex < annotations.count - 1
    }

    nonisolated var canReorderBackward: Bool {
        let selectedIndices = selectedAnnotationIndices()
        guard let minIndex = selectedIndices.min() else { return false }
        return minIndex > 0
    }
}
