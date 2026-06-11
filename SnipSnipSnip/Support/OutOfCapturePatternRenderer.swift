import AppKit

enum OutOfCapturePatternRenderer {
    static func draw(
        bounds: CGRect,
        excluding imageRect: CGRect,
        settings: EditorOutOfCapturePatternSettings,
        appearance: NSAppearance
    ) {
        guard settings.isEnabled else {
            return
        }

        for rect in outOfCaptureRects(in: bounds, excluding: imageRect) where rect.width > 0 && rect.height > 0 {
            drawPattern(in: rect, bounds: bounds, settings: settings, appearance: appearance)
        }
    }

    private static func outOfCaptureRects(in bounds: CGRect, excluding imageRect: CGRect) -> [CGRect] {
        let clippedImageRect = imageRect.intersection(bounds)

        guard !clippedImageRect.isNull else {
            return [bounds]
        }

        return [
            CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(clippedImageRect.minY - bounds.minY, 0)),
            CGRect(x: bounds.minX, y: clippedImageRect.maxY, width: bounds.width, height: max(bounds.maxY - clippedImageRect.maxY, 0)),
            CGRect(x: bounds.minX, y: clippedImageRect.minY, width: max(clippedImageRect.minX - bounds.minX, 0), height: clippedImageRect.height),
            CGRect(x: clippedImageRect.maxX, y: clippedImageRect.minY, width: max(bounds.maxX - clippedImageRect.maxX, 0), height: clippedImageRect.height)
        ]
    }

    private static func drawPattern(
        in rect: CGRect,
        bounds: CGRect,
        settings: EditorOutOfCapturePatternSettings,
        appearance: NSAppearance
    ) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        defer {
            NSGraphicsContext.restoreGraphicsState()
        }

        let palette = palette(for: appearance)
        palette.background.setFill()
        rect.fill()

        let spacing = settings.spacing
        let origin = CGPoint(
            x: floor(bounds.minX / spacing) * spacing,
            y: floor(bounds.minY / spacing) * spacing
        )
        let expandedBounds = bounds.insetBy(dx: -spacing * 4, dy: -spacing * 4)

        let path = NSBezierPath()
        path.lineWidth = 1
        path.lineCapStyle = .round

        let minRisingIndex = Int(floor(((expandedBounds.minX - origin.x) - (expandedBounds.maxY - origin.y)) / spacing))
        let maxRisingIndex = Int(ceil(((expandedBounds.maxX - origin.x) - (expandedBounds.minY - origin.y)) / spacing))
        for index in minRisingIndex...maxRisingIndex {
            let difference = CGFloat(index) * spacing
            path.move(to: CGPoint(x: origin.x + difference + (expandedBounds.minY - origin.y), y: expandedBounds.minY))
            path.line(to: CGPoint(x: origin.x + difference + (expandedBounds.maxY - origin.y), y: expandedBounds.maxY))
        }

        let minFallingIndex = Int(floor(((expandedBounds.minX - origin.x) + (expandedBounds.minY - origin.y)) / spacing))
        let maxFallingIndex = Int(ceil(((expandedBounds.maxX - origin.x) + (expandedBounds.maxY - origin.y)) / spacing))
        for index in minFallingIndex...maxFallingIndex {
            let sum = CGFloat(index) * spacing
            path.move(to: CGPoint(x: origin.x + sum - (expandedBounds.minY - origin.y), y: expandedBounds.minY))
            path.line(to: CGPoint(x: origin.x + sum - (expandedBounds.maxY - origin.y), y: expandedBounds.maxY))
        }

        palette.line.withAlphaComponent(settings.lineOpacity).setStroke()
        path.stroke()

        let dotRadius = settings.dotDiameter / 2
        palette.dot.withAlphaComponent(settings.dotOpacity).setFill()

        let minDotRow = Int(floor((expandedBounds.minY - origin.y) / spacing))
        let maxDotRow = Int(ceil((expandedBounds.maxY - origin.y) / spacing))
        let minDotColumn = Int(floor((expandedBounds.minX - origin.x) / spacing))
        let maxDotColumn = Int(ceil((expandedBounds.maxX - origin.x) / spacing))

        for row in minDotRow...maxDotRow {
            for column in minDotColumn...maxDotColumn where (row + column).isMultiple(of: 2) {
                let dotPoint = CGPoint(
                    x: origin.x + CGFloat(column) * spacing,
                    y: origin.y + CGFloat(row) * spacing
                )

                guard rect.insetBy(dx: -dotRadius, dy: -dotRadius).contains(dotPoint) else {
                    continue
                }

                let dotRect = CGRect(
                    x: dotPoint.x - dotRadius,
                    y: dotPoint.y - dotRadius,
                    width: settings.dotDiameter,
                    height: settings.dotDiameter
                )
                NSBezierPath(ovalIn: dotRect).fill()
            }
        }
    }

    private static func palette(for appearance: NSAppearance) -> (background: NSColor, line: NSColor, dot: NSColor) {
        let matchedAppearance = appearance.bestMatch(from: [.darkAqua, .aqua])
        let isDark = matchedAppearance == .darkAqua

        if isDark {
            return (
                background: NSColor(calibratedWhite: 0.09, alpha: 1),
                line: NSColor(calibratedRed: 0.62, green: 0.72, blue: 0.98, alpha: 1),
                dot: NSColor(calibratedRed: 0.70, green: 0.80, blue: 1.00, alpha: 1)
            )
        }

        return (
            background: NSColor(calibratedWhite: 0.98, alpha: 1),
            line: NSColor(calibratedRed: 0.20, green: 0.33, blue: 0.61, alpha: 1),
            dot: NSColor(calibratedRed: 0.16, green: 0.28, blue: 0.58, alpha: 1)
        )
    }
}
