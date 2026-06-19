import CoreGraphics
import Foundation

nonisolated enum EditorRenderGeometry {
    static func arrowBodyPath(for shape: ArrowShape) -> CGPath {
        let path = CGMutablePath()
        path.move(to: shape.start)
        if abs(shape.curvature) > 0.5 {
            let control = AnnotationGeometry.arrowControlPoint(for: shape)
            path.addCurve(to: shape.end, control1: control, control2: control)
        } else {
            path.addLine(to: shape.end)
        }
        return path
    }

    static func arrowLabelGeometry(
        for shape: ArrowShape,
        yAxisPointsDown: Bool
    ) -> (rect: CGRect, rotationDegrees: CGFloat) {
        let fontSize = max(shape.labelFontSize, 8)
        let height = max(fontSize + 14, 28)
        let width = max(CGFloat(shape.label.count) * fontSize * 0.58 + 24, 64)
        let midpoint = AnnotationGeometry.arrowPoint(on: shape, at: 0.5)
        let angle = atan2(shape.end.y - shape.start.y, shape.end.x - shape.start.x)
        let offset = height / 2 + 8
        let center: CGPoint
        let rotationDegrees: CGFloat

        switch shape.labelPlacement {
        case .horizontal:
            center = midpoint
            rotationDegrees = 0
        case .parallelAbove:
            let labelOffset = gscArrowLabelOffset(angle: angle, distance: offset, placeAbove: true, yAxisPointsDown: yAxisPointsDown)
            center = CGPoint(x: midpoint.x + labelOffset.x, y: midpoint.y + labelOffset.y)
            rotationDegrees = gscUprightTextRotationDegrees(for: angle * 180 / .pi)
        case .parallelBelow:
            let labelOffset = gscArrowLabelOffset(angle: angle, distance: offset, placeAbove: false, yAxisPointsDown: yAxisPointsDown)
            center = CGPoint(x: midpoint.x + labelOffset.x, y: midpoint.y + labelOffset.y)
            rotationDegrees = gscUprightTextRotationDegrees(for: angle * 180 / .pi)
        }

        return (
            CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height),
            rotationDegrees
        )
    }

    static func arrowEndpointTangentAngle(tip: CGPoint, tail: CGPoint, curvature: CGFloat) -> CGFloat {
        guard abs(curvature) > 0.5 else {
            return atan2(tip.y - tail.y, tip.x - tail.x)
        }

        let control = AnnotationGeometry.arrowControlPoint(for: ArrowShape(start: tail, end: tip, curvature: curvature))
        let tangent = CGPoint(x: tip.x - control.x, y: tip.y - control.y)
        guard hypot(tangent.x, tangent.y) > .leastNonzeroMagnitude else {
            return atan2(tip.y - tail.y, tip.x - tail.x)
        }
        return atan2(tangent.y, tangent.x)
    }
}
