import CoreGraphics
import Foundation

nonisolated enum RedactionRenderStyle {
    static func dashPattern(for mode: RedactionMode, scale: CGFloat) -> [CGFloat] {
        switch mode {
        case .blur:
            let dashLength = scaled(6, by: scale)
            return [dashLength, dashLength]
        case .pixelate:
            return [scaled(3, by: scale), scaled(5, by: scale)]
        case .solid:
            return []
        }
    }

    static func cornerRadius(scale: CGFloat) -> CGFloat {
        scaled(8, by: scale)
    }

    private static func scaled(_ value: CGFloat, by scale: CGFloat) -> CGFloat {
        value * scale
    }
}
