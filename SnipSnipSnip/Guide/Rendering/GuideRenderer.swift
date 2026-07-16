import AppKit
import CoreGraphics
import CoreImage
import CoreText
import Foundation

nonisolated enum GuideRenderer {
    static func renderStepCard(
        step: GuideStep,
        image: CGImage,
        theme: GuideTheme,
        cardWidth: Int = 1440,
        advancedEdit: EditableScreenshotDocument? = nil,
        logo: CGImage? = nil
    ) -> CGImage? {
        let renderedImage = advancedEdit.flatMap {
            ScreenshotPresentationRenderer.render(baseImage: image, snapshot: $0.session.currentSnapshot)
        } ?? image
        let margin: CGFloat = 72
        let caption = step.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = step.note.trimmingCharacters(in: .whitespacesAndNewlines)
        // The card is the shared visual representation for the editor preview
        // and every still-image export. Reserve enough space for both pieces of
        // step copy so notes do not silently disappear outside document exports.
        let captionHeight = textHeight(
            "\(step.sequence). \(caption)",
            font: CTFontCreateWithName("Helvetica-Bold" as CFString, 30, nil),
            width: CGFloat(cardWidth) - margin * 2
        )
        let noteHeight = note.isEmpty ? 0 : textHeight(
            "Note: \(note)",
            font: CTFontCreateWithName("Helvetica-Oblique" as CFString, 22, nil),
            width: CGFloat(cardWidth) - margin * 2
        )
        let headerHeight = max(150, captionHeight + (note.isEmpty ? 0 : noteHeight + 16) + 44)
        let scale = min((CGFloat(cardWidth) - margin * 2) / CGFloat(renderedImage.width), 1)
        let imageSize = CGSize(width: CGFloat(renderedImage.width) * scale, height: CGFloat(renderedImage.height) * scale)
        let size = CGSize(width: CGFloat(cardWidth), height: imageSize.height + margin * 2 + headerHeight)
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(color(theme.backgroundColorHex, fallback: CGColor(gray: 0.96, alpha: 1)))
        context.fill(CGRect(origin: .zero, size: size))
        let imageRect = CGRect(x: margin, y: headerHeight + margin, width: imageSize.width, height: imageSize.height)
        if theme.showsScreenshotShadow {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: CGColor(gray: 0, alpha: 0.28))
            context.setFillColor(CGColor(gray: 0, alpha: 0.12))
            context.addPath(CGPath(roundedRect: imageRect, cornerWidth: theme.screenshotCornerRadius, cornerHeight: theme.screenshotCornerRadius, transform: nil))
            context.fillPath()
            context.restoreGState()
        }
        context.saveGState()
        let path = CGPath(roundedRect: imageRect, cornerWidth: theme.screenshotCornerRadius, cornerHeight: theme.screenshotCornerRadius, transform: nil)
        context.addPath(path)
        context.clip()
        context.draw(renderedImage, in: imageRect)
        context.restoreGState()

        for redaction in step.session.redactions {
            let rect = mapped(redaction.rect, sourceSize: step.session.sourcePixelSize, destination: imageRect)
            context.setFillColor(redaction.kind == .solid ? CGColor(gray: 0.08, alpha: 1) : CGColor(gray: 0.25, alpha: 0.92))
            context.fill(rect)
        }

        if let marker = step.session.marker, !marker.isHidden {
            drawMarker(marker, number: step.sequence, in: imageRect, sourceSize: step.session.sourcePixelSize, theme: theme, context: context)
        }
        if step.session.showsCursor, let marker = step.session.marker {
            drawCursor(at: mapped(marker.target, sourceSize: step.session.sourcePixelSize, destination: imageRect), context: context)
        }
        let noteRect = CGRect(x: margin, y: margin * 0.45, width: size.width - margin * 2, height: noteHeight)
        let captionRect = CGRect(
            x: margin,
            y: note.isEmpty ? margin * 0.45 : noteRect.maxY + 16,
            width: size.width - margin * 2,
            height: captionHeight
        )
        drawCaption(caption, number: step.sequence, rect: captionRect, theme: theme, context: context)
        if !note.isEmpty {
            drawNote(note, rect: noteRect, theme: theme, context: context)
        }
        if !theme.organizationName.isEmpty {
            drawSmallText(theme.organizationName, rect: CGRect(x: margin, y: size.height - 36, width: size.width / 2, height: 24), context: context)
        }
        if !theme.footer.isEmpty {
            drawSmallText(theme.footer, rect: CGRect(x: size.width / 2, y: 12, width: size.width / 2 - margin, height: 24), context: context)
        }
        if let logo {
            let ratio = CGFloat(logo.width) / CGFloat(max(logo.height, 1))
            let logoHeight: CGFloat = 44
            context.draw(logo, in: CGRect(x: size.width - margin - logoHeight * ratio, y: size.height - 54, width: logoHeight * ratio, height: logoHeight))
        }
        return context.makeImage()
    }

    static func renderPreview(project: GuideProject, images: [UUID: CGImage], advancedEdits: [UUID: EditableScreenshotDocument] = [:]) -> CGImage? {
        guard let step = project.steps.first(where: { !$0.isDeleted }), let image = images[step.id] else { return nil }
        return renderStepCard(step: step, image: image, theme: project.theme, cardWidth: 960, advancedEdit: advancedEdits[step.id])
    }

    private static func drawMarker(_ marker: GuideMarker, number: Int, in imageRect: CGRect, sourceSize: CGSize, theme: GuideTheme, context: CGContext) {
        let target = mapped(marker.target, sourceSize: sourceSize, destination: imageRect)
        let tail = mapped(marker.tail, sourceSize: sourceSize, destination: imageRect)
        let markerColor = color(marker.colorHex ?? theme.markerColorHex, fallback: CGColor(red: 0.9, green: 0.1, blue: 0.08, alpha: 1))
        context.setStrokeColor(markerColor)
        context.setFillColor(markerColor)
        context.setLineWidth(marker.lineWidth ?? theme.markerLineWidth)
        context.setLineCap(.round)
        context.move(to: tail)
        context.addLine(to: target)
        context.strokePath()
        let angle = atan2(target.y - tail.y, target.x - tail.x)
        let head: CGFloat = 18
        if theme.markerHeadStyle == "circle" {
            context.fillEllipse(in: CGRect(x: target.x - 8, y: target.y - 8, width: 16, height: 16))
        } else {
            context.move(to: target)
            context.addLine(to: CGPoint(x: target.x - head * cos(angle - .pi / 6), y: target.y - head * sin(angle - .pi / 6)))
            context.addLine(to: CGPoint(x: target.x - head * cos(angle + .pi / 6), y: target.y - head * sin(angle + .pi / 6)))
            if theme.markerHeadStyle == "open" { context.strokePath() }
            else { context.closePath(); context.fillPath() }
        }
        if theme.showsClickHighlight {
            context.setStrokeColor(markerColor.copy(alpha: 0.45) ?? markerColor)
            context.setLineWidth(5)
            context.strokeEllipse(in: CGRect(x: target.x - 24, y: target.y - 24, width: 48, height: 48))
        }
        let badgeRect = CGRect(x: tail.x - 18, y: tail.y - 18, width: 36, height: 36)
        switch theme.markerNumberStyle {
        case "none": return
        case "plain": break
        case "square":
            context.addPath(CGPath(roundedRect: badgeRect, cornerWidth: 7, cornerHeight: 7, transform: nil))
            context.fillPath()
        default: context.fillEllipse(in: badgeRect)
        }
        let text = NSAttributedString(string: String(number), attributes: [
            .font: CTFontCreateWithName("Helvetica-Bold" as CFString, 20, nil),
            .foregroundColor: theme.markerNumberStyle == "plain" ? markerColor : CGColor(gray: 1, alpha: 1)
        ])
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        context.textPosition = CGPoint(x: tail.x - bounds.width / 2, y: tail.y - bounds.height / 2 - 2)
        CTLineDraw(line, context)
    }

    private static func drawCaption(_ caption: String, number: Int, rect: CGRect, theme: GuideTheme, context: CGContext) {
        let text = NSAttributedString(string: "\(number). \(caption)", attributes: [
            .font: CTFontCreateWithName("Helvetica-Bold" as CFString, 30, nil),
            .foregroundColor: CGColor(gray: theme.appearance == .dark ? 0.96 : 0.08, alpha: 1)
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, context)
    }

    private static func drawNote(_ note: String, rect: CGRect, theme: GuideTheme, context: CGContext) {
        let text = NSAttributedString(string: "Note: \(note)", attributes: [
            .font: CTFontCreateWithName("Helvetica-Oblique" as CFString, 22, nil),
            .foregroundColor: CGColor(gray: theme.appearance == .dark ? 0.78 : 0.35, alpha: 1)
        ])
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(text), CFRange(), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, context)
    }

    private static func textHeight(_ value: String, font: CTFont, width: CGFloat) -> CGFloat {
        let text = NSAttributedString(string: value, attributes: [.font: font])
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            CTFramesetterCreateWithAttributedString(text),
            CFRange(),
            nil,
            CGSize(width: width, height: .greatestFiniteMagnitude),
            nil
        )
        return ceil(suggested.height)
    }

    private static func drawSmallText(_ value: String, rect: CGRect, context: CGContext) {
        let text = NSAttributedString(string: value, attributes: [
            .font: CTFontCreateWithName("Helvetica" as CFString, 17, nil),
            .foregroundColor: CGColor(gray: 0.35, alpha: 1)
        ])
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(text), CFRange(), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, context)
    }

    private static func drawCursor(at point: CGPoint, context: CGContext) {
        let path = CGMutablePath()
        path.move(to: point)
        path.addLine(to: CGPoint(x: point.x, y: point.y - 26))
        path.addLine(to: CGPoint(x: point.x + 7, y: point.y - 20))
        path.addLine(to: CGPoint(x: point.x + 13, y: point.y - 32))
        path.addLine(to: CGPoint(x: point.x + 18, y: point.y - 29))
        path.addLine(to: CGPoint(x: point.x + 12, y: point.y - 17))
        path.addLine(to: CGPoint(x: point.x + 21, y: point.y - 17))
        path.closeSubpath()
        context.saveGState()
        context.setShadow(offset: CGSize(width: 1, height: -2), blur: 3, color: CGColor(gray: 0, alpha: 0.55))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.95))
        context.setLineWidth(2)
        context.addPath(path)
        context.drawPath(using: .fillStroke)
        context.restoreGState()
    }

    private static func mapped(_ point: CGPoint, sourceSize: CGSize, destination: CGRect) -> CGPoint {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return destination.origin }
        return CGPoint(x: destination.minX + point.x / sourceSize.width * destination.width, y: destination.minY + (1 - point.y / sourceSize.height) * destination.height)
    }

    private static func mapped(_ rect: CGRect, sourceSize: CGSize, destination: CGRect) -> CGRect {
        let first = mapped(rect.origin, sourceSize: sourceSize, destination: destination)
        let second = mapped(CGPoint(x: rect.maxX, y: rect.maxY), sourceSize: sourceSize, destination: destination)
        return CGRect(x: min(first.x, second.x), y: min(first.y, second.y), width: abs(second.x - first.x), height: abs(second.y - first.y))
    }

    private static func color(_ hex: String, fallback: CGColor) -> CGColor {
        let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard value.count == 6, let number = UInt64(value, radix: 16) else { return fallback }
        return CGColor(red: CGFloat((number >> 16) & 255) / 255, green: CGFloat((number >> 8) & 255) / 255, blue: CGFloat(number & 255) / 255, alpha: 1)
    }
}
