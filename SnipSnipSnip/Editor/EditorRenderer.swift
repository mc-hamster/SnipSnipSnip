import AppKit
import CoreText
import CoreImage

nonisolated private struct ArrowHeadGeometry {
    let tip: CGPoint
    let left: CGPoint
    let right: CGPoint

    var base: CGPoint {
        CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
    }

    var stealthNotch: CGPoint {
        CGPoint(
            x: base.x + (tip.x - base.x) * 0.38,
            y: base.y + (tip.y - base.y) * 0.38
        )
    }

    var diamondBack: CGPoint {
        CGPoint(
            x: base.x - (tip.x - base.x) * 0.55,
            y: base.y - (tip.y - base.y) * 0.55
        )
    }
}

enum EditorRenderer {
    nonisolated private static let ciContext = CIContext(options: nil)
    nonisolated private static let croppedImageCache = RenderImageCache(totalCostLimit: 128 * 1024 * 1024)
    nonisolated private static let processedRedactionCache = RenderImageCache(totalCostLimit: 64 * 1024 * 1024)
    nonisolated private static let previewAttributedTextCache = RenderAttributedTextCache(totalCostLimit: 8 * 1024 * 1024)
    nonisolated(unsafe) private static var exportFontCache = [NSString: CTFont]()
    nonisolated(unsafe) private static var exportParagraphStyleCache = [NSString: NSParagraphStyle]()
    nonisolated private static let exportCacheLock = NSLock()

    nonisolated static func render(baseImage: CGImage, snapshot: EditorSnapshot) -> CGImage? {
        let crop = snapshot.cropRect.gscIntegralStandardized
        let width = Int(crop.width)
        let height = Int(crop.height)

        guard width > 0,
              height > 0,
              let croppedBase = croppedBaseImage(for: baseImage, crop: crop),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        let projection = renderProjection(for: crop)
        let canvasRect = projection.destinationBounds

        context.interpolationQuality = .high
        context.draw(croppedBase, in: canvasRect)

        for annotation in snapshot.annotations {
            drawExport(
                annotation: annotation,
                croppedBase: croppedBase,
                projection: projection,
                context: context
            )
        }

        return context.makeImage()
    }

    nonisolated static func displayBaseImage(baseImage: CGImage, snapshot: EditorSnapshot) -> CGImage? {
        let crop = snapshot.cropRect.gscIntegralStandardized

        guard crop.width > 0, crop.height > 0 else {
            return nil
        }

        return croppedBaseImage(for: baseImage, crop: crop)
    }

    static func draw(baseImage: CGImage, snapshot: EditorSnapshot, canvasRect: CGRect, draftAnnotations: [Annotation]) {
        drawContent(baseImage: baseImage, snapshot: snapshot, canvasRect: canvasRect, draftAnnotations: draftAnnotations, drawBaseImage: true)
    }

    static func drawAnnotations(baseImage: CGImage, snapshot: EditorSnapshot, canvasRect: CGRect, draftAnnotations: [Annotation]) {
        drawContent(baseImage: baseImage, snapshot: snapshot, canvasRect: canvasRect, draftAnnotations: draftAnnotations, drawBaseImage: false)
    }

    private static func drawContent(baseImage: CGImage, snapshot: EditorSnapshot, canvasRect: CGRect, draftAnnotations: [Annotation], drawBaseImage: Bool) {
        guard let projection = previewProjection(for: baseImage, canvasRect: canvasRect) else {
            return
        }

        if drawBaseImage {
            NSImage(cgImage: baseImage, size: projection.sourceDocumentRect.size).draw(
                in: projection.destinationBounds,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
        }

        let renderScale = displayScale(for: projection)

        for annotation in snapshot.annotations {
            draw(annotation: annotation, sourceImage: baseImage, projection: projection, renderScale: renderScale)
        }

        for annotation in draftAnnotations {
            draw(annotation: annotation, sourceImage: baseImage, projection: projection, renderScale: renderScale)
        }
    }

    private static func draw(annotation: Annotation, sourceImage: CGImage, projection: DocumentProjection, renderScale: CGFloat) {
        let displayStyle = annotation.style.scaledForDisplay(by: renderScale)
        let localRect = projection.sourceLocalRect(fromDocumentRect: annotation.boundingRect)
        let displayRect = mapRect(annotation.boundingRect, using: projection)

        if case let .spotlight(shape) = annotation.kind {
            drawSpotlight(
                shape,
                in: mapRect(shape.rect, using: projection),
                canvasRect: projection.destinationBounds,
                style: displayStyle,
                scale: renderScale,
                rotationDegrees: annotation.rotationDegrees,
                rotationCenter: displayRect.center
            )
            return
        }

        NSGraphicsContext.saveGraphicsState()
        rotatePreviewIfNeeded(degrees: annotation.rotationDegrees, around: displayRect.center)
        defer {
            NSGraphicsContext.restoreGraphicsState()
        }

        switch annotation.kind {
        case let .rectangle(shape):
            let path = rectanglePreviewPath(in: mapRect(shape.rect, using: projection), style: displayStyle)
            strokeAndFill(path: path, style: displayStyle)
        case let .ellipse(shape):
            let path = NSBezierPath(ovalIn: mapRect(shape.rect, using: projection))
            strokeAndFill(path: path, style: displayStyle)
        case let .line(shape):
            drawLine(
                from: mapPoint(shape.start, using: projection),
                to: mapPoint(shape.end, using: projection),
                style: displayStyle
            )
        case let .arrow(shape):
            drawArrow(
                ArrowShape(
                    start: mapPoint(shape.start, using: projection),
                    end: mapPoint(shape.end, using: projection),
                    curvature: shape.curvature * renderScale,
                    headStyle: shape.headStyle,
                    label: shape.label,
                    labelBoxColor: shape.labelBoxColor,
                    labelPlacement: shape.labelPlacement,
                    labelFontSize: shape.labelFontSize * renderScale,
                    labelTextColor: shape.labelTextColor,
                    headShape: shape.headShape
                ),
                style: displayStyle,
                scale: renderScale
            )
        case let .freehand(shape):
            drawFreehand(points: shape.points.map { mapPoint($0, using: projection) }, style: displayStyle)
        case let .highlighter(shape):
            drawHighlighter(points: shape.points.map { mapPoint($0, using: projection) }, style: displayStyle)
        case let .highlight(shape):
            drawHighlight(in: mapRect(shape.rect, using: projection), style: displayStyle, scale: renderScale)
        case let .text(shape):
            drawText(shape.text, alignment: shape.alignment, in: mapRect(shape.rect, using: projection), style: displayStyle, scale: renderScale)
        case let .callout(shape):
            drawCallout(
                CalloutShape(
                    rect: mapRect(shape.rect, using: projection),
                    number: shape.number,
                    text: shape.text,
                    alignment: shape.alignment,
                    style: shape.style,
                    leaderPoint: shape.leaderPoint.map { mapPoint($0, using: projection) }
                ),
                in: mapRect(shape.rect, using: projection),
                style: displayStyle,
                scale: renderScale
            )
        case let .measurement(shape):
            drawMeasurement(
                shape,
                from: mapPoint(shape.start, using: projection),
                to: mapPoint(shape.end, using: projection),
                style: displayStyle,
                scale: renderScale
            )
        case .spotlight:
            assertionFailure("Spotlight annotations should return before generic rotation rendering")
        case let .imageOverlay(shape):
            drawImageOverlay(shape, in: mapRect(shape.rect, using: projection))
        case let .redaction(shape):
            drawRedaction(shape.mode, in: localRect, displayRect: displayRect, croppedBase: sourceImage, style: displayStyle, scale: renderScale)
        }
    }

    nonisolated private static func drawExport(annotation: Annotation, croppedBase: CGImage, projection: DocumentProjection, context: CGContext) {
        let renderScale: CGFloat = 1
        let displayStyle = annotation.style.scaledForDisplay(by: renderScale)
        let localRect = projection.sourceLocalRect(fromDocumentRect: annotation.boundingRect)
        let displayRect = exportRect(for: annotation.boundingRect, using: projection)

        if case let .spotlight(shape) = annotation.kind {
            drawSpotlightExport(
                shape,
                in: exportRect(for: shape.rect, using: projection),
                canvasRect: projection.destinationBounds,
                style: displayStyle,
                scale: renderScale,
                rotationDegrees: annotation.rotationDegrees,
                rotationCenter: displayRect.center,
                context: context
            )
            return
        }

        context.saveGState()
        rotateExportIfNeeded(degrees: annotation.rotationDegrees, around: displayRect.center, context: context)
        defer {
            context.restoreGState()
        }

        switch annotation.kind {
        case let .rectangle(shape):
            strokeAndFillExport(
                path: rectangleExportPath(in: exportRect(for: shape.rect, using: projection), style: displayStyle),
                style: displayStyle,
                context: context
            )
        case let .ellipse(shape):
            strokeAndFillExport(
                path: CGPath(ellipseIn: exportRect(for: shape.rect, using: projection), transform: nil),
                style: displayStyle,
                context: context
            )
        case let .line(shape):
            drawLineExport(
                from: exportPoint(for: shape.start, using: projection),
                to: exportPoint(for: shape.end, using: projection),
                style: displayStyle,
                context: context
            )
        case let .arrow(shape):
            drawArrowExport(
                ArrowShape(
                    start: exportPoint(for: shape.start, using: projection),
                    end: exportPoint(for: shape.end, using: projection),
                    curvature: shape.curvature,
                    headStyle: shape.headStyle,
                    label: shape.label,
                    labelBoxColor: shape.labelBoxColor,
                    labelPlacement: shape.labelPlacement,
                    labelFontSize: shape.labelFontSize,
                    labelTextColor: shape.labelTextColor,
                    headShape: shape.headShape
                ),
                style: displayStyle,
                scale: renderScale,
                context: context
            )
        case let .freehand(shape):
            drawFreehandExport(
                points: shape.points.map { exportPoint(for: $0, using: projection) },
                style: displayStyle,
                context: context
            )
        case let .highlighter(shape):
            drawHighlighterExport(
                points: shape.points.map { exportPoint(for: $0, using: projection) },
                style: displayStyle,
                context: context
            )
        case let .highlight(shape):
            drawHighlightExport(
                in: exportRect(for: shape.rect, using: projection),
                style: displayStyle,
                scale: renderScale,
                context: context
            )
        case let .text(shape):
            drawTextExport(
                shape.text,
                alignment: shape.alignment,
                in: exportRect(for: shape.rect, using: projection),
                style: displayStyle,
                scale: renderScale,
                context: context
            )
        case let .callout(shape):
            drawCalloutExport(
                CalloutShape(
                    rect: exportRect(for: shape.rect, using: projection),
                    number: shape.number,
                    text: shape.text,
                    alignment: shape.alignment,
                    style: shape.style,
                    leaderPoint: shape.leaderPoint.map { exportPoint(for: $0, using: projection) }
                ),
                in: exportRect(for: shape.rect, using: projection),
                style: displayStyle,
                scale: renderScale,
                context: context
            )
        case let .measurement(shape):
            drawMeasurementExport(
                shape,
                from: exportPoint(for: shape.start, using: projection),
                to: exportPoint(for: shape.end, using: projection),
                style: displayStyle,
                scale: renderScale,
                context: context
            )
        case .spotlight:
            assertionFailure("Spotlight annotations should return before generic rotation export rendering")
        case let .imageOverlay(shape):
            drawImageOverlayExport(
                shape,
                in: exportRect(for: shape.rect, using: projection),
                context: context
            )
        case let .redaction(shape):
            let compositedImage: CGImage

            switch shape.mode {
            case .blur, .pixelate:
                compositedImage = context.makeImage() ?? croppedBase
            case .solid:
                compositedImage = croppedBase
            }

            drawRedactionExport(
                shape.mode,
                in: localRect,
                displayRect: displayRect,
                croppedBase: compositedImage,
                style: displayStyle,
                scale: renderScale,
                context: context
            )
        }
    }

    private static func strokeAndFill(path: NSBezierPath, style: AnnotationStyle) {
        if style.fillColor.alpha > 0 {
            style.fillColor.nsColor.setFill()
            path.fill()
        }

        if style.lineWidth > 0 {
            style.strokeColor.nsColor.setStroke()
            path.lineWidth = style.lineWidth
            applyStrokeStyle(style, to: path)
            path.stroke()
        }
    }

    nonisolated private static func strokeAndFillExport(path: CGPath, style: AnnotationStyle, context: CGContext) {
        context.saveGState()

        if style.fillColor.alpha > 0 {
            context.setFillColor(style.fillColor.cgColor)
            context.addPath(path)
            context.fillPath()
        }

        if style.lineWidth > 0 {
            context.setStrokeColor(style.strokeColor.cgColor)
            context.setLineWidth(style.lineWidth)
            applyStrokeStyle(style, to: context)
            context.addPath(path)
            context.strokePath()
        }

        context.restoreGState()
    }

    private static func drawLine(from start: CGPoint, to end: CGPoint, style: AnnotationStyle) {
        style.strokeColor.nsColor.setStroke()

        let path = NSBezierPath()
        path.lineWidth = style.lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        applyStrokeStyle(style, to: path)
        path.move(to: start)
        path.line(to: end)
        path.stroke()
    }

    nonisolated private static func drawLineExport(from start: CGPoint, to end: CGPoint, style: AnnotationStyle, context: CGContext) {
        context.saveGState()
        context.setStrokeColor(style.strokeColor.cgColor)
        context.setLineWidth(style.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        applyStrokeStyle(style, to: context)
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
        context.restoreGState()
    }

    nonisolated static func arrowHeadLength(bodyLength: CGFloat, lineWidth: CGFloat, scale: CGFloat) -> CGFloat {
        guard bodyLength > 0 else {
            return max(lineWidth * 3, scaled(12, by: scale))
        }

        let baseLength = max(lineWidth * 3, scaled(12, by: scale))
        let proportionalLength = bodyLength * 0.18

        return min(max(baseLength, proportionalLength), bodyLength * 0.45)
    }

    nonisolated static func arrowHeadPoints(
        tip: CGPoint,
        tail: CGPoint,
        curvature: CGFloat,
        lineWidth: CGFloat,
        scale: CGFloat
    ) -> (left: CGPoint, right: CGPoint) {
        let geometry = arrowHeadGeometry(
            tip: tip,
            tail: tail,
            curvature: curvature,
            lineWidth: lineWidth,
            scale: scale
        )

        return (geometry.left, geometry.right)
    }

    nonisolated private static func arrowHeadGeometry(
        tip: CGPoint,
        tail: CGPoint,
        curvature: CGFloat,
        lineWidth: CGFloat,
        scale: CGFloat
    ) -> ArrowHeadGeometry {
        let tangentAngle = arrowEndpointTangentAngle(tip: tip, tail: tail, curvature: curvature)
        let bodyLength = hypot(tip.x - tail.x, tip.y - tail.y)
        let arrowLength = arrowHeadLength(bodyLength: bodyLength, lineWidth: lineWidth, scale: scale)
        let spread: CGFloat = .pi / 6

        return ArrowHeadGeometry(
            tip: tip,
            left: CGPoint(x: tip.x - cos(tangentAngle - spread) * arrowLength, y: tip.y - sin(tangentAngle - spread) * arrowLength),
            right: CGPoint(x: tip.x - cos(tangentAngle + spread) * arrowLength, y: tip.y - sin(tangentAngle + spread) * arrowLength)
        )
    }

    private static func arrowPreviewPath(for shape: ArrowShape) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: shape.start)
        if abs(shape.curvature) > 0.5 {
            path.curve(to: shape.end, controlPoint1: arrowControlPoint(for: shape), controlPoint2: arrowControlPoint(for: shape))
        } else {
            path.line(to: shape.end)
        }
        return path
    }

    nonisolated private static func arrowExportPath(for shape: ArrowShape) -> CGPath {
        let path = CGMutablePath()
        path.move(to: shape.start)
        if abs(shape.curvature) > 0.5 {
            let control = arrowControlPoint(for: shape)
            path.addCurve(to: shape.end, control1: control, control2: control)
        } else {
            path.addLine(to: shape.end)
        }
        return path
    }

    nonisolated private static func arrowControlPoint(for shape: ArrowShape) -> CGPoint {
        let midpoint = CGPoint(x: (shape.start.x + shape.end.x) / 2, y: (shape.start.y + shape.end.y) / 2)
        let dx = shape.end.x - shape.start.x
        let dy = shape.end.y - shape.start.y
        let length = max(hypot(dx, dy), 1)
        let normal = CGPoint(x: -dy / length, y: dx / length)
        return CGPoint(x: midpoint.x + normal.x * shape.curvature, y: midpoint.y + normal.y * shape.curvature)
    }

    nonisolated private static func arrowMidpoint(for shape: ArrowShape) -> CGPoint {
        if abs(shape.curvature) > 0.5 {
            let control = arrowControlPoint(for: shape)
            let t: CGFloat = 0.5
            let mt = 1 - t
            return CGPoint(
                x: mt * mt * shape.start.x + 2 * mt * t * control.x + t * t * shape.end.x,
                y: mt * mt * shape.start.y + 2 * mt * t * control.y + t * t * shape.end.y
            )
        }
        return CGPoint(x: (shape.start.x + shape.end.x) / 2, y: (shape.start.y + shape.end.y) / 2)
    }

    nonisolated private static func arrowLabelGeometry(for shape: ArrowShape) -> (rect: CGRect, rotationDegrees: CGFloat) {
        let fontSize = max(shape.labelFontSize, 8)
        let height = max(fontSize + 14, 28)
        let width = max(CGFloat(shape.label.count) * fontSize * 0.58 + 24, 64)
        let midpoint = arrowMidpoint(for: shape)
        let angle = atan2(shape.end.y - shape.start.y, shape.end.x - shape.start.x)
        let offset = height / 2 + 8
        let center: CGPoint
        let rotationDegrees: CGFloat

        switch shape.labelPlacement {
        case .horizontal:
            center = midpoint
            rotationDegrees = 0
        case .parallelAbove:
            let labelOffset = gscArrowLabelOffset(angle: angle, distance: offset, placeAbove: true, yAxisPointsDown: false)
            center = CGPoint(x: midpoint.x + labelOffset.x, y: midpoint.y + labelOffset.y)
            rotationDegrees = gscUprightTextRotationDegrees(for: angle * 180 / .pi)
        case .parallelBelow:
            let labelOffset = gscArrowLabelOffset(angle: angle, distance: offset, placeAbove: false, yAxisPointsDown: false)
            center = CGPoint(x: midpoint.x + labelOffset.x, y: midpoint.y + labelOffset.y)
            rotationDegrees = gscUprightTextRotationDegrees(for: angle * 180 / .pi)
        }

        return (
            CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height),
            rotationDegrees
        )
    }

    nonisolated private static func arrowEndpointTangentAngle(tip: CGPoint, tail: CGPoint, curvature: CGFloat) -> CGFloat {
        guard abs(curvature) > 0.5 else {
            return atan2(tip.y - tail.y, tip.x - tail.x)
        }

        let control = arrowControlPoint(for: ArrowShape(start: tail, end: tip, curvature: curvature))
        let tangent = CGPoint(x: tip.x - control.x, y: tip.y - control.y)

        guard hypot(tangent.x, tangent.y) > .leastNonzeroMagnitude else {
            return atan2(tip.y - tail.y, tip.x - tail.x)
        }

        return atan2(tangent.y, tangent.x)
    }

    private static func arrowHeadPreviewPath(shape: ArrowHeadShape, tip: CGPoint, tail: CGPoint, curvature: CGFloat, lineWidth: CGFloat, scale: CGFloat) -> NSBezierPath {
        let geometry = arrowHeadGeometry(tip: tip, tail: tail, curvature: curvature, lineWidth: lineWidth, scale: scale)
        let path = NSBezierPath()

        switch shape {
        case .open:
            path.move(to: tip)
            path.line(to: geometry.left)
            path.move(to: tip)
            path.line(to: geometry.right)
        case .triangle:
            path.move(to: tip)
            path.line(to: geometry.left)
            path.line(to: geometry.right)
            path.close()
        case .stealth:
            path.move(to: tip)
            path.line(to: geometry.left)
            path.line(to: geometry.stealthNotch)
            path.line(to: geometry.right)
            path.close()
        case .diamond:
            path.move(to: tip)
            path.line(to: geometry.left)
            path.line(to: geometry.diamondBack)
            path.line(to: geometry.right)
            path.close()
        }

        return path
    }

    nonisolated private static func arrowHeadExportPath(shape: ArrowHeadShape, tip: CGPoint, tail: CGPoint, curvature: CGFloat, lineWidth: CGFloat, scale: CGFloat) -> CGPath {
        let geometry = arrowHeadGeometry(tip: tip, tail: tail, curvature: curvature, lineWidth: lineWidth, scale: scale)
        let path = CGMutablePath()

        switch shape {
        case .open:
            path.move(to: tip)
            path.addLine(to: geometry.left)
            path.move(to: tip)
            path.addLine(to: geometry.right)
        case .triangle:
            path.move(to: tip)
            path.addLine(to: geometry.left)
            path.addLine(to: geometry.right)
            path.closeSubpath()
        case .stealth:
            path.move(to: tip)
            path.addLine(to: geometry.left)
            path.addLine(to: geometry.stealthNotch)
            path.addLine(to: geometry.right)
            path.closeSubpath()
        case .diamond:
            path.move(to: tip)
            path.addLine(to: geometry.left)
            path.addLine(to: geometry.diamondBack)
            path.addLine(to: geometry.right)
            path.closeSubpath()
        }

        return path
    }

    private static func drawArrowHeadPreview(shape: ArrowHeadShape, tip: CGPoint, tail: CGPoint, curvature: CGFloat, style: AnnotationStyle, scale: CGFloat) {
        let path = arrowHeadPreviewPath(shape: shape, tip: tip, tail: tail, curvature: curvature, lineWidth: style.lineWidth, scale: scale)
        style.strokeColor.nsColor.setStroke()
        style.strokeColor.nsColor.setFill()
        path.lineWidth = style.lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        applyStrokeStyle(style, to: path)

        if shape == .open {
            path.stroke()
        } else {
            path.fill()
            path.stroke()
        }
    }

    nonisolated private static func drawArrowHeadExport(shape: ArrowHeadShape, tip: CGPoint, tail: CGPoint, curvature: CGFloat, style: AnnotationStyle, scale: CGFloat, context: CGContext) {
        let path = arrowHeadExportPath(shape: shape, tip: tip, tail: tail, curvature: curvature, lineWidth: style.lineWidth, scale: scale)
        context.saveGState()
        context.setStrokeColor(style.strokeColor.cgColor)
        context.setFillColor(style.strokeColor.cgColor)
        context.setLineWidth(style.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        applyStrokeStyle(style, to: context)
        context.addPath(path)

        if shape == .open {
            context.strokePath()
        } else {
            context.drawPath(using: .fillStroke)
        }

        context.restoreGState()
    }

    private static func drawArrowLabel(_ shape: ArrowShape, style: AnnotationStyle, scale: CGFloat) {
        let labelGeometry = arrowLabelGeometry(for: shape)
        NSGraphicsContext.saveGraphicsState()
        rotatePreviewIfNeeded(degrees: labelGeometry.rotationDegrees, around: labelGeometry.rect.center)
        defer { NSGraphicsContext.restoreGraphicsState() }

        if shape.labelBoxColor.alpha > 0 {
            let background = NSBezierPath(
                roundedRect: labelGeometry.rect,
                xRadius: scaled(8, by: scale),
                yRadius: scaled(8, by: scale)
            )
            shape.labelBoxColor.nsColor.setFill()
            background.fill()
        }

        drawCenteredText(
            shape.label,
            in: labelGeometry.rect,
            font: NSFont.systemFont(ofSize: max(shape.labelFontSize, scaled(8, by: scale)), weight: .semibold),
            color: shape.labelTextColor.resolvedColor(for: style.strokeColor)
        )
    }

    nonisolated private static func drawArrowLabelExport(_ shape: ArrowShape, style: AnnotationStyle, scale: CGFloat, context: CGContext) {
        let labelGeometry = arrowLabelGeometry(for: shape)
        context.saveGState()
        rotateExportIfNeeded(degrees: labelGeometry.rotationDegrees, around: labelGeometry.rect.center, context: context)

        if shape.labelBoxColor.alpha > 0 {
            context.setFillColor(shape.labelBoxColor.cgColor)
            context.addPath(CGPath(
                roundedRect: labelGeometry.rect,
                cornerWidth: scaled(8, by: scale),
                cornerHeight: scaled(8, by: scale),
                transform: nil
            ))
            context.fillPath()
        }

        drawCenteredTextExport(
            shape.label,
            in: labelGeometry.rect,
            font: exportFont(size: max(shape.labelFontSize, 8), bold: true),
            color: shape.labelTextColor.resolvedColor(for: style.strokeColor).cgColor,
            context: context
        )
        context.restoreGState()
    }

    private static func drawArrow(_ shape: ArrowShape, style: AnnotationStyle, scale: CGFloat) {
        let path = arrowPreviewPath(for: shape)
        style.strokeColor.nsColor.setStroke()
        path.lineWidth = style.lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        applyStrokeStyle(style, to: path)
        path.stroke()
        drawArrowHeadPreview(shape: shape.headShape, tip: shape.end, tail: shape.start, curvature: shape.curvature, style: style, scale: scale)
        if shape.headStyle == .double {
            drawArrowHeadPreview(shape: shape.headShape, tip: shape.start, tail: shape.end, curvature: -shape.curvature, style: style, scale: scale)
        }

        if !shape.label.isEmpty {
            drawArrowLabel(shape, style: style, scale: scale)
        }
    }

    nonisolated private static func drawArrowExport(_ shape: ArrowShape, style: AnnotationStyle, scale: CGFloat, context: CGContext) {
        context.saveGState()
        context.setStrokeColor(style.strokeColor.cgColor)
        context.setLineWidth(style.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        applyStrokeStyle(style, to: context)
        context.addPath(arrowExportPath(for: shape))
        context.strokePath()
        context.restoreGState()
        drawArrowHeadExport(shape: shape.headShape, tip: shape.end, tail: shape.start, curvature: shape.curvature, style: style, scale: scale, context: context)
        if shape.headStyle == .double {
            drawArrowHeadExport(shape: shape.headShape, tip: shape.start, tail: shape.end, curvature: -shape.curvature, style: style, scale: scale, context: context)
        }

        if !shape.label.isEmpty {
            drawArrowLabelExport(shape, style: style, scale: scale, context: context)
        }
    }

    private static func drawFreehand(points: [CGPoint], style: AnnotationStyle) {
        guard let first = points.first else {
            return
        }

        style.strokeColor.nsColor.setStroke()
        let path = smoothedFreehandPath(
            simplifiedFreehandPoints(points, tolerance: style.freehandSimplification),
            smoothing: style.freehandSmoothing,
            fallbackStart: first
        )
        path.lineWidth = style.lineWidth
        path.lineCapStyle = NSBezierPath.LineCapStyle.round
        path.lineJoinStyle = NSBezierPath.LineJoinStyle.round
        applyStrokeStyle(style, to: path)
        path.stroke()
    }

    nonisolated private static func drawFreehandExport(points: [CGPoint], style: AnnotationStyle, context: CGContext) {
        let simplified = simplifiedFreehandPoints(points, tolerance: style.freehandSimplification)
        guard let first = simplified.first else {
            return
        }

        context.saveGState()
        context.setStrokeColor(style.strokeColor.cgColor)
        context.setLineWidth(style.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        applyStrokeStyle(style, to: context)
        context.move(to: first)
        addSmoothedFreehandSegments(simplified, smoothing: style.freehandSmoothing, to: context)

        context.strokePath()
        context.restoreGState()
    }

    private static func drawHighlighter(points: [CGPoint], style: AnnotationStyle) {
        guard let first = points.first else {
            return
        }

        let simplified = simplifiedFreehandPoints(points, tolerance: style.freehandSimplification)
        let path = smoothedFreehandPath(simplified, smoothing: style.freehandSmoothing, fallbackStart: first)
        NSGraphicsContext.current?.cgContext.saveGState()
        NSGraphicsContext.current?.cgContext.setBlendMode(.multiply)
        style.strokeColor.nsColor.setStroke()
        path.lineWidth = style.lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
        NSGraphicsContext.current?.cgContext.restoreGState()
    }

    nonisolated private static func drawHighlighterExport(points: [CGPoint], style: AnnotationStyle, context: CGContext) {
        let simplified = simplifiedFreehandPoints(points, tolerance: style.freehandSimplification)
        guard let first = simplified.first else {
            return
        }

        context.saveGState()
        context.setBlendMode(.multiply)
        context.setStrokeColor(style.strokeColor.cgColor)
        context.setLineWidth(style.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: first)
        addSmoothedFreehandSegments(simplified, smoothing: style.freehandSmoothing, to: context)
        context.strokePath()
        context.restoreGState()
    }

    private static func rectanglePreviewPath(in rect: CGRect, style: AnnotationStyle) -> NSBezierPath {
        let radius = min(style.cornerRadius, min(rect.width, rect.height) / 2)
        guard radius > 0 else {
            return NSBezierPath(rect: rect)
        }

        return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }

    nonisolated private static func rectangleExportPath(in rect: CGRect, style: AnnotationStyle) -> CGPath {
        let radius = min(style.cornerRadius, min(rect.width, rect.height) / 2)
        guard radius > 0 else {
            return CGPath(rect: rect, transform: nil)
        }

        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    private static func applyStrokeStyle(_ style: AnnotationStyle, to path: NSBezierPath) {
        let pattern = style.dashStyle.pattern.map { $0 * max(style.lineWidth / 4, 1) }
        guard !pattern.isEmpty else {
            path.setLineDash(nil, count: 0, phase: 0)
            return
        }

        var mutablePattern = pattern
        path.setLineDash(&mutablePattern, count: mutablePattern.count, phase: 0)
    }

    nonisolated private static func applyStrokeStyle(_ style: AnnotationStyle, to context: CGContext) {
        let pattern = style.dashStyle.pattern.map { $0 * max(style.lineWidth / 4, 1) }
        context.setLineDash(phase: 0, lengths: pattern)
    }

    nonisolated private static func simplifiedFreehandPoints(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2, tolerance > 0 else {
            return points
        }

        var simplified: [CGPoint] = [points[0]]
        for point in points.dropFirst().dropLast() {
            if hypot(point.x - simplified.last!.x, point.y - simplified.last!.y) >= tolerance {
                simplified.append(point)
            }
        }
        simplified.append(points[points.count - 1])
        return simplified
    }

    private static func smoothedFreehandPath(_ points: [CGPoint], smoothing: CGFloat, fallbackStart: CGPoint) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first else {
            path.move(to: fallbackStart)
            return path
        }

        path.move(to: first)
        let clampedSmoothing = max(0, min(smoothing, 1))
        guard points.count > 2, clampedSmoothing > 0.01 else {
            for point in points.dropFirst() {
                path.line(to: point)
            }
            return path
        }

        for index in 1..<(points.count - 1) {
            let targetMidpoint = CGPoint(
                x: (points[index].x + points[index + 1].x) / 2,
                y: (points[index].y + points[index + 1].y) / 2
            )
            let currentPoint = points[index]
            let midpoint = CGPoint(
                x: currentPoint.x + (targetMidpoint.x - currentPoint.x) * clampedSmoothing,
                y: currentPoint.y + (targetMidpoint.y - currentPoint.y) * clampedSmoothing
            )
            path.curve(to: midpoint, controlPoint1: currentPoint, controlPoint2: currentPoint)
        }
        if let last = points.last {
            path.line(to: last)
        }
        return path
    }

    nonisolated private static func addSmoothedFreehandSegments(_ points: [CGPoint], smoothing: CGFloat, to context: CGContext) {
        let clampedSmoothing = max(0, min(smoothing, 1))
        guard points.count > 2, clampedSmoothing > 0.01 else {
            for point in points.dropFirst() {
                context.addLine(to: point)
            }
            return
        }

        for index in 1..<(points.count - 1) {
            let targetMidpoint = CGPoint(
                x: (points[index].x + points[index + 1].x) / 2,
                y: (points[index].y + points[index + 1].y) / 2
            )
            let currentPoint = points[index]
            let midpoint = CGPoint(
                x: currentPoint.x + (targetMidpoint.x - currentPoint.x) * clampedSmoothing,
                y: currentPoint.y + (targetMidpoint.y - currentPoint.y) * clampedSmoothing
            )
            context.addCurve(to: midpoint, control1: currentPoint, control2: currentPoint)
        }
        if let last = points.last {
            context.addLine(to: last)
        }
    }

    private static func drawHighlight(in rect: CGRect, style: AnnotationStyle, scale: CGFloat) {
        let radius = scaled(10, by: scale)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        strokeAndFill(path: path, style: style)
    }

    nonisolated private static func drawHighlightExport(in rect: CGRect, style: AnnotationStyle, scale: CGFloat, context: CGContext) {
        let radius = scaled(10, by: scale)
        strokeAndFillExport(
            path: CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil),
            style: style,
            context: context
        )
    }

    private static func drawText(_ text: String, alignment: TextAlignmentMode, in rect: CGRect, style: AnnotationStyle, scale: CGFloat) {
        let alignedRect = rect.integral
        let cornerRadius = scaled(12, by: scale)
        let background = NSBezierPath(roundedRect: alignedRect, xRadius: cornerRadius, yRadius: cornerRadius)
        style.fillColor.nsColor.setFill()
        background.fill()

        let attributedText = previewAttributedText(
            text,
            font: NSFont.systemFont(ofSize: style.fontSize, weight: .semibold),
            color: style.strokeColor,
            alignment: alignment.nsTextAlignment,
            lineBreakMode: .byWordWrapping
        )

        attributedText.draw(in: alignedRect.insetBy(dx: scaled(12, by: scale), dy: scaled(10, by: scale)))
    }

    nonisolated private static func drawTextExport(_ text: String, alignment: TextAlignmentMode, in rect: CGRect, style: AnnotationStyle, scale: CGFloat, context: CGContext) {
        let cornerRadius = scaled(12, by: scale)
        let backgroundPath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        context.saveGState()
        context.setFillColor(style.fillColor.cgColor)
        context.addPath(backgroundPath)
        context.fillPath()
        context.restoreGState()

        drawAttributedTextExport(
            text,
            in: rect.insetBy(dx: scaled(12, by: scale), dy: scaled(10, by: scale)),
            font: exportFont(size: style.fontSize),
            color: style.strokeColor.cgColor,
            alignment: alignment.nsTextAlignment,
            context: context
        )
    }

    private static func drawCallout(_ shape: CalloutShape, in rect: CGRect, style: AnnotationStyle, scale: CGFloat) {
        let alignedRect = rect.integral
        let badgeDiameter = min(max(alignedRect.height - scaled(18, by: scale), scaled(32, by: scale)), scaled(48, by: scale))
        let badgeRect = CGRect(
            x: alignedRect.minX + scaled(10, by: scale),
            y: alignedRect.midY - badgeDiameter / 2,
            width: badgeDiameter,
            height: badgeDiameter
        )
        let bodyRect = CGRect(
            x: badgeRect.maxX - scaled(8, by: scale),
            y: alignedRect.minY,
            width: alignedRect.width - badgeDiameter + scaled(8, by: scale),
            height: alignedRect.height
        )

        let bodyCornerRadius = scaled(16, by: scale)
        let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: bodyCornerRadius, yRadius: bodyCornerRadius)
        if let leaderPoint = shape.leaderPoint {
            drawLine(from: leaderPoint, to: CGPoint(x: badgeRect.minX, y: badgeRect.midY), style: style)
        }

        if shape.style == .filled {
            style.fillColor.nsColor.setFill()
            bodyPath.fill()
        } else {
            let borderFill = style.fillColor.withAlpha(0.18)
            borderFill.nsColor.setFill()
            bodyPath.fill()
            style.strokeColor.nsColor.setStroke()
            bodyPath.lineWidth = max(style.lineWidth, 2)
            bodyPath.stroke()
        }

        let badgePath = NSBezierPath(ovalIn: badgeRect)
        if shape.style == .filled {
            style.fillColor.nsColor.setFill()
            badgePath.fill()
        } else {
            style.strokeColor.nsColor.setStroke()
            style.fillColor.withAlpha(0.12).nsColor.setFill()
            badgePath.lineWidth = max(style.lineWidth, 2)
            badgePath.fill()
            badgePath.stroke()
        }

        let numberText = previewAttributedText(
            "\(shape.number)",
            font: NSFont.monospacedDigitSystemFont(ofSize: max(style.fontSize - scaled(2, by: scale), scaled(16, by: scale)), weight: .bold),
            color: style.strokeColor
        )
        let numberSize = numberText.size()
        numberText.draw(
            at: CGPoint(x: badgeRect.midX - numberSize.width / 2, y: badgeRect.midY - numberSize.height / 2),
            )

        let bodyText = previewAttributedText(
            shape.text,
            font: NSFont.systemFont(ofSize: style.fontSize, weight: .semibold),
            color: style.strokeColor,
            alignment: shape.alignment.nsTextAlignment,
            lineBreakMode: .byWordWrapping
        )
        bodyText.draw(in: bodyRect.insetBy(dx: scaled(20, by: scale), dy: scaled(12, by: scale)))
    }

    nonisolated private static func drawCalloutExport(_ shape: CalloutShape, in rect: CGRect, style: AnnotationStyle, scale: CGFloat, context: CGContext) {
        let badgeDiameter = min(max(rect.height - scaled(18, by: scale), scaled(32, by: scale)), scaled(48, by: scale))
        let badgeRect = CGRect(
            x: rect.minX + scaled(10, by: scale),
            y: rect.midY - badgeDiameter / 2,
            width: badgeDiameter,
            height: badgeDiameter
        )
        let bodyRect = CGRect(
            x: badgeRect.maxX - scaled(8, by: scale),
            y: rect.minY,
            width: rect.width - badgeDiameter + scaled(8, by: scale),
            height: rect.height
        )

        if let leaderPoint = shape.leaderPoint {
            drawLineExport(from: leaderPoint, to: CGPoint(x: badgeRect.minX, y: badgeRect.midY), style: style, context: context)
        }

        context.saveGState()
        if shape.style == .filled {
            context.setFillColor(style.fillColor.cgColor)
            context.addPath(CGPath(roundedRect: bodyRect, cornerWidth: scaled(16, by: scale), cornerHeight: scaled(16, by: scale), transform: nil))
            context.fillPath()
            context.addPath(CGPath(ellipseIn: badgeRect, transform: nil))
            context.fillPath()
        } else {
            context.setFillColor(style.fillColor.withAlpha(0.18).cgColor)
            context.addPath(CGPath(roundedRect: bodyRect, cornerWidth: scaled(16, by: scale), cornerHeight: scaled(16, by: scale), transform: nil))
            context.fillPath()
            context.addPath(CGPath(ellipseIn: badgeRect, transform: nil))
            context.fillPath()
            context.setStrokeColor(style.strokeColor.cgColor)
            context.setLineWidth(max(style.lineWidth, 2))
            context.addPath(CGPath(roundedRect: bodyRect, cornerWidth: scaled(16, by: scale), cornerHeight: scaled(16, by: scale), transform: nil))
            context.strokePath()
            context.addPath(CGPath(ellipseIn: badgeRect, transform: nil))
            context.strokePath()
        }
        context.restoreGState()

        drawCenteredTextExport(
            "\(shape.number)",
            in: badgeRect,
            font: exportFont(size: max(style.fontSize - scaled(2, by: scale), scaled(16, by: scale)), bold: true),
            color: style.strokeColor.cgColor,
            context: context
        )

        drawAttributedTextExport(
            shape.text,
            in: bodyRect.insetBy(dx: scaled(20, by: scale), dy: scaled(12, by: scale)),
            font: exportFont(size: style.fontSize),
            color: style.strokeColor.cgColor,
            alignment: shape.alignment.nsTextAlignment,
            context: context
        )
    }

    private static func drawMeasurement(_ shape: MeasurementShape, from start: CGPoint, to end: CGPoint, style: AnnotationStyle, scale: CGFloat) {
        drawLine(from: start, to: end, style: style)

        let tickLength = scaled(8, by: scale)
        drawMeasurementTick(at: start, toward: end, length: tickLength, style: style)
        drawMeasurementTick(at: end, toward: start, length: tickLength, style: style)

        let label = "\(Int(shape.length.rounded())) px"
        let text = previewAttributedText(
            label,
            font: NSFont.monospacedDigitSystemFont(ofSize: max(style.fontSize, scaled(12, by: scale)), weight: .semibold),
            color: style.strokeColor
        )
        let size = text.size()
        let labelRect = CGRect(
            x: (start.x + end.x) / 2 - size.width / 2 - scaled(8, by: scale),
            y: (start.y + end.y) / 2 - size.height / 2 - scaled(5, by: scale),
            width: size.width + scaled(16, by: scale),
            height: size.height + scaled(10, by: scale)
        )
        let background = NSBezierPath(roundedRect: labelRect, xRadius: scaled(8, by: scale), yRadius: scaled(8, by: scale))
        style.fillColor.nsColor.setFill()
        background.fill()
        text.draw(at: CGPoint(x: labelRect.minX + scaled(8, by: scale), y: labelRect.minY + scaled(5, by: scale)))
    }

    nonisolated private static func drawMeasurementExport(_ shape: MeasurementShape, from start: CGPoint, to end: CGPoint, style: AnnotationStyle, scale: CGFloat, context: CGContext) {
        drawLineExport(from: start, to: end, style: style, context: context)

        let tickLength = scaled(8, by: scale)
        drawMeasurementTickExport(at: start, toward: end, length: tickLength, style: style, context: context)
        drawMeasurementTickExport(at: end, toward: start, length: tickLength, style: style, context: context)

        let label = "\(Int(shape.length.rounded())) px"
        let labelRect = CGRect(
            x: (start.x + end.x) / 2 - 46,
            y: (start.y + end.y) / 2 - 13,
            width: 92,
            height: 26
        )
        context.saveGState()
        context.setFillColor(style.fillColor.cgColor)
        context.addPath(CGPath(roundedRect: labelRect, cornerWidth: 8, cornerHeight: 8, transform: nil))
        context.fillPath()
        context.restoreGState()
        drawCenteredTextExport(label, in: labelRect, font: exportFont(size: max(style.fontSize, 12), bold: true), color: style.strokeColor.cgColor, context: context)
    }

    private static func drawMeasurementTick(at point: CGPoint, toward other: CGPoint, length: CGFloat, style: AnnotationStyle) {
        let angle = atan2(other.y - point.y, other.x - point.x) + .pi / 2
        let delta = CGPoint(x: cos(angle) * length / 2, y: sin(angle) * length / 2)
        drawLine(
            from: CGPoint(x: point.x - delta.x, y: point.y - delta.y),
            to: CGPoint(x: point.x + delta.x, y: point.y + delta.y),
            style: style
        )
    }

    nonisolated private static func drawMeasurementTickExport(at point: CGPoint, toward other: CGPoint, length: CGFloat, style: AnnotationStyle, context: CGContext) {
        let angle = atan2(other.y - point.y, other.x - point.x) + .pi / 2
        let delta = CGPoint(x: cos(angle) * length / 2, y: sin(angle) * length / 2)
        drawLineExport(
            from: CGPoint(x: point.x - delta.x, y: point.y - delta.y),
            to: CGPoint(x: point.x + delta.x, y: point.y + delta.y),
            style: style,
            context: context
        )
    }

    private static func drawSpotlight(
        _ shape: SpotlightShape,
        in rect: CGRect,
        canvasRect: CGRect,
        style: AnnotationStyle,
        scale: CGFloat,
        rotationDegrees: CGFloat,
        rotationCenter: CGPoint
    ) {
        let path = NSBezierPath(rect: canvasRect)
        path.append(
            spotlightPreviewPath(
                for: shape,
                rect: rect,
                scale: scale,
                rotationDegrees: rotationDegrees,
                rotationCenter: rotationCenter
            )
        )
        path.windingRule = .evenOdd
        style.fillColor.nsColor.withAlphaComponent(max(min(style.effectRadius / 100, 0.9), 0.05)).setFill()
        path.fill()

        let outline = spotlightPreviewPath(
            for: shape,
            rect: rect,
            scale: scale,
            rotationDegrees: rotationDegrees,
            rotationCenter: rotationCenter
        )
        outline.lineWidth = max(style.lineWidth, 1)
        style.strokeColor.nsColor.setStroke()
        outline.stroke()
    }

    nonisolated private static func drawSpotlightExport(
        _ shape: SpotlightShape,
        in rect: CGRect,
        canvasRect: CGRect,
        style: AnnotationStyle,
        scale: CGFloat,
        rotationDegrees: CGFloat,
        rotationCenter: CGPoint,
        context: CGContext
    ) {
        context.saveGState()
        context.setFillColor(style.fillColor.withAlpha(max(min(style.effectRadius / 100, 0.9), 0.05)).cgColor)
        context.addRect(canvasRect)
        context.addPath(
            spotlightExportPath(
                for: shape,
                rect: rect,
                scale: scale,
                rotationDegrees: rotationDegrees,
                rotationCenter: rotationCenter
            )
        )
        context.drawPath(using: .eoFill)

        context.setStrokeColor(style.strokeColor.cgColor)
        context.setLineWidth(max(style.lineWidth, 1))
        context.addPath(
            spotlightExportPath(
                for: shape,
                rect: rect,
                scale: scale,
                rotationDegrees: rotationDegrees,
                rotationCenter: rotationCenter
            )
        )
        context.strokePath()
        context.restoreGState()
    }

    private static func spotlightPreviewPath(
        for shape: SpotlightShape,
        rect: CGRect,
        scale: CGFloat,
        rotationDegrees: CGFloat,
        rotationCenter: CGPoint
    ) -> NSBezierPath {
        let path = shape.isEllipse
            ? NSBezierPath(ovalIn: rect)
            : NSBezierPath(roundedRect: rect, xRadius: scaled(10, by: scale), yRadius: scaled(10, by: scale))
        guard rotationDegrees != 0 else {
            return path
        }

        let transform = NSAffineTransform()
        transform.translateX(by: rotationCenter.x, yBy: rotationCenter.y)
        transform.rotate(byDegrees: rotationDegrees)
        transform.translateX(by: -rotationCenter.x, yBy: -rotationCenter.y)
        path.transform(using: transform as AffineTransform)
        return path
    }

    nonisolated private static func spotlightExportPath(
        for shape: SpotlightShape,
        rect: CGRect,
        scale: CGFloat,
        rotationDegrees: CGFloat,
        rotationCenter: CGPoint
    ) -> CGPath {
        let basePath = shape.isEllipse
            ? CGPath(ellipseIn: rect, transform: nil)
            : CGPath(
                roundedRect: rect,
                cornerWidth: scaled(10, by: scale),
                cornerHeight: scaled(10, by: scale),
                transform: nil
            )
        guard rotationDegrees != 0 else {
            return basePath
        }

        var transform = CGAffineTransform.identity
        transform = transform.translatedBy(x: rotationCenter.x, y: rotationCenter.y)
        transform = transform.rotated(by: rotationDegrees * .pi / 180)
        transform = transform.translatedBy(x: -rotationCenter.x, y: -rotationCenter.y)
        return basePath.copy(using: &transform) ?? basePath
    }

    private static func drawImageOverlay(_ shape: ImageOverlayShape, in rect: CGRect) {
        NSImage(cgImage: shape.image, size: rect.size).draw(
            in: rect,
            from: .zero,
            operation: .sourceOver,
            fraction: shape.opacity,
            respectFlipped: true,
            hints: nil
        )
    }

    nonisolated private static func drawImageOverlayExport(_ shape: ImageOverlayShape, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.setAlpha(shape.opacity)
        context.translateBy(x: 0, y: rect.minY * 2 + rect.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(shape.image, in: rect)
        context.restoreGState()
    }

    private static func drawRedaction(_ mode: RedactionMode, in localRect: CGRect, displayRect: CGRect, croppedBase: CGImage, style: AnnotationStyle, scale: CGFloat) {
        switch mode {
        case .blur, .pixelate:
            drawProcessedRedactionPreview(mode, in: localRect, displayRect: displayRect, croppedBase: croppedBase, style: style, scale: scale)
        case .solid:
            drawSolidRedaction(in: displayRect, style: style, scale: scale)
        }
    }

    nonisolated private static func drawRedactionExport(_ mode: RedactionMode, in localRect: CGRect, displayRect: CGRect, croppedBase: CGImage, style: AnnotationStyle, scale: CGFloat, context: CGContext) {
        switch mode {
        case .blur, .pixelate:
            drawProcessedRedactionExport(mode, in: localRect, displayRect: displayRect, croppedBase: croppedBase, style: style, scale: scale, context: context)
        case .solid:
            drawSolidRedactionExport(in: displayRect, style: style, scale: scale, context: context)
        }
    }

    private static func drawProcessedRedactionPreview(_ mode: RedactionMode, in localRect: CGRect, displayRect: CGRect, croppedBase: CGImage, style: AnnotationStyle, scale: CGFloat) {
        guard let focused = processedRedactionImage(for: mode, in: localRect, sourceImage: croppedBase, effectRadius: style.effectRadius) else {
            return
        }

        drawRedactionPreviewImage(focused, sourceSize: localRect.size, in: displayRect, mode: mode)
        drawRedactionPreviewOutline(for: mode, in: displayRect, style: style, scale: scale)
    }

    nonisolated private static func drawProcessedRedactionExport(_ mode: RedactionMode, in localRect: CGRect, displayRect: CGRect, croppedBase: CGImage, style: AnnotationStyle, scale: CGFloat, context: CGContext) {
        guard let focused = processedRedactionImage(for: mode, in: localRect, sourceImage: croppedBase, effectRadius: style.effectRadius) else {
            return
        }

        drawRedactionExportImage(focused, in: displayRect, mode: mode, context: context)
        drawRedactionExportOutline(for: mode, in: displayRect, style: style, scale: scale, context: context)
    }

    private static func drawSolidRedaction(in displayRect: CGRect, style: AnnotationStyle, scale: CGFloat) {
        let cornerRadius = redactionCornerRadius(scale: scale)
        let path = NSBezierPath(roundedRect: displayRect, xRadius: cornerRadius, yRadius: cornerRadius)
        style.fillColor.nsColor.setFill()
        path.fill()
    }

    nonisolated private static func drawSolidRedactionExport(in displayRect: CGRect, style: AnnotationStyle, scale: CGFloat, context: CGContext) {
        context.saveGState()
        context.setFillColor(style.fillColor.cgColor)
        context.addPath(CGPath(roundedRect: displayRect, cornerWidth: redactionCornerRadius(scale: scale), cornerHeight: redactionCornerRadius(scale: scale), transform: nil))
        context.fillPath()
        context.restoreGState()
    }

    nonisolated private static func processedRedactionImage(for mode: RedactionMode, in localRect: CGRect, sourceImage: CGImage, effectRadius: CGFloat) -> CGImage? {
        let key = processedRedactionCacheKey(mode: mode, localRect: localRect, sourceImage: sourceImage, effectRadius: effectRadius)

        if let cached = processedRedactionCache.image(forKey: key) {
            return cached
        }

        let image: CGImage?

        switch mode {
        case .blur:
            image = makeBlurredRedactionImage(in: localRect, sourceImage: sourceImage, radius: effectRadius)
        case .pixelate:
            image = makePixelatedRedactionImage(in: localRect, sourceImage: sourceImage, scale: effectRadius)
        case .solid:
            return nil
        }

        if let image {
            processedRedactionCache.setImage(image, forKey: key, cost: cacheCost(for: image))
        }

        return image
    }

    private static func drawRedactionPreviewImage(_ image: CGImage, sourceSize: CGSize, in displayRect: CGRect, mode: RedactionMode) {
        let drawImage = {
            NSImage(cgImage: image, size: sourceSize).draw(
                in: displayRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
        }

        if mode == .pixelate {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.imageInterpolation = .none
            drawImage()
            NSGraphicsContext.restoreGraphicsState()
        } else {
            drawImage()
        }
    }

    nonisolated private static func drawRedactionExportImage(_ image: CGImage, in displayRect: CGRect, mode: RedactionMode, context: CGContext) {
        context.saveGState()
        if mode == .pixelate {
            context.interpolationQuality = .none
        }
        context.translateBy(x: 0, y: displayRect.minY * 2 + displayRect.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: displayRect)
        context.restoreGState()
    }

    private static func drawRedactionPreviewOutline(for mode: RedactionMode, in displayRect: CGRect, style: AnnotationStyle, scale: CGFloat) {
        let outline = NSBezierPath(
            roundedRect: displayRect,
            xRadius: redactionCornerRadius(scale: scale),
            yRadius: redactionCornerRadius(scale: scale)
        )
        style.strokeColor.nsColor.setStroke()
        outline.lineWidth = style.lineWidth
        let dashPattern = redactionDashPattern(for: mode, scale: scale)
        outline.setLineDash(dashPattern, count: dashPattern.count, phase: 0)
        outline.stroke()
    }

    nonisolated private static func drawRedactionExportOutline(for mode: RedactionMode, in displayRect: CGRect, style: AnnotationStyle, scale: CGFloat, context: CGContext) {
        context.saveGState()
        context.setStrokeColor(style.strokeColor.cgColor)
        context.setLineWidth(style.lineWidth)
        context.setLineDash(phase: 0, lengths: redactionDashPattern(for: mode, scale: scale))
        context.addPath(
            CGPath(
                roundedRect: displayRect,
                cornerWidth: redactionCornerRadius(scale: scale),
                cornerHeight: redactionCornerRadius(scale: scale),
                transform: nil
            )
        )
        context.strokePath()
        context.restoreGState()
    }

    nonisolated private static func redactionDashPattern(for mode: RedactionMode, scale: CGFloat) -> [CGFloat] {
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

    nonisolated private static func redactionCornerRadius(scale: CGFloat) -> CGFloat {
        scaled(8, by: scale)
    }

    nonisolated private static func makeBlurredRedactionImage(in localRect: CGRect, sourceImage: CGImage, radius: CGFloat) -> CGImage? {
        makeProcessedRedactionImage(in: localRect, sourceImage: sourceImage, sampleInset: max(radius * 2, 12)) { ciImage in
            guard let filter = CIFilter(name: "CIGaussianBlur") else {
                return nil
            }

            filter.setValue(ciImage.clampedToExtent(), forKey: kCIInputImageKey)
            filter.setValue(radius, forKey: kCIInputRadiusKey)
            return filter.outputImage?.cropped(to: ciImage.extent)
        }
    }

    nonisolated private static func makePixelatedRedactionImage(in localRect: CGRect, sourceImage: CGImage, scale: CGFloat) -> CGImage? {
        makeProcessedRedactionImage(in: localRect, sourceImage: sourceImage, sampleInset: max(scale, 12)) { ciImage in
            guard let filter = CIFilter(name: "CIPixellate") else {
                return nil
            }

            filter.setValue(ciImage, forKey: kCIInputImageKey)
            filter.setValue(scale, forKey: kCIInputScaleKey)
            filter.setValue(CIVector(x: ciImage.extent.midX, y: ciImage.extent.midY), forKey: kCIInputCenterKey)
            return filter.outputImage?.cropped(to: ciImage.extent)
        }
    }

#if DEBUG
    nonisolated static func debugMakeBlurredRedactionImage(in localRect: CGRect, sourceImage: CGImage, radius: CGFloat) -> CGImage? {
        makeBlurredRedactionImage(in: localRect, sourceImage: sourceImage, radius: radius)
    }
#endif

    nonisolated private static func makeProcessedRedactionImage(
        in localRect: CGRect,
        sourceImage: CGImage,
        sampleInset: CGFloat,
        processor: (CIImage) -> CIImage?
    ) -> CGImage? {
        let expandedRect = localRect.insetBy(dx: -sampleInset, dy: -sampleInset).intersection(
            CGRect(origin: .zero, size: CGSize(width: sourceImage.width, height: sourceImage.height))
        )

        guard
            let subimage = sourceImage.gscCropped(topLeftPixelRect: expandedRect),
            let outputImage = processor(CIImage(cgImage: subimage)),
            let processedImage = ciContext.createCGImage(outputImage, from: outputImage.extent)
        else {
            return nil
        }

        return processedImage.gscCropped(
            topLeftPixelRect: localRect.offsetBy(dx: -expandedRect.minX, dy: -expandedRect.minY)
        )
    }

    nonisolated private static func croppedBaseImage(for baseImage: CGImage, crop: CGRect) -> CGImage? {
        let key = croppedImageCacheKey(baseImage: baseImage, crop: crop)

        if let cached = croppedImageCache.image(forKey: key) {
            return cached
        }

        guard let image = baseImage.gscCropped(topLeftPixelRect: crop) else {
            return nil
        }

        croppedImageCache.setImage(image, forKey: key, cost: cacheCost(for: image))
        return image
    }

    nonisolated private static func croppedImageCacheKey(baseImage: CGImage, crop: CGRect) -> NSString {
        "\(ObjectIdentifier(baseImage as AnyObject))|\(cacheComponent(crop.minX))|\(cacheComponent(crop.minY))|\(cacheComponent(crop.width))|\(cacheComponent(crop.height))" as NSString
    }

    nonisolated private static func processedRedactionCacheKey(
        mode: RedactionMode,
        localRect: CGRect,
        sourceImage: CGImage,
        effectRadius: CGFloat
    ) -> NSString {
        "\(ObjectIdentifier(sourceImage as AnyObject))|\(mode.rawValue)|\(cacheComponent(localRect.minX))|\(cacheComponent(localRect.minY))|\(cacheComponent(localRect.width))|\(cacheComponent(localRect.height))|\(cacheComponent(effectRadius))" as NSString
    }

    nonisolated private static func cacheCost(for image: CGImage) -> Int {
        image.bytesPerRow * image.height
    }

    nonisolated private static func cacheComponent(_ value: CGFloat) -> String {
        String(value.native.bitPattern)
    }

    nonisolated private static func previewAttributedText(
        _ text: String,
        font: NSFont,
        color: RGBAColor,
        alignment: NSTextAlignment? = nil,
        lineBreakMode: NSLineBreakMode? = nil
    ) -> NSAttributedString {
        let key = previewAttributedTextCacheKey(
            text: text,
            font: font,
            color: color,
            alignment: alignment,
            lineBreakMode: lineBreakMode
        )

        if let cached = previewAttributedTextCache.attributedText(forKey: key) {
            return cached
        }

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(cgColor: color.cgColor) ?? .clear
        ]

        if let alignment, let lineBreakMode {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = alignment
            paragraphStyle.lineBreakMode = lineBreakMode
            attributes[.paragraphStyle] = paragraphStyle
        }

        let attributedText = NSAttributedString(string: text, attributes: attributes)
        previewAttributedTextCache.setAttributedText(
            attributedText,
            forKey: key,
            cost: max(text.utf16.count * MemoryLayout<UInt16>.size, 1) + 256
        )
        return attributedText
    }

    private static func drawCenteredText(_ text: String, in rect: CGRect, font: NSFont, color: RGBAColor) {
        let attributed = previewAttributedText(text, font: font, color: color)
        let size = attributed.size()
        attributed.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    nonisolated private static func previewAttributedTextCacheKey(
        text: String,
        font: NSFont,
        color: RGBAColor,
        alignment: NSTextAlignment?,
        lineBreakMode: NSLineBreakMode?
    ) -> NSString {
        [
            text,
            font.fontName,
            cacheComponent(font.pointSize),
            colorCacheKey(color),
            alignment.map { String($0.rawValue) } ?? "nil",
            lineBreakMode.map { String($0.rawValue) } ?? "nil"
        ].joined(separator: "|") as NSString
    }

    nonisolated private static func colorCacheKey(_ color: RGBAColor) -> String {
        [
            cacheComponent(color.red),
            cacheComponent(color.green),
            cacheComponent(color.blue),
            cacheComponent(color.alpha)
        ].joined(separator: "|")
    }

    private static func rotatePreviewIfNeeded(degrees: CGFloat, around center: CGPoint) {
        guard degrees != 0 else {
            return
        }

        let transform = NSAffineTransform()
        transform.translateX(by: center.x, yBy: center.y)
        transform.rotate(byDegrees: degrees)
        transform.translateX(by: -center.x, yBy: -center.y)
        transform.concat()
    }

    nonisolated private static func rotateExportIfNeeded(degrees: CGFloat, around center: CGPoint, context: CGContext) {
        guard degrees != 0 else {
            return
        }

        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: degrees * .pi / 180)
        context.translateBy(x: -center.x, y: -center.y)
    }

    nonisolated private static func scaled(_ value: CGFloat, by scale: CGFloat) -> CGFloat {
        value * scale
    }

    nonisolated private static func previewProjection(for baseImage: CGImage, canvasRect: CGRect) -> DocumentProjection? {
        let documentRect = CGRect(origin: .zero, size: CGSize(width: baseImage.width, height: baseImage.height))
        guard documentRect.width > 0, documentRect.height > 0,
              canvasRect.width > 0, canvasRect.height > 0 else {
            return nil
        }

        return DocumentProjection(sourceDocumentRect: documentRect, destinationBounds: canvasRect)
    }

    nonisolated private static func renderProjection(for crop: CGRect) -> DocumentProjection {
        DocumentProjection(sourceDocumentRect: crop, destinationBounds: CGRect(origin: .zero, size: crop.size))
    }

    nonisolated private static func displayScale(for projection: DocumentProjection) -> CGFloat {
        let scaleX = projection.destinationBounds.width / projection.sourceDocumentRect.width
        let scaleY = projection.destinationBounds.height / projection.sourceDocumentRect.height
        return max(min(scaleX, scaleY), .leastNonzeroMagnitude)
    }

    nonisolated private static func mapPoint(_ point: CGPoint, using projection: DocumentProjection) -> CGPoint {
        projection.destinationPoint(fromDocumentPoint: point)
    }

    nonisolated private static func mapRect(_ rect: CGRect, using projection: DocumentProjection) -> CGRect {
        projection.destinationRect(fromDocumentRect: rect)
    }

    nonisolated private static func exportPoint(for point: CGPoint, using projection: DocumentProjection) -> CGPoint {
        projection.contextPoint(fromDocumentPoint: point)
    }

    nonisolated private static func exportRect(for rect: CGRect, using projection: DocumentProjection) -> CGRect {
        projection.contextRect(fromDocumentRect: rect)
    }

    nonisolated private static func exportFont(size: CGFloat, bold: Bool = false) -> CTFont {
        let key = exportFontCacheKey(size: size, bold: bold)
        exportCacheLock.lock()
        defer { exportCacheLock.unlock() }

        if let cached = exportFontCache[key] {
            return cached
        }

        let fontName = bold ? "Helvetica-Bold" : "Helvetica"
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        exportFontCache[key] = font
        return font
    }

    nonisolated private static func exportFontCacheKey(size: CGFloat, bold: Bool) -> NSString {
        let fontName = bold ? "Helvetica-Bold" : "Helvetica"
        return "\(fontName)|\(cacheComponent(size))" as NSString
    }

    nonisolated private static func exportParagraphStyle(for alignment: NSTextAlignment) -> NSParagraphStyle {
        let key = "\(alignment.rawValue)" as NSString
        exportCacheLock.lock()
        defer { exportCacheLock.unlock() }

        if let cached = exportParagraphStyleCache[key] {
            return cached
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment
        paragraphStyle.lineBreakMode = .byWordWrapping
        exportParagraphStyleCache[key] = paragraphStyle
        return paragraphStyle
    }

    nonisolated private static func drawAttributedTextExport(_ text: String, in rect: CGRect, font: CTFont, color: CGColor, alignment: NSTextAlignment, context: CGContext) {
        guard !text.isEmpty, rect.width > 0, rect.height > 0 else {
            return
        }

        let paragraphStyle = exportParagraphStyle(for: alignment)

        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            .paragraphStyle: paragraphStyle
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, attributed.length), path, nil)

        context.saveGState()
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    nonisolated private static func drawCenteredTextExport(_ text: String, in rect: CGRect, font: CTFont, color: CGColor, context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let origin = CGPoint(
            x: rect.midX - bounds.width / 2 - bounds.minX,
            y: rect.midY - bounds.height / 2 - bounds.minY
        )

        context.saveGState()
        context.textPosition = origin
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

nonisolated private final class CachedCGImage {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}

nonisolated private final class CachedAttributedText {
    let attributedText: NSAttributedString

    init(_ attributedText: NSAttributedString) {
        self.attributedText = attributedText
    }
}

nonisolated private final class RenderImageCache: @unchecked Sendable {
    private let cache = NSCache<NSString, CachedCGImage>()

    init(totalCostLimit: Int) {
        cache.totalCostLimit = totalCostLimit
    }

    func image(forKey key: NSString) -> CGImage? {
        cache.object(forKey: key)?.image
    }

    func setImage(_ image: CGImage, forKey key: NSString, cost: Int) {
        cache.setObject(CachedCGImage(image), forKey: key, cost: cost)
    }
}

nonisolated private final class RenderAttributedTextCache: @unchecked Sendable {
    private let cache = NSCache<NSString, CachedAttributedText>()

    init(totalCostLimit: Int) {
        cache.totalCostLimit = totalCostLimit
    }

    func attributedText(forKey key: NSString) -> NSAttributedString? {
        cache.object(forKey: key)?.attributedText
    }

    func setAttributedText(_ attributedText: NSAttributedString, forKey key: NSString, cost: Int) {
        cache.setObject(CachedAttributedText(attributedText), forKey: key, cost: cost)
    }
}
