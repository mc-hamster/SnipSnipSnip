import AppKit
import CoreGraphics
import CoreImage

enum ScreenshotPresentationRenderer {
    nonisolated private static let ciContext = CIContext(options: nil)

    nonisolated static func render(
        baseImage: CGImage,
        snapshot: EditorSnapshot,
        pinnedUIMapElements: [UIMapElement] = [],
        uiMapOverlayOptions: UIMapOverlayOptions = UIMapOverlayOptions()
    ) -> CGImage? {
        guard let contentImage = EditorRenderer.render(
            baseImage: baseImage,
            snapshot: snapshot,
            pinnedUIMapElements: pinnedUIMapElements,
            uiMapOverlayOptions: uiMapOverlayOptions
        ) else {
            return nil
        }

        return render(contentImage: contentImage, presentation: snapshot.presentation)
    }

    nonisolated static func render(contentImage: CGImage, presentation: ScreenshotPresentation) -> CGImage? {
        guard FeatureFlags.presentationStylingEnabled, presentation.isEnabled else {
            return contentImage
        }

        let insets = presentation.totalInsets
        let contentSize = CGSize(width: contentImage.width, height: contentImage.height)
        let outputSize = CGSize(
            width: contentSize.width + insets.left + insets.right,
            height: contentSize.height + insets.top + insets.bottom
        )
        let width = max(Int(ceil(outputSize.width)), 1)
        let height = max(Int(ceil(outputSize.height)), 1)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
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

        let destinationRect = CGRect(origin: .zero, size: CGSize(width: width, height: height))
        let contentRect = CGRect(
            x: insets.left,
            y: insets.bottom,
            width: contentSize.width,
            height: contentSize.height
        ).integral
        let cornerRadius = min(max(presentation.cornerRadius, 0), min(contentRect.width, contentRect.height) / 2)
        let cardPath = CGPath(
            roundedRect: contentRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )

        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.interpolationQuality = .high
        context.clear(destinationRect)

        switch presentation.background {
        case .transparent:
            break
        case let .solid(color):
            drawCanvasBackground(in: context, destinationRect: destinationRect, cardRect: contentRect, color: color)
        }

        if presentation.shadow != .off {
            drawShadow(
                in: context,
                destinationRect: destinationRect,
                cardRect: contentRect,
                cornerRadius: cornerRadius,
                presentation: presentation
            )
        }

        context.saveGState()
        context.addPath(cardPath)
        context.clip()
        context.draw(contentImage, in: contentRect)
        context.restoreGState()

        drawCardEdge(in: context, cardPath: cardPath, cardRect: contentRect, cornerRadius: cornerRadius)

        return context.makeImage()
    }

    nonisolated static func outputSize(for cropSize: CGSize, presentation: ScreenshotPresentation) -> CGSize {
        guard FeatureFlags.presentationStylingEnabled, presentation.isEnabled else {
            return cropSize
        }

        let insets = presentation.totalInsets
        return CGSize(
            width: cropSize.width + insets.left + insets.right,
            height: cropSize.height + insets.top + insets.bottom
        )
    }

    nonisolated private static func drawShadow(
        in context: CGContext,
        destinationRect: CGRect,
        cardRect: CGRect,
        cornerRadius: CGFloat,
        presentation: ScreenshotPresentation
    ) {
        let style = presentation.shadow
        guard style != .off,
              presentation.shadowBlurRadius > 0,
              presentation.shadowOpacity > 0,
              let maskImage = roundedRectMaskImage(size: destinationRect.size, rect: cardRect, cornerRadius: cornerRadius) else {
            return
        }

        let shadowColor = NSColor(calibratedRed: 0.04, green: 0.05, blue: 0.08, alpha: 1)
        let coolShadowColor = NSColor(calibratedRed: 0.02, green: 0.04, blue: 0.09, alpha: 1)
        let blurRadius = max(presentation.shadowBlurRadius, 0)
        let offsetX = presentation.shadowOffsetX
        let offsetY = presentation.shadowOffsetY
        let opacity = min(max(presentation.shadowOpacity, 0), 1)

        if style == .drop {
            drawShadowLayer(
                in: context,
                destinationRect: destinationRect,
                maskImage: maskImage,
                color: .black,
                blurRadius: blurRadius,
                offsetX: offsetX,
                offsetY: -offsetY,
                opacity: opacity
            )
            return
        }

        drawShadowLayer(
            in: context,
            destinationRect: destinationRect,
            maskImage: maskImage,
            color: shadowColor,
            blurRadius: max(blurRadius * 0.16, 5),
            offsetX: offsetX == 0 ? 0 : offsetX * 0.12,
            offsetY: offsetY == 0 ? -1 : -offsetY * 0.08,
            opacity: opacity * 0.46
        )

        drawShadowLayer(
            in: context,
            destinationRect: destinationRect,
            maskImage: maskImage,
            color: coolShadowColor,
            blurRadius: blurRadius * 0.72,
            offsetX: offsetX * 0.45,
            offsetY: -offsetY * 0.62,
            opacity: opacity * 0.62
        )

        if style == .medium || style == .strong {
            drawShadowLayer(
                in: context,
                destinationRect: destinationRect,
                maskImage: maskImage,
                color: shadowColor,
                blurRadius: blurRadius * 1.18,
                offsetX: offsetX,
                offsetY: -offsetY,
                opacity: opacity * 0.54
            )
        }

        guard style == .strong else {
            return
        }

        drawShadowLayer(
            in: context,
            destinationRect: destinationRect,
            maskImage: maskImage,
            color: coolShadowColor,
            blurRadius: blurRadius * 1.55,
            offsetX: offsetX * 1.6,
            offsetY: -offsetY * 1.36,
            opacity: opacity * 0.24
        )
    }

    nonisolated private static func drawCanvasBackground(
        in context: CGContext,
        destinationRect: CGRect,
        cardRect: CGRect,
        color: RGBAColor
    ) {
        let baseColor = color.nsColor.usingColorSpace(.deviceRGB) ?? color.nsColor
        let topColor = baseColor.blended(withFraction: 0.18, of: .white) ?? baseColor
        let bottomColor = baseColor.blended(withFraction: 0.08, of: .black) ?? baseColor
        let edgeShade = NSColor.black.withAlphaComponent(0.06)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            context.setFillColor(color.cgColor)
            context.fill(destinationRect)
            return
        }

        if let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [topColor.cgColor, bottomColor.cgColor] as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: destinationRect.midX, y: destinationRect.maxY),
                end: CGPoint(x: destinationRect.midX, y: destinationRect.minY),
                options: []
            )
        } else {
            context.setFillColor(color.cgColor)
            context.fill(destinationRect)
        }

        let glowCenter = CGPoint(x: cardRect.midX, y: cardRect.midY + cardRect.height * 0.08)
        let glowRadius = max(cardRect.width, cardRect.height) * 0.95
        if let glowGradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                NSColor.white.withAlphaComponent(0.18).cgColor,
                NSColor.white.withAlphaComponent(0.04).cgColor,
                NSColor.white.withAlphaComponent(0).cgColor,
            ] as CFArray,
            locations: [0, 0.45, 1]
        ) {
            context.saveGState()
            context.setBlendMode(.screen)
            context.drawRadialGradient(
                glowGradient,
                startCenter: glowCenter,
                startRadius: 0,
                endCenter: glowCenter,
                endRadius: glowRadius,
                options: [.drawsAfterEndLocation]
            )
            context.restoreGState()
        }

        if let edgeGradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [NSColor.clear.cgColor, edgeShade.cgColor] as CFArray,
            locations: [0.55, 1]
        ) {
            context.saveGState()
            context.drawRadialGradient(
                edgeGradient,
                startCenter: CGPoint(x: destinationRect.midX, y: destinationRect.midY),
                startRadius: max(destinationRect.width, destinationRect.height) * 0.15,
                endCenter: CGPoint(x: destinationRect.midX, y: destinationRect.midY),
                endRadius: max(destinationRect.width, destinationRect.height) * 0.9,
                options: [.drawsBeforeStartLocation]
            )
            context.restoreGState()
        }
    }

    nonisolated private static func drawShadowLayer(
        in context: CGContext,
        destinationRect: CGRect,
        maskImage: CGImage,
        color: NSColor,
        blurRadius: CGFloat,
        offsetX: CGFloat,
        offsetY: CGFloat,
        opacity: CGFloat
    ) {
        guard opacity > 0 else {
            return
        }

        let blurredMask = CIImage(cgImage: maskImage)
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
            .cropped(to: CGRect(origin: .zero, size: destinationRect.size))
            .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
            .cropped(to: CGRect(origin: .zero, size: destinationRect.size))

        guard let shadowMask = ciContext.createCGImage(blurredMask, from: CGRect(origin: .zero, size: destinationRect.size)) else {
            return
        }

        context.saveGState()
        context.clip(to: destinationRect, mask: shadowMask)
        context.setFillColor(color.withAlphaComponent(opacity).cgColor)
        context.fill(destinationRect)
        context.restoreGState()
    }

    nonisolated private static func drawCardEdge(
        in context: CGContext,
        cardPath: CGPath,
        cardRect: CGRect,
        cornerRadius: CGFloat
    ) {
        context.saveGState()
        context.addPath(cardPath)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.10).cgColor)
        context.setLineWidth(1)
        context.strokePath()
        context.restoreGState()

        let highlightRect = cardRect.insetBy(dx: 0.5, dy: 0.5)
        guard highlightRect.width > 1, highlightRect.height > 1 else {
            return
        }

        let highlightRadius = max(cornerRadius - 0.5, 0)
        let highlightPath = CGPath(
            roundedRect: highlightRect,
            cornerWidth: highlightRadius,
            cornerHeight: highlightRadius,
            transform: nil
        )

        context.saveGState()
        context.addPath(highlightPath)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
        context.setLineWidth(1)
        context.strokePath()
        context.restoreGState()
    }

    nonisolated private static func roundedRectMaskImage(size: CGSize, rect: CGRect, cornerRadius: CGFloat) -> CGImage? {
        let width = max(Int(ceil(size.width)), 1)
        let height = max(Int(ceil(size.height)), 1)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
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

        context.clear(CGRect(origin: .zero, size: CGSize(width: width, height: height)))
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setFillColor(NSColor.white.cgColor)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
        context.fillPath()
        return context.makeImage()
    }
}
