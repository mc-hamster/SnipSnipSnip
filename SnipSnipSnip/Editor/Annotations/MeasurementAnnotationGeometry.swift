import AppKit
import CoreText

/// Derived from source pixels, never persisted or recomputed from a zoomed line.
nonisolated struct MeasurementLabelPlan {
    let text: String
    let rect: CGRect
    let font: NSFont

    func projected(rect transform: (CGRect) -> CGRect, scale: CGFloat) -> MeasurementLabelPlan {
        MeasurementLabelPlan(text: text, rect: transform(rect),
            font: CTFontCreateCopyWithAttributes(font as CTFont, font.pointSize * scale, nil, nil) as NSFont)
    }
}

nonisolated enum MeasurementAnnotationGeometry {
    static func label(for shape: MeasurementShape, style: AnnotationStyle) -> MeasurementLabelPlan {
        let length = shape.length.isFinite ? max(shape.length.rounded(), 0) : 0
        let text = length < CGFloat(Int.max) ? "\(Int(length)) px" : String(format: "%.0f px", length)
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(style.fontSize, 12), weight: .semibold)
        let size = (text as NSString).size(withAttributes: [.font: font])
        let center = CGPoint(x: (shape.start.x + shape.end.x) / 2, y: (shape.start.y + shape.end.y) / 2)
        return MeasurementLabelPlan(text: text,
            rect: CGRect(x: center.x - size.width / 2 - 8, y: center.y - size.height / 2 - 5,
                width: size.width + 16, height: size.height + 10), font: font)
    }

    static func bounds(for shape: MeasurementShape, style: AnnotationStyle) -> CGRect {
        let lineAndTicks = AnnotationGeometry.lineBounds(from: shape.start, to: shape.end,
            padding: 4 + max(style.lineWidth, 0) / 2)
        return lineAndTicks.union(label(for: shape, style: style).rect).integral
    }
}
