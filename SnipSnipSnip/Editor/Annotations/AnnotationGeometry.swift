import CoreGraphics
import Foundation

nonisolated enum AnnotationGeometry {
    static func transforming(
        _ kind: AnnotationKind,
        rect transformRect: (CGRect) -> CGRect,
        point transformPoint: (CGPoint) -> CGPoint
    ) -> AnnotationKind {
        switch kind {
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
        case let .statusMark(shape):
            return .statusMark(StatusMarkShape(rect: transformRect(shape.rect)))
        case let .freehand(shape):
            return .freehand(FreehandShape(points: shape.points.map(transformPoint)))
        case let .highlighter(shape):
            return .highlighter(HighlighterShape(points: shape.points.map(transformPoint)))
        case let .highlight(shape):
            return .highlight(HighlightShape(rect: transformRect(shape.rect)))
        case let .text(shape):
            return .text(TextShape(
                rect: transformRect(shape.rect),
                text: shape.text,
                alignment: shape.alignment,
                automaticallySizesToText: shape.automaticallySizesToText
            ))
        case let .callout(shape):
            return .callout(CalloutShape(
                rect: transformRect(shape.rect),
                number: shape.number,
                text: shape.text,
                alignment: shape.alignment,
                style: shape.style,
                leaderPoint: shape.leaderPoint.map(transformPoint),
                automaticallySizesToText: shape.automaticallySizesToText
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

    static func unrotatedBoundingRect(for kind: AnnotationKind, style: AnnotationStyle) -> CGRect {
        switch kind {
        case let .rectangle(shape):
            return standardizedRect(shape.rect)
        case let .ellipse(shape):
            return standardizedRect(shape.rect)
        case let .line(shape):
            return lineBounds(from: shape.start, to: shape.end, padding: 10)
        case let .arrow(shape):
            let lineRect = lineBounds(from: shape.start, to: shape.end, padding: 18)
            return gscBoundingRect(of: [lineRect, arrowLabelRect(for: shape)]).integral
        case let .statusMark(shape):
            return standardizedRect(shape.rect)
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

    static func resizeReferenceRect(for kind: AnnotationKind, style: AnnotationStyle) -> CGRect {
        switch kind {
        case let .line(shape):
            return pointBounds([shape.start, shape.end])
        case let .arrow(shape):
            var points = [shape.start, shape.end]
            if abs(shape.curvature) > 0.5 {
                points.append(arrowControlPoint(for: shape))
            }
            return pointBounds(points)
        case let .measurement(shape):
            return pointBounds([shape.start, shape.end])
        case let .freehand(shape):
            return pointBounds(shape.points)
        case let .highlighter(shape):
            return pointBounds(shape.points)
        case let .callout(shape):
            if let leaderPoint = shape.leaderPoint {
                return gscBoundingRect(of: [standardizedRect(shape.rect), pointBounds([leaderPoint])])
            }
            return standardizedRect(shape.rect)
        default:
            return unrotatedBoundingRect(for: kind, style: style)
        }
    }

    static func standardizedRect(_ rect: CGRect) -> CGRect {
        rect.standardized.integral
    }

    static func lineBounds(from start: CGPoint, to end: CGPoint, padding: CGFloat) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        .insetBy(dx: -padding, dy: -padding)
        .integral
    }

    static func polylineBounds(for points: [CGPoint], style: AnnotationStyle) -> CGRect {
        let rect = gscBoundingRect(of: points.map { CGRect(origin: $0, size: .zero) })
        let padding = style.lineWidth + 6
        return rect.insetBy(dx: -padding, dy: -padding).integral
    }

    static func pointBounds(_ points: [CGPoint]) -> CGRect {
        gscBoundingRect(of: points.map { CGRect(origin: $0, size: .zero) })
    }

    static func arrowLabelRect(for shape: ArrowShape) -> CGRect {
        guard !shape.label.isEmpty else {
            return CGRect(origin: shape.end, size: .zero)
        }

        let geometry = arrowLabelGeometry(for: shape)
        guard geometry.rotationDegrees != 0 else {
            return geometry.rect.integral
        }

        return gscRotatedBoundingRect(geometry.rect, degrees: geometry.rotationDegrees).integral
    }

    static func arrowLabelGeometry(for shape: ArrowShape) -> (rect: CGRect, rotationDegrees: CGFloat) {
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

    static func arrowPoint(on shape: ArrowShape, at t: CGFloat) -> CGPoint {
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

    static func arrowControlPoint(for shape: ArrowShape) -> CGPoint {
        let midpoint = CGPoint(x: (shape.start.x + shape.end.x) / 2, y: (shape.start.y + shape.end.y) / 2)
        let dx = shape.end.x - shape.start.x
        let dy = shape.end.y - shape.start.y
        let length = max(hypot(dx, dy), 1)
        let normal = CGPoint(x: -dy / length, y: dx / length)
        return CGPoint(x: midpoint.x + normal.x * shape.curvature, y: midpoint.y + normal.y * shape.curvature)
    }
}
