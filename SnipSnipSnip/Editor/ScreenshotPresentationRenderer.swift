import AppKit
import CoreGraphics
import CoreImage

nonisolated struct ScreenshotPresentationRenderResult {
    let image: CGImage
    let layout: ScreenshotPresentationRenderLayout
}

nonisolated struct ScreenshotPresentationRenderLayout: Equatable {
    let canvasSize: CGSize
    let subjectRect: CGRect
    let screenRect: CGRect
    let contentRect: CGRect
    let subjectScale: CGFloat
    let frame: PresentationFrame
}

enum ScreenshotPresentationRenderer {
    nonisolated private static let ciContext = CIContext(options: nil)

    nonisolated private struct FrameMetrics {
        let outerSize: CGSize
        let screenRect: CGRect
        let outerCornerRadius: CGFloat
        let screenCornerRadius: CGFloat
        let contentBackground: NSColor
    }

    nonisolated static func render(
        baseImage: CGImage,
        snapshot: EditorSnapshot,
        pinnedUIMapElements: [UIMapElement] = [],
        uiMapOverlayOptions: UIMapOverlayOptions = UIMapOverlayOptions()
    ) -> CGImage? {
        renderWithLayout(
            baseImage: baseImage,
            snapshot: snapshot,
            pinnedUIMapElements: pinnedUIMapElements,
            uiMapOverlayOptions: uiMapOverlayOptions
        )?.image
    }

    nonisolated static func renderWithLayout(
        baseImage: CGImage,
        snapshot: EditorSnapshot,
        pinnedUIMapElements: [UIMapElement] = [],
        uiMapOverlayOptions: UIMapOverlayOptions = UIMapOverlayOptions(),
        maxPixelDimension: CGFloat? = nil
    ) -> ScreenshotPresentationRenderResult? {
        let contentImage = PresentationPerformanceMetrics.measure(
            "renderer.content",
            context: "base=\(baseImage.width)x\(baseImage.height) crop=\(PresentationPerformanceMetrics.size(snapshot.cropRect.size)) annotations=\(snapshot.annotations.count) uiMapPins=\(pinnedUIMapElements.count)",
            warnAfterMS: 60
        ) {
            EditorRenderer.render(
                baseImage: baseImage,
                snapshot: snapshot,
                pinnedUIMapElements: pinnedUIMapElements,
                uiMapOverlayOptions: uiMapOverlayOptions
            )
        }

        guard let contentImage else {
            return nil
        }

        return renderWithLayout(
            contentImage: contentImage,
            presentation: snapshot.presentation,
            maxPixelDimension: maxPixelDimension
        )
    }

    nonisolated static func render(contentImage: CGImage, presentation: ScreenshotPresentation) -> CGImage? {
        renderWithLayout(contentImage: contentImage, presentation: presentation)?.image
    }

    nonisolated static func renderWithLayout(
        contentImage: CGImage,
        presentation: ScreenshotPresentation,
        maxPixelDimension: CGFloat? = nil
    ) -> ScreenshotPresentationRenderResult? {
        PresentationPerformanceMetrics.measure(
            "renderer.presentation.total",
            context: "input=\(contentImage.width)x\(contentImage.height) \(PresentationPerformanceMetrics.presentationSummary(presentation, maxPixelDimension: maxPixelDimension))",
            warnAfterMS: maxPixelDimension == nil ? 75 : 35
        ) {
            if FeatureFlags.presentationStylingEnabled,
               presentation.isEnabled,
               let scene = presentation.scene {
                return PresentationSceneRenderer.renderWithLayout(
                    contentImage: contentImage,
                    scene: scene,
                    maxPixelDimension: maxPixelDimension
                )
            }

            let prepared = previewRenderInputs(
                contentImage: contentImage,
                presentation: presentation,
                maxPixelDimension: maxPixelDimension
            )

            return renderWithLayoutUnscaled(
                contentImage: prepared.contentImage,
                presentation: prepared.presentation
            )
        }
    }

    nonisolated private static func renderWithLayoutUnscaled(
        contentImage: CGImage,
        presentation: ScreenshotPresentation
    ) -> ScreenshotPresentationRenderResult? {
        guard FeatureFlags.presentationStylingEnabled, presentation.isEnabled else {
            let size = CGSize(width: contentImage.width, height: contentImage.height)
            let rect = CGRect(origin: .zero, size: size)
            return ScreenshotPresentationRenderResult(
                image: contentImage,
                layout: ScreenshotPresentationRenderLayout(
                    canvasSize: size,
                    subjectRect: rect,
                    screenRect: rect,
                    contentRect: rect,
                    subjectScale: 1,
                    frame: .none
                )
            )
        }

        let contentSize = CGSize(width: contentImage.width, height: contentImage.height)
        let metrics = frameMetrics(for: contentSize, presentation: presentation)
        let layout: ScreenshotPresentationRenderLayout = PresentationPerformanceMetrics.measure(
            "renderer.layout",
            context: "content=\(PresentationPerformanceMetrics.size(contentSize)) \(PresentationPerformanceMetrics.presentationSummary(presentation))",
            warnAfterMS: 5
        ) {
            Self.layout(contentSize: contentSize, presentation: presentation)
        }
        let width = max(Int(ceil(layout.canvasSize.width)), 1)
        let height = max(Int(ceil(layout.canvasSize.height)), 1)
        let canvasSize = CGSize(width: width, height: height)

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

        let destinationRect = CGRect(origin: .zero, size: canvasSize)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.interpolationQuality = .high
        context.clear(destinationRect)

        PresentationPerformanceMetrics.measure(
            "renderer.background",
            context: "canvas=\(width)x\(height) background=\(presentation.background.metricNameForRenderer)",
            warnAfterMS: 20
        ) {
            drawBackground(
                in: context,
                destinationRect: destinationRect,
                subjectRect: toCGRect(layout.subjectRect, canvasSize: canvasSize),
                background: presentation.background,
                contentImage: contentImage
            )
        }

        let subjectRect = toCGRect(layout.subjectRect, canvasSize: canvasSize)
        if presentation.shadow != .off {
            PresentationPerformanceMetrics.measure(
                "renderer.shadow",
                context: "canvas=\(width)x\(height) shadow=\(presentation.shadow.rawValue)",
                warnAfterMS: 20
            ) {
                drawShadow(
                    in: context,
                    destinationRect: destinationRect,
                    shadowRect: subjectRect,
                    cornerRadius: metrics.outerCornerRadius * layout.subjectScale,
                    presentation: presentation
                )
            }
        }

        PresentationPerformanceMetrics.measure(
            "renderer.frame",
            context: "canvas=\(width)x\(height) frame=\(presentation.frame.metricNameForRenderer)",
            warnAfterMS: 10
        ) {
            drawFrame(
                presentation.frame,
                in: context,
                canvasSize: canvasSize,
                subjectRect: layout.subjectRect,
                screenRect: layout.screenRect,
                contentRect: layout.contentRect,
                metrics: metrics,
                scale: layout.subjectScale
            )
        }

        PresentationPerformanceMetrics.measure(
            "renderer.contentImage",
            context: "content=\(contentImage.width)x\(contentImage.height) target=\(PresentationPerformanceMetrics.size(layout.contentRect.size))",
            warnAfterMS: 20
        ) {
            drawContentImage(
                contentImage,
                in: context,
                canvasSize: canvasSize,
                presentation: presentation,
                contentRect: layout.contentRect,
                screenRect: layout.screenRect,
                screenCornerRadius: metrics.screenCornerRadius * layout.subjectScale,
                screenBackground: metrics.contentBackground
            )
        }

        drawEdge(
            frame: presentation.frame,
            in: context,
            canvasSize: canvasSize,
            subjectRect: layout.subjectRect,
            screenRect: layout.screenRect,
            contentRect: layout.contentRect,
            metrics: metrics,
            presentation: presentation,
            scale: layout.subjectScale
        )

        let image = PresentationPerformanceMetrics.measure(
            "renderer.makeImage",
            context: "canvas=\(width)x\(height)",
            warnAfterMS: 20
        ) {
            context.makeImage()
        }

        guard let image else {
            return nil
        }

        PresentationPerformanceMetrics.logEvent(
            "renderer.output",
            context: "image=\(image.width)x\(image.height) subject=\(PresentationPerformanceMetrics.size(layout.subjectRect.size)) screen=\(PresentationPerformanceMetrics.size(layout.screenRect.size))"
        )

        return ScreenshotPresentationRenderResult(image: image, layout: layout)
    }

    nonisolated static func outputSize(for cropSize: CGSize, presentation: ScreenshotPresentation) -> CGSize {
        guard FeatureFlags.presentationStylingEnabled, presentation.isEnabled else {
            return cropSize
        }

        if let scene = presentation.scene,
           let sceneSize = PresentationSceneRenderer.outputSize(for: scene) {
            return sceneSize
        }

        return layout(contentSize: cropSize, presentation: presentation).canvasSize
    }

    nonisolated private static func previewRenderInputs(
        contentImage: CGImage,
        presentation: ScreenshotPresentation,
        maxPixelDimension: CGFloat?
    ) -> (contentImage: CGImage, presentation: ScreenshotPresentation) {
        guard let maxPixelDimension,
              maxPixelDimension > 0 else {
            return (contentImage, presentation)
        }

        var currentImage = contentImage
        var currentPresentation = presentation

        for _ in 0..<4 {
            let contentSize = CGSize(width: currentImage.width, height: currentImage.height)
            let canvasSize = FeatureFlags.presentationStylingEnabled && currentPresentation.isEnabled
                ? layout(contentSize: contentSize, presentation: currentPresentation).canvasSize
                : contentSize
            let longestSide = max(canvasSize.width, canvasSize.height)
            let renderScale = min(maxPixelDimension / max(longestSide, 1), 1)

            guard renderScale < 0.995 else {
                return (currentImage, currentPresentation)
            }

            let scaledContent = PresentationPerformanceMetrics.measure(
                "renderer.previewScale",
                context: "from=\(currentImage.width)x\(currentImage.height) scale=\(String(format: "%.3f", Double(renderScale))) cap=\(Int(maxPixelDimension.rounded())) canvas=\(PresentationPerformanceMetrics.size(canvasSize))",
                warnAfterMS: 12
            ) {
                resizedImage(currentImage, scale: renderScale)
            }

            guard let scaledContent else {
                return (currentImage, currentPresentation)
            }

            currentImage = scaledContent
            currentPresentation = scaledPresentation(currentPresentation, scale: renderScale)
        }

        return (currentImage, currentPresentation)
    }

    nonisolated private static func resizedImage(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let width = max(Int((CGFloat(image.width) * scale).rounded()), 1)
        let height = max(Int((CGFloat(image.height) * scale).rounded()), 1)

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

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    nonisolated private static func scaledPresentation(
        _ presentation: ScreenshotPresentation,
        scale: CGFloat
    ) -> ScreenshotPresentation {
        guard scale < 0.995 else {
            return presentation
        }

        var scaled = presentation
        scaled.padding *= scale
        scaled.cornerRadius *= scale
        scaled.shadowBlurRadius *= scale
        scaled.shadowOffsetX *= scale
        scaled.shadowOffsetY *= scale
        scaled.subjectPlacement.offset = CGSize(
            width: scaled.subjectPlacement.offset.width * scale,
            height: scaled.subjectPlacement.offset.height * scale
        )

        if case let .custom(width, height) = scaled.canvas {
            scaled.canvas = .custom(
                width: max(Int((CGFloat(width) * scale).rounded()), 1),
                height: max(Int((CGFloat(height) * scale).rounded()), 1)
            )
        }

        switch scaled.frame {
        case var .phone(style):
            style.screenCornerRadius *= scale
            scaled.frame = .phone(style)
        case var .tablet(style):
            style.screenCornerRadius *= scale
            scaled.frame = .tablet(style)
        case .none, .browser, .macOSWindow:
            break
        }

        return scaled
    }

    nonisolated static func layout(contentSize: CGSize, presentation: ScreenshotPresentation) -> ScreenshotPresentationRenderLayout {
        let metrics = frameMetrics(for: contentSize, presentation: presentation)
        let placement = presentation.subjectPlacement
        let safeInsets = presentation.totalInsets
        let baseSubjectScale = max(placement.scale, 0.05)
        let canvasSize = canvasSize(
            subjectSize: metrics.outerSize,
            presentation: presentation
        )
        let safeRect = CGRect(
            x: safeInsets.left,
            y: safeInsets.top,
            width: max(canvasSize.width - safeInsets.left - safeInsets.right, 1),
            height: max(canvasSize.height - safeInsets.top - safeInsets.bottom, 1)
        )
        let fitScale: CGFloat
        switch placement.fit {
        case .contain:
            fitScale = min(
                safeRect.width / max(metrics.outerSize.width, 1),
                safeRect.height / max(metrics.outerSize.height, 1)
            )
        case .actualSize:
            fitScale = 1
        }
        let subjectScale = max(fitScale * baseSubjectScale, 0.05)
        let subjectSize = CGSize(
            width: metrics.outerSize.width * subjectScale,
            height: metrics.outerSize.height * subjectScale
        )
        let subjectOrigin = CGPoint(
            x: safeRect.minX + max(safeRect.width - subjectSize.width, 0) * placement.alignment.xFactor + placement.offset.width,
            y: safeRect.minY + max(safeRect.height - subjectSize.height, 0) * placement.alignment.yFactor + placement.offset.height
        )
        let subjectRect = CGRect(origin: subjectOrigin, size: subjectSize).integral
        let screenRect = CGRect(
            x: subjectRect.minX + metrics.screenRect.minX * subjectScale,
            y: subjectRect.minY + metrics.screenRect.minY * subjectScale,
            width: metrics.screenRect.width * subjectScale,
            height: metrics.screenRect.height * subjectScale
        ).integral
        let contentRect = aspectFitRect(
            contentSize: contentSize,
            in: screenRect
        ).integral

        return ScreenshotPresentationRenderLayout(
            canvasSize: canvasSize,
            subjectRect: subjectRect,
            screenRect: screenRect,
            contentRect: contentRect,
            subjectScale: subjectScale,
            frame: presentation.frame
        )
    }

    nonisolated private static func canvasSize(
        subjectSize: CGSize,
        presentation: ScreenshotPresentation
    ) -> CGSize {
        let insets = presentation.totalInsets
        let requiredSize = CGSize(
            width: max(subjectSize.width + insets.left + insets.right, 1),
            height: max(subjectSize.height + insets.top + insets.bottom, 1)
        )

        switch presentation.canvas {
        case .original:
            return CGSize(width: ceil(requiredSize.width), height: ceil(requiredSize.height))
        case let .preset(preset):
            let aspect = max(preset.aspectRatio, 0.01)
            if requiredSize.width / max(requiredSize.height, 1) > aspect {
                let width = requiredSize.width
                return CGSize(width: ceil(width), height: ceil(width / aspect))
            } else {
                let height = requiredSize.height
                return CGSize(width: ceil(height * aspect), height: ceil(height))
            }
        case let .custom(width, height):
            return CGSize(width: max(width, 1), height: max(height, 1))
        }
    }

    nonisolated private static func frameMetrics(for contentSize: CGSize, presentation: ScreenshotPresentation) -> FrameMetrics {
        switch presentation.frame {
        case .none:
            return FrameMetrics(
                outerSize: contentSize,
                screenRect: CGRect(origin: .zero, size: contentSize),
                outerCornerRadius: min(max(presentation.cornerRadius, 0), min(contentSize.width, contentSize.height) / 2),
                screenCornerRadius: min(max(presentation.cornerRadius, 0), min(contentSize.width, contentSize.height) / 2),
                contentBackground: .clear
            )
        case .browser:
            let chromeHeight = min(max(contentSize.height * 0.052, 26), 38)
            let outerSize = CGSize(
                width: contentSize.width,
                height: contentSize.height + chromeHeight
            )
            return FrameMetrics(
                outerSize: outerSize,
                screenRect: CGRect(x: 0, y: chromeHeight, width: contentSize.width, height: contentSize.height),
                outerCornerRadius: 7,
                screenCornerRadius: min(max(presentation.cornerRadius, 0), 4),
                contentBackground: .white
            )
        case .macOSWindow:
            let titlebarHeight = min(max(contentSize.height * 0.08, 32), 58)
            let sideInset: CGFloat = 1
            let bottomInset: CGFloat = 1
            let outerSize = CGSize(
                width: contentSize.width + sideInset * 2,
                height: contentSize.height + titlebarHeight + bottomInset
            )
            return FrameMetrics(
                outerSize: outerSize,
                screenRect: CGRect(x: sideInset, y: titlebarHeight, width: contentSize.width, height: contentSize.height),
                outerCornerRadius: 14,
                screenCornerRadius: min(max(presentation.cornerRadius, 0), 12),
                contentBackground: .windowBackgroundColor
            )
        case let .phone(style):
            return deviceMetrics(contentSize: contentSize, style: style, isTablet: false)
        case let .tablet(style):
            return deviceMetrics(contentSize: contentSize, style: style, isTablet: true)
        }
    }

    nonisolated private static func deviceMetrics(
        contentSize: CGSize,
        style: PresentationDeviceFrameStyle,
        isTablet: Bool
    ) -> FrameMetrics {
        let screenAspect: CGFloat = {
            if isTablet {
                return style.orientation == .portrait ? 3 / 4 : 4 / 3
            }
            return style.orientation == .portrait ? 9 / 19.5 : 19.5 / 9
        }()
        let contentAspect = contentSize.width / max(contentSize.height, 1)
        let screenSize: CGSize
        if contentAspect > screenAspect {
            screenSize = CGSize(width: contentSize.width, height: contentSize.width / screenAspect)
        } else {
            screenSize = CGSize(width: contentSize.height * screenAspect, height: contentSize.height)
        }

        let bezel = max(min(screenSize.width, screenSize.height) * (isTablet ? 0.055 : 0.075), isTablet ? 18 : 16)
        let topInset = bezel + (style.showsSensorHousing && style.orientation == .portrait ? (isTablet ? 0 : bezel * 0.58) : 0)
        let bottomInset = bezel * (isTablet ? 1.05 : 1.25)
        let outerSize = CGSize(
            width: screenSize.width + bezel * 2,
            height: screenSize.height + topInset + bottomInset
        )
        let screenRect = CGRect(x: bezel, y: topInset, width: screenSize.width, height: screenSize.height)
        let outerRadius = min(min(outerSize.width, outerSize.height) * (isTablet ? 0.07 : 0.12), isTablet ? 34 : 42)

        return FrameMetrics(
            outerSize: outerSize,
            screenRect: screenRect,
            outerCornerRadius: outerRadius,
            screenCornerRadius: style.screenCornerRadius,
            contentBackground: .black
        )
    }

    nonisolated private static func drawBackground(
        in context: CGContext,
        destinationRect: CGRect,
        subjectRect: CGRect,
        background: ScreenshotPresentationBackground,
        contentImage: CGImage
    ) {
        switch background {
        case .transparent:
            break
        case let .solid(color):
            drawCanvasBackground(in: context, destinationRect: destinationRect, cardRect: subjectRect, color: color)
        case let .twoColorGradient(start, end):
            drawLinearBackground(in: context, destinationRect: destinationRect, start: start, end: end)
        case let .radialSpotlight(base, spotlight):
            context.setFillColor(base.cgColor)
            context.fill(destinationRect)
            drawSpotlight(in: context, destinationRect: destinationRect, color: spotlight)
        case let .blurredScreenshot(tint):
            drawBlurredScreenshotBackground(in: context, destinationRect: destinationRect, contentImage: contentImage, tint: tint)
        }
    }

    nonisolated private static func drawFrame(
        _ frame: PresentationFrame,
        in context: CGContext,
        canvasSize: CGSize,
        subjectRect: CGRect,
        screenRect: CGRect,
        contentRect: CGRect,
        metrics: FrameMetrics,
        scale: CGFloat
    ) {
        switch frame {
        case .none:
            break
        case let .browser(style):
            drawBrowserFrame(style, in: context, canvasSize: canvasSize, subjectRect: subjectRect, screenRect: screenRect, cornerRadius: metrics.outerCornerRadius * scale)
        case let .macOSWindow(style):
            drawMacWindowFrame(style, in: context, canvasSize: canvasSize, subjectRect: subjectRect, screenRect: screenRect, cornerRadius: metrics.outerCornerRadius * scale)
        case let .phone(style):
            drawDeviceFrame(style, isTablet: false, in: context, canvasSize: canvasSize, subjectRect: subjectRect, screenRect: screenRect, cornerRadius: metrics.outerCornerRadius * scale)
        case let .tablet(style):
            drawDeviceFrame(style, isTablet: true, in: context, canvasSize: canvasSize, subjectRect: subjectRect, screenRect: screenRect, cornerRadius: metrics.outerCornerRadius * scale)
        }
    }

    nonisolated private static func drawContentImage(
        _ contentImage: CGImage,
        in context: CGContext,
        canvasSize: CGSize,
        presentation: ScreenshotPresentation,
        contentRect: CGRect,
        screenRect: CGRect,
        screenCornerRadius: CGFloat,
        screenBackground: NSColor
    ) {
        let screenCGRect = toCGRect(screenRect, canvasSize: canvasSize)
        if presentation.frame != .none {
            context.saveGState()
            context.setFillColor(screenBackground.cgColor)
            context.addPath(CGPath(
                roundedRect: screenCGRect,
                cornerWidth: screenCornerRadius,
                cornerHeight: screenCornerRadius,
                transform: nil
            ))
            context.fillPath()
            context.restoreGState()
        }

        let contentCGRect = toCGRect(contentRect, canvasSize: canvasSize)
        let clipRadius = presentation.frame == .none ? screenCornerRadius : min(screenCornerRadius, min(screenCGRect.width, screenCGRect.height) / 2)
        let clipRect = presentation.frame == .none ? contentCGRect : screenCGRect

        context.saveGState()
        context.addPath(CGPath(
            roundedRect: clipRect,
            cornerWidth: clipRadius,
            cornerHeight: clipRadius,
            transform: nil
        ))
        context.clip()
        context.draw(contentImage, in: contentCGRect)
        context.restoreGState()
    }

    nonisolated private static func drawEdge(
        frame: PresentationFrame,
        in context: CGContext,
        canvasSize: CGSize,
        subjectRect: CGRect,
        screenRect: CGRect,
        contentRect: CGRect,
        metrics: FrameMetrics,
        presentation: ScreenshotPresentation,
        scale: CGFloat
    ) {
        switch frame {
        case .none:
            let contentCGRect = toCGRect(contentRect, canvasSize: canvasSize)
            let cornerRadius = min(max(presentation.cornerRadius, 0), min(contentCGRect.width, contentCGRect.height) / 2)
            drawCardEdge(
                in: context,
                cardPath: CGPath(roundedRect: contentCGRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil),
                cardRect: contentCGRect,
                cornerRadius: cornerRadius
            )
        case .browser, .macOSWindow, .phone, .tablet:
            let screenCGRect = toCGRect(screenRect, canvasSize: canvasSize)
            let radius = metrics.screenCornerRadius * scale
            context.saveGState()
            context.addPath(CGPath(roundedRect: screenCGRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.18).cgColor)
            context.setLineWidth(1)
            context.strokePath()
            context.restoreGState()
        }
    }

    nonisolated private static func drawBrowserFrame(
        _ style: PresentationBrowserFrameStyle,
        in context: CGContext,
        canvasSize: CGSize,
        subjectRect: CGRect,
        screenRect: CGRect,
        cornerRadius: CGFloat
    ) {
        let outer = toCGRect(subjectRect, canvasSize: canvasSize)
        let screen = toCGRect(screenRect, canvasSize: canvasSize)
        let isDark = style.scheme == .dark
        let pageColor = isDark ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor(calibratedWhite: 0.97, alpha: 1)
        let toolbarTopColor = isDark ? NSColor(calibratedWhite: 0.20, alpha: 1) : NSColor(calibratedWhite: 0.90, alpha: 1)
        let toolbarBottomColor = isDark ? NSColor(calibratedWhite: 0.16, alpha: 1) : NSColor(calibratedWhite: 0.84, alpha: 1)
        let fieldColor = isDark ? NSColor(calibratedWhite: 0.27, alpha: 1) : NSColor(calibratedWhite: 0.96, alpha: 1)
        let iconColor = isDark ? NSColor(calibratedWhite: 0.70, alpha: 0.46) : NSColor(calibratedWhite: 0.54, alpha: 0.34)
        let textColor = isDark ? NSColor(calibratedWhite: 0.82, alpha: 0.34) : NSColor(calibratedWhite: 0.58, alpha: 0.26)
        let chromeHeight = max(outer.maxY - screen.maxY, 28)
        let chromeRect = CGRect(x: outer.minX, y: screen.maxY, width: outer.width, height: chromeHeight)
        let iconScale = max(min(chromeHeight / 28, 1.35), 0.75)
        let iconStroke = max(iconScale, 0.8)

        context.saveGState()
        context.addPath(CGPath(roundedRect: outer, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
        context.clip()
        context.setFillColor(pageColor.cgColor)
        context.fill(outer)
        let toolbarGradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [toolbarTopColor.cgColor, toolbarBottomColor.cgColor] as CFArray,
            locations: [0, 1]
        )
        if let toolbarGradient {
            context.drawLinearGradient(
                toolbarGradient,
                start: CGPoint(x: chromeRect.midX, y: chromeRect.maxY),
                end: CGPoint(x: chromeRect.midX, y: chromeRect.minY),
                options: []
            )
        } else {
            context.setFillColor(toolbarTopColor.cgColor)
            context.fill(chromeRect)
        }
        context.restoreGState()

        if style.showsTrafficLights {
            let dotRadius = max(min(chromeHeight * 0.105, 4.2), 2.4)
            let dotY = chromeRect.midY
            let startX = outer.minX + max(chromeHeight * 0.44, 9)
            for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                context.setFillColor(color.withAlphaComponent(isDark ? 0.78 : 0.84).cgColor)
                context.fillEllipse(in: CGRect(
                    x: startX + CGFloat(index) * dotRadius * 2.85,
                    y: dotY - dotRadius,
                    width: dotRadius * 2,
                    height: dotRadius * 2
                ))
            }
        }

        context.saveGState()
        context.setStrokeColor(iconColor.cgColor)
        context.setLineWidth(iconStroke)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let navX = outer.minX + max(chromeHeight * 1.28, 34)
        let navY = chromeRect.midY
        let chevronWidth = 4.2 * iconScale
        let chevronHeight = 5.4 * iconScale
        drawChevronLeft(in: context, center: CGPoint(x: navX, y: navY), width: chevronWidth, height: chevronHeight)
        drawChevronRight(in: context, center: CGPoint(x: navX + 9.0 * iconScale, y: navY), width: chevronWidth, height: chevronHeight)

        let sidebarRect = CGRect(
            x: navX + 27 * iconScale,
            y: navY - 4.6 * iconScale,
            width: 9.2 * iconScale,
            height: 9.2 * iconScale
        )
        context.stroke(sidebarRect)
        context.move(to: CGPoint(x: sidebarRect.minX + sidebarRect.width * 0.38, y: sidebarRect.minY))
        context.addLine(to: CGPoint(x: sidebarRect.minX + sidebarRect.width * 0.38, y: sidebarRect.maxY))
        context.strokePath()
        context.restoreGState()

        let addressRect = CGRect(
            x: outer.midX - outer.width * 0.285,
            y: chromeRect.midY - max(chromeHeight * 0.145, 4.6),
            width: outer.width * 0.57,
            height: max(chromeHeight * 0.29, 9.2)
        )
        context.setFillColor(fieldColor.cgColor)
        context.addPath(CGPath(
            roundedRect: addressRect,
            cornerWidth: addressRect.height / 2,
            cornerHeight: addressRect.height / 2,
            transform: nil
        ))
        context.fillPath()

        let addressText = style.address.isEmpty ? style.title : style.address
        drawTextTopLeft(
            addressText,
            in: fromCGRect(addressRect, canvasSize: canvasSize).insetBy(dx: addressRect.height * 1.15, dy: 1),
            context: context,
            canvasSize: canvasSize,
            color: textColor,
            fontSize: max(addressRect.height * 0.34, 4.8),
            alignment: .center
        )

        context.saveGState()
        context.setStrokeColor(iconColor.cgColor)
        context.setLineWidth(iconStroke)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let lockX = addressRect.minX + addressRect.height * 0.58
        let lockY = chromeRect.midY
        let lockWidth = max(addressRect.height * 0.24, 2.4)
        let lockBody = CGRect(x: lockX - lockWidth / 2, y: lockY - lockWidth * 0.12, width: lockWidth, height: lockWidth * 0.56)
        context.stroke(lockBody)
        context.addArc(center: CGPoint(x: lockX, y: lockBody.maxY), radius: lockWidth * 0.36, startAngle: .pi, endAngle: 0, clockwise: false)
        context.strokePath()

        let shareX = outer.maxX - max(chromeHeight * 1.02, 28)
        let shareRect = CGRect(x: shareX, y: navY - 5.0 * iconScale, width: 9.8 * iconScale, height: 9.8 * iconScale)
        context.stroke(shareRect)
        context.move(to: CGPoint(x: shareRect.midX, y: shareRect.maxY + 2.2 * iconScale))
        context.addLine(to: CGPoint(x: shareRect.midX, y: shareRect.minY + 2.0 * iconScale))
        context.move(to: CGPoint(x: shareRect.midX - 2.8 * iconScale, y: shareRect.maxY - 0.5 * iconScale))
        context.addLine(to: CGPoint(x: shareRect.midX, y: shareRect.maxY + 2.2 * iconScale))
        context.addLine(to: CGPoint(x: shareRect.midX + 2.8 * iconScale, y: shareRect.maxY - 0.5 * iconScale))
        context.strokePath()

        let tabsRect = CGRect(
            x: outer.maxX - max(chromeHeight * 0.55, 15),
            y: navY - 4.4 * iconScale,
            width: 8.8 * iconScale,
            height: 8.8 * iconScale
        )
        context.stroke(tabsRect.offsetBy(dx: -2.2 * iconScale, dy: 1.8 * iconScale))
        context.stroke(tabsRect)
        context.restoreGState()

        context.saveGState()
        context.setStrokeColor(NSColor.black.withAlphaComponent(isDark ? 0.36 : 0.14).cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: outer.minX, y: screen.maxY))
        context.addLine(to: CGPoint(x: outer.maxX, y: screen.maxY))
        context.strokePath()
        context.setStrokeColor(NSColor.black.withAlphaComponent(isDark ? 0.34 : 0.12).cgColor)
        context.addPath(CGPath(
            roundedRect: outer.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: max(cornerRadius - 0.5, 0),
            cornerHeight: max(cornerRadius - 0.5, 0),
            transform: nil
        ))
        context.strokePath()
        context.restoreGState()
    }

    nonisolated private static func drawChevronLeft(
        in context: CGContext,
        center: CGPoint,
        width: CGFloat,
        height: CGFloat
    ) {
        context.move(to: CGPoint(x: center.x + width / 2, y: center.y + height / 2))
        context.addLine(to: CGPoint(x: center.x - width / 2, y: center.y))
        context.addLine(to: CGPoint(x: center.x + width / 2, y: center.y - height / 2))
        context.strokePath()
    }

    nonisolated private static func drawChevronRight(
        in context: CGContext,
        center: CGPoint,
        width: CGFloat,
        height: CGFloat
    ) {
        context.move(to: CGPoint(x: center.x - width / 2, y: center.y + height / 2))
        context.addLine(to: CGPoint(x: center.x + width / 2, y: center.y))
        context.addLine(to: CGPoint(x: center.x - width / 2, y: center.y - height / 2))
        context.strokePath()
    }

    nonisolated private static func drawMacWindowFrame(
        _ style: PresentationMacWindowFrameStyle,
        in context: CGContext,
        canvasSize: CGSize,
        subjectRect: CGRect,
        screenRect: CGRect,
        cornerRadius: CGFloat
    ) {
        let outer = toCGRect(subjectRect, canvasSize: canvasSize)
        let screen = toCGRect(screenRect, canvasSize: canvasSize)
        let isDark = style.scheme == .dark
        let bodyColor = isDark ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor(calibratedWhite: 0.97, alpha: 1)
        let titleColor = isDark ? NSColor(calibratedWhite: 0.17, alpha: 1) : NSColor(calibratedWhite: 0.92, alpha: 1)
        let textColor = isDark ? NSColor(calibratedWhite: 0.76, alpha: 1) : NSColor(calibratedWhite: 0.25, alpha: 1)
        let titlebarHeight = max(outer.maxY - screen.maxY, 24)
        let titlebarRect = CGRect(x: outer.minX, y: screen.maxY, width: outer.width, height: titlebarHeight)

        context.saveGState()
        context.addPath(CGPath(roundedRect: outer, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
        context.clip()
        context.setFillColor(bodyColor.cgColor)
        context.fill(outer)
        context.setFillColor(titleColor.cgColor)
        context.fill(titlebarRect)
        context.restoreGState()

        if style.showsTrafficLights {
            let dotRadius = max(min(titlebarHeight * 0.14, 5.5), 3)
            let dotY = titlebarRect.midY
            let startX = outer.minX + max(titlebarHeight * 0.36, 12)
            for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                context.setFillColor(color.withAlphaComponent(0.9).cgColor)
                context.fillEllipse(in: CGRect(
                    x: startX + CGFloat(index) * dotRadius * 2.9,
                    y: dotY - dotRadius,
                    width: dotRadius * 2,
                    height: dotRadius * 2
                ))
            }
        }

        drawTextTopLeft(
            style.title,
            in: fromCGRect(titlebarRect.insetBy(dx: titlebarHeight * 2.1, dy: titlebarHeight * 0.24), canvasSize: canvasSize),
            context: context,
            canvasSize: canvasSize,
            color: textColor,
            fontSize: max(titlebarHeight * 0.30, 9),
            alignment: .center
        )

        context.saveGState()
        context.setStrokeColor(NSColor.black.withAlphaComponent(isDark ? 0.36 : 0.14).cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: outer.minX, y: screen.maxY))
        context.addLine(to: CGPoint(x: outer.maxX, y: screen.maxY))
        context.strokePath()
        context.addPath(CGPath(roundedRect: outer.insetBy(dx: 0.5, dy: 0.5), cornerWidth: max(cornerRadius - 0.5, 0), cornerHeight: max(cornerRadius - 0.5, 0), transform: nil))
        context.strokePath()
        context.restoreGState()
    }

    nonisolated private static func drawBrowserToolbarGlyph(
        _ glyph: String,
        x: CGFloat,
        y: CGFloat,
        attributes: [NSAttributedString.Key: Any],
        context: CGContext
    ) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        (glyph as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    nonisolated private static func drawDeviceFrame(
        _ style: PresentationDeviceFrameStyle,
        isTablet: Bool,
        in context: CGContext,
        canvasSize: CGSize,
        subjectRect: CGRect,
        screenRect: CGRect,
        cornerRadius: CGFloat
    ) {
        let outer = toCGRect(subjectRect, canvasSize: canvasSize)
        let screen = toCGRect(screenRect, canvasSize: canvasSize)
        let bezel = style.bezelColor.nsColor
        let bezelTop = bezel.blended(withFraction: 0.16, of: .white) ?? bezel
        let bezelBottom = bezel.blended(withFraction: 0.18, of: .black) ?? bezel
        let highlight = NSColor.white.withAlphaComponent(isTablet ? 0.10 : 0.14)
        let lowlight = NSColor.black.withAlphaComponent(0.42)
        let outerPath = CGPath(roundedRect: outer, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        if style.castsDeviceShadow {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -outer.height * 0.02), blur: max(outer.width, outer.height) * 0.035, color: NSColor.black.withAlphaComponent(0.22).cgColor)
            context.setFillColor(bezelBottom.cgColor)
            context.addPath(outerPath)
            context.fillPath()
            context.restoreGState()
        }

        context.saveGState()
        context.addPath(outerPath)
        context.clip()
        if let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
           let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [bezelTop.cgColor, bezel.cgColor, bezelBottom.cgColor] as CFArray,
            locations: [0, 0.45, 1]
           ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: outer.midX, y: outer.maxY),
                end: CGPoint(x: outer.midX, y: outer.minY),
                options: []
            )
        } else {
            context.setFillColor(bezel.cgColor)
            context.fill(outer)
        }
        context.restoreGState()

        drawDeviceSideButtons(style: style, isTablet: isTablet, in: context, outer: outer)

        context.saveGState()
        context.addPath(CGPath(roundedRect: outer.insetBy(dx: 1.2, dy: 1.2), cornerWidth: max(cornerRadius - 1.2, 0), cornerHeight: max(cornerRadius - 1.2, 0), transform: nil))
        context.setStrokeColor(highlight.cgColor)
        context.setLineWidth(1.4)
        context.strokePath()
        context.restoreGState()

        context.saveGState()
        context.addPath(CGPath(roundedRect: screen.insetBy(dx: -1.5, dy: -1.5), cornerWidth: max(style.screenCornerRadius + 1.5, 0), cornerHeight: max(style.screenCornerRadius + 1.5, 0), transform: nil))
        context.setStrokeColor(lowlight.cgColor)
        context.setLineWidth(3)
        context.strokePath()
        context.restoreGState()

        if isTablet {
            let cameraRadius = max(min(min(outer.width, outer.height) * 0.008, 4.5), 2.2)
            let cameraCenter = style.orientation == .portrait
                ? CGPoint(x: outer.midX, y: screen.maxY + max((outer.maxY - screen.maxY) * 0.48, cameraRadius * 2.2))
                : CGPoint(x: screen.maxX + max((outer.maxX - screen.maxX) * 0.48, cameraRadius * 2.2), y: outer.midY)
            context.setFillColor(NSColor.black.withAlphaComponent(0.58).cgColor)
            context.fillEllipse(in: CGRect(
                x: cameraCenter.x - cameraRadius,
                y: cameraCenter.y - cameraRadius,
                width: cameraRadius * 2,
                height: cameraRadius * 2
            ))
        } else if style.showsSensorHousing {
            drawPhoneSensorHousing(style: style, in: context, screen: screen)
        }

        drawHomeIndicator(style: style, isTablet: isTablet, in: context, screen: screen)
    }

    nonisolated private static func drawPhoneSensorHousing(
        style: PresentationDeviceFrameStyle,
        in context: CGContext,
        screen: CGRect
    ) {
        let notchWidth = min(screen.width * (style.orientation == .portrait ? 0.32 : 0.18), 84)
        let notchHeight = min(screen.height * (style.orientation == .portrait ? 0.030 : 0.070), 18)
        let notchRect: CGRect
        if style.orientation == .portrait {
            notchRect = CGRect(x: screen.midX - notchWidth / 2, y: screen.maxY - notchHeight - screen.height * 0.012, width: notchWidth, height: notchHeight)
        } else {
            notchRect = CGRect(x: screen.maxX - notchHeight - screen.width * 0.012, y: screen.midY - notchWidth / 2, width: notchHeight, height: notchWidth)
        }
        context.setFillColor(NSColor.black.withAlphaComponent(0.78).cgColor)
        context.addPath(CGPath(roundedRect: notchRect, cornerWidth: min(notchRect.width, notchRect.height) / 2, cornerHeight: min(notchRect.width, notchRect.height) / 2, transform: nil))
        context.fillPath()
    }

    nonisolated private static func drawHomeIndicator(
        style: PresentationDeviceFrameStyle,
        isTablet: Bool,
        in context: CGContext,
        screen: CGRect
    ) {
        let indicatorLength = min((style.orientation == .portrait ? screen.width : screen.height) * (isTablet ? 0.20 : 0.28), isTablet ? 78 : 92)
        let indicatorThickness = max(min(indicatorLength * 0.045, 4), 2)
        let indicatorRect: CGRect

        if style.orientation == .portrait {
            indicatorRect = CGRect(
                x: screen.midX - indicatorLength / 2,
                y: screen.minY + screen.height * 0.025,
                width: indicatorLength,
                height: indicatorThickness
            )
        } else {
            indicatorRect = CGRect(
                x: screen.minX + screen.width * 0.025,
                y: screen.midY - indicatorLength / 2,
                width: indicatorThickness,
                height: indicatorLength
            )
        }

        context.setFillColor(NSColor.white.withAlphaComponent(0.42).cgColor)
        context.addPath(CGPath(
            roundedRect: indicatorRect,
            cornerWidth: min(indicatorRect.width, indicatorRect.height) / 2,
            cornerHeight: min(indicatorRect.width, indicatorRect.height) / 2,
            transform: nil
        ))
        context.fillPath()
    }

    nonisolated private static func drawDeviceSideButtons(
        style: PresentationDeviceFrameStyle,
        isTablet: Bool,
        in context: CGContext,
        outer: CGRect
    ) {
        let buttonColor = NSColor.white.withAlphaComponent(0.16)
        let shortSide = min(outer.width, outer.height)
        let thickness = max(shortSide * 0.008, 1.4)
        let length = max(shortSide * (isTablet ? 0.13 : 0.17), 18)

        context.setFillColor(buttonColor.cgColor)

        if style.orientation == .portrait {
            let leftButton = CGRect(
                x: outer.minX + thickness * 1.4,
                y: outer.maxY - outer.height * 0.35,
                width: thickness,
                height: length
            )
            let rightButton = CGRect(
                x: outer.maxX - thickness * 2.4,
                y: outer.maxY - outer.height * 0.45,
                width: thickness,
                height: length * 1.2
            )
            for rect in [leftButton, rightButton] {
                context.addPath(CGPath(roundedRect: rect, cornerWidth: thickness / 2, cornerHeight: thickness / 2, transform: nil))
                context.fillPath()
            }
        } else {
            let topButton = CGRect(
                x: outer.minX + outer.width * 0.28,
                y: outer.maxY - thickness * 2.4,
                width: length,
                height: thickness
            )
            context.addPath(CGPath(roundedRect: topButton, cornerWidth: thickness / 2, cornerHeight: thickness / 2, transform: nil))
            context.fillPath()
        }
    }

    nonisolated private static func drawShadow(
        in context: CGContext,
        destinationRect: CGRect,
        shadowRect: CGRect,
        cornerRadius: CGFloat,
        presentation: ScreenshotPresentation
    ) {
        let style = presentation.shadow
        guard style != .off,
              presentation.shadowBlurRadius > 0,
              presentation.shadowOpacity > 0 else {
            return
        }

        let shadowColor = NSColor(calibratedRed: 0.04, green: 0.05, blue: 0.08, alpha: 1)
        let coolShadowColor = NSColor(calibratedRed: 0.02, green: 0.04, blue: 0.09, alpha: 1)
        let blurRadius = max(presentation.shadowBlurRadius, 0)
        let offsetX = presentation.shadowOffsetX
        let offsetY = presentation.shadowOffsetY
        let opacity = min(max(presentation.shadowOpacity, 0), 1)

        if max(destinationRect.width, destinationRect.height) <= 360 {
            drawFastPreviewShadow(
                in: context,
                shadowRect: shadowRect,
                cornerRadius: cornerRadius,
                color: style == .drop ? .black : coolShadowColor,
                blurRadius: blurRadius,
                offsetX: offsetX,
                offsetY: -offsetY,
                opacity: opacity
            )
            return
        }

        guard let maskImage = roundedRectMaskImage(size: destinationRect.size, rect: shadowRect, cornerRadius: cornerRadius) else {
            return
        }

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

    nonisolated private static func drawFastPreviewShadow(
        in context: CGContext,
        shadowRect: CGRect,
        cornerRadius: CGFloat,
        color: NSColor,
        blurRadius: CGFloat,
        offsetX: CGFloat,
        offsetY: CGFloat,
        opacity: CGFloat
    ) {
        guard opacity > 0 else {
            return
        }

        let path = CGPath(roundedRect: shadowRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: offsetX, height: offsetY),
            blur: max(blurRadius, 1),
            color: color.withAlphaComponent(opacity).cgColor
        )
        context.setFillColor(color.withAlphaComponent(0.004).cgColor)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
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

    nonisolated private static func drawLinearBackground(
        in context: CGContext,
        destinationRect: CGRect,
        start: RGBAColor,
        end: RGBAColor
    ) {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(
                colorsSpace: colorSpace,
                colors: [start.cgColor, end.cgColor] as CFArray,
                locations: [0, 1]
              ) else {
            context.setFillColor(start.cgColor)
            context.fill(destinationRect)
            return
        }

        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: destinationRect.minX, y: destinationRect.maxY),
            end: CGPoint(x: destinationRect.maxX, y: destinationRect.minY),
            options: []
        )
    }

    nonisolated private static func drawSpotlight(
        in context: CGContext,
        destinationRect: CGRect,
        color: RGBAColor
    ) {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(
                colorsSpace: colorSpace,
                colors: [
                    color.withAlpha(0.78).cgColor,
                    color.withAlpha(0.20).cgColor,
                    color.withAlpha(0).cgColor,
                ] as CFArray,
                locations: [0, 0.46, 1]
              ) else {
            return
        }

        context.saveGState()
        context.setBlendMode(.screen)
        context.drawRadialGradient(
            gradient,
            startCenter: CGPoint(x: destinationRect.midX, y: destinationRect.midY + destinationRect.height * 0.12),
            startRadius: 0,
            endCenter: CGPoint(x: destinationRect.midX, y: destinationRect.midY),
            endRadius: max(destinationRect.width, destinationRect.height) * 0.72,
            options: [.drawsAfterEndLocation]
        )
        context.restoreGState()
    }

    nonisolated private static func drawBlurredScreenshotBackground(
        in context: CGContext,
        destinationRect: CGRect,
        contentImage: CGImage,
        tint: RGBAColor
    ) {
        let blurRadius = max(min(destinationRect.width, destinationRect.height) * 0.045, 18)
        let input = CIImage(cgImage: contentImage)
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
            .cropped(to: CGRect(x: 0, y: 0, width: contentImage.width, height: contentImage.height))

        if let blurred = ciContext.createCGImage(input, from: CGRect(x: 0, y: 0, width: contentImage.width, height: contentImage.height)) {
            let coverRect = aspectFillRect(
                contentSize: CGSize(width: blurred.width, height: blurred.height),
                in: destinationRect
            )
            context.saveGState()
            context.setAlpha(0.92)
            context.draw(blurred, in: coverRect)
            context.restoreGState()
        }

        context.setFillColor(tint.cgColor)
        context.fill(destinationRect)
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

    nonisolated private static func aspectFitRect(contentSize: CGSize, in container: CGRect) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0, container.width > 0, container.height > 0 else {
            return container
        }

        let scale = min(container.width / contentSize.width, container.height / contentSize.height)
        let size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        return CGRect(
            x: container.midX - size.width / 2,
            y: container.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    nonisolated private static func aspectFillRect(contentSize: CGSize, in container: CGRect) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0, container.width > 0, container.height > 0 else {
            return container
        }

        let scale = max(container.width / contentSize.width, container.height / contentSize.height)
        let size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        return CGRect(
            x: container.midX - size.width / 2,
            y: container.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    nonisolated private static func toCGRect(_ topLeftRect: CGRect, canvasSize: CGSize) -> CGRect {
        CGRect(
            x: topLeftRect.minX,
            y: canvasSize.height - topLeftRect.maxY,
            width: topLeftRect.width,
            height: topLeftRect.height
        )
    }

    nonisolated private static func fromCGRect(_ rect: CGRect, canvasSize: CGSize) -> CGRect {
        CGRect(
            x: rect.minX,
            y: canvasSize.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    nonisolated private static func drawTextTopLeft(
        _ text: String,
        in rect: CGRect,
        context: CGContext,
        canvasSize: CGSize,
        color: NSColor,
        fontSize: CGFloat,
        alignment: NSTextAlignment = .left
    ) {
        guard !text.isEmpty else {
            return
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingMiddle
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        (text as NSString).draw(in: rect, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }
}

private extension ScreenshotPresentationBackground {
    nonisolated var metricNameForRenderer: String {
        switch self {
        case .transparent:
            return "transparent"
        case .solid:
            return "solid"
        case .twoColorGradient:
            return "gradient"
        case .radialSpotlight:
            return "spotlight"
        case .blurredScreenshot:
            return "blurredScreenshot"
        }
    }
}

private extension PresentationFrame {
    nonisolated var metricNameForRenderer: String {
        switch self {
        case .none:
            return "none"
        case .browser:
            return "browser"
        case .macOSWindow:
            return "macOSWindow"
        case .phone:
            return "phone"
        case .tablet:
            return "tablet"
        }
    }
}
