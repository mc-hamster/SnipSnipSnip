import AppKit
import CoreGraphics
import Foundation

nonisolated enum PresentationSceneRenderer {
    static func renderWithLayout(
        contentImage: CGImage,
        scene: AppliedPresentationScene,
        maxPixelDimension: CGFloat? = nil,
        logicalContentSize: CGSize? = nil
    ) -> ScreenshotPresentationRenderResult? {
        guard validSettings(scene.screenshotSlotSettings) else { return nil }
        if let logicalContentSize,
           !logicalContentSize.width.isFinite || !logicalContentSize.height.isFinite
            || logicalContentSize.width <= 0 || logicalContentSize.height <= 0 { return nil }
        let maxPixelDimension = maxPixelDimension.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return PresentationPerformanceMetrics.measure(
            "scene.render.total",
            context: "scene=\(scene.sceneID) version=\(scene.version) content=\(contentImage.width)x\(contentImage.height) cap=\(maxPixelDimension.map { String(Int($0.rounded())) } ?? "none")",
            warnAfterMS: 55
        ) {
            let originalCanvasSize = outputSize(for: scene) ?? CGSize(width: 1600, height: 900)
            let renderScale = maxPixelDimension.flatMap { limit -> CGFloat? in
                guard limit.isFinite, limit > 0 else { return nil }
                return min(limit / max(max(originalCanvasSize.width, originalCanvasSize.height), 1), 1)
            } ?? 1
            guard let prepared = preparedSVG(
                contentImage: contentImage,
                scene: scene,
                renderScale: renderScale,
                logicalContentSize: logicalContentSize
            ),
                  let image = rasterize(svgText: prepared.svgText, canvasSize: prepared.metadata.canvas.size, scale: renderScale) else {
                return nil
            }

            let canvasSize = CGSize(
                width: prepared.metadata.canvas.size.width * renderScale,
                height: prepared.metadata.canvas.size.height * renderScale
            )
            let rasterTransform = CGAffineTransform(scaleX: renderScale, y: renderScale)
            let screenshotRect = prepared.geometry?.logicalSlotBounds.applying(rasterTransform)
                ?? CGRect(origin: .zero, size: canvasSize)
            let contentRect = prepared.geometry.map {
                prepared.framingAnalysis.contentRect.applying($0.localToLogicalCanvas).applying(rasterTransform)
            } ?? CGRect(origin: .zero, size: canvasSize)
            let layout = ScreenshotPresentationRenderLayout(
                canvasSize: canvasSize,
                subjectRect: screenshotRect,
                screenRect: screenshotRect,
                contentRect: contentRect,
                subjectScale: contentRect.width / max(logicalContentSize?.width ?? CGFloat(contentImage.width), 1),
                frame: .none
            )

            PresentationPerformanceMetrics.logEvent(
                "scene.render.output",
                context: "scene=\(scene.sceneID) image=\(image.width)x\(image.height) slot=\(PresentationPerformanceMetrics.size(screenshotRect.size))"
            )

            return ScreenshotPresentationRenderResult(image: image, layout: layout, pixelScale: renderScale,
                sceneGeometry: prepared.geometry, sceneMappingUnavailable: prepared.geometry == nil)
        }
    }

    static func framingAnalysis(
        contentSize: CGSize,
        scene: AppliedPresentationScene
    ) -> PresentationSceneFramingAnalysis? {
        guard validSettings(scene.screenshotSlotSettings), contentSize.width.isFinite, contentSize.height.isFinite,
              contentSize.width > 0, contentSize.height > 0,
              let metrics = sceneMetrics(for: scene),
              let slot = metrics.metadata.primaryScreenshotSlot else {
            return nil
        }

        let analysis = resolvedFraming(
            contentSize: contentSize,
            slotRect: metrics.primaryScreenshotRect,
            slot: slot,
            settings: scene.screenshotSlotSettings
        )
        return finiteAnalysis(analysis) ? analysis : nil
    }

    static func outputSize(for scene: AppliedPresentationScene) -> CGSize? {
        guard let metadata = try? PresentationSceneValidator
            .validate(svgText: scene.sanitizedSVGText, source: validationSource(for: scene))
            .metadata else {
            return nil
        }

        return metadata.canvas.size
    }

    private struct PreparedSVG {
        var metadata: PresentationSceneMetadata
        var svgText: String
        var primaryScreenshotRect: CGRect
        var framingAnalysis: PresentationSceneFramingAnalysis
        var geometry: PresentationSceneGeometry?
    }

    private struct SceneMetrics {
        var metadata: PresentationSceneMetadata
        var primaryScreenshotRect: CGRect
    }

    private static func preparedSVG(
        contentImage: CGImage,
        scene: AppliedPresentationScene,
        renderScale: CGFloat,
        logicalContentSize: CGSize?
    ) -> PreparedSVG? {
        PresentationPerformanceMetrics.measure(
            "scene.prepare",
            context: "scene=\(scene.sceneID) content=\(contentImage.width)x\(contentImage.height)",
            warnAfterMS: 20
        ) {
            guard let validated = try? PresentationSceneValidator.validate(
                svgText: scene.sanitizedSVGText,
                source: validationSource(for: scene)
            ),
                  let document = try? XMLDocument(
                    data: Data(validated.sanitizedSVGText.utf8),
                    options: [.nodeLoadExternalEntitiesNever, .nodePreserveWhitespace]
                  ),
                  let primarySlot = validated.metadata.primaryScreenshotSlot else {
                return nil
            }

            var primaryScreenshotRect: CGRect?
            var framingAnalysis: PresentationSceneFramingAnalysis?
            let geometry = PresentationSceneGeometryResolver.geometry(in: document, canvasSize: validated.metadata.canvas.size)
            replaceSlots(
                in: document.rootElement(),
                scene: scene,
                contentImage: contentImage,
                primarySlot: primarySlot,
                renderScale: renderScale,
                logicalContentSize: logicalContentSize,
                canvasSize: validated.metadata.canvas.size,
                geometry: geometry,
                primaryScreenshotRect: &primaryScreenshotRect,
                framingAnalysis: &framingAnalysis
            )

            guard let primaryScreenshotRect,
                  let framingAnalysis else {
                return nil
            }

            return PreparedSVG(
                metadata: validated.metadata,
                svgText: document.xmlString(options: []),
                primaryScreenshotRect: primaryScreenshotRect,
                framingAnalysis: framingAnalysis,
                geometry: geometry
            )
        }
    }

    private static func replaceSlots(
        in element: XMLElement?,
        scene: AppliedPresentationScene,
        contentImage: CGImage,
        primarySlot: PresentationSceneSlot,
        renderScale: CGFloat,
        logicalContentSize: CGSize?,
        canvasSize: CGSize,
        geometry: PresentationSceneGeometry?,
        primaryScreenshotRect: inout CGRect?,
        framingAnalysis: inout PresentationSceneFramingAnalysis?
    ) {
        guard let element else {
            return
        }

        if let slotID = element.attribute(forName: "data-sss-slot")?.stringValue {
            if slotID == PresentationSceneStore.primaryScreenshotSlotID,
               (element.localName ?? element.name ?? "").lowercased() == "image" {
                let slotRect = rect(from: element)
                let analysis = resolvedFraming(
                    contentSize: logicalContentSize ?? CGSize(width: contentImage.width, height: contentImage.height),
                    slotRect: slotRect,
                    slot: primarySlot,
                    settings: scene.screenshotSlotSettings
                )
                guard finiteAnalysis(analysis) else { return }
                guard let slotImage = slotImage(
                    contentImage: contentImage,
                    analysis: analysis,
                    renderScale: renderScale,
                    canvasSize: canvasSize,
                    geometry: geometry
                ),
                    let pngData = try? ImageExporter.pngData(for: slotImage) else {
                    return
                }

                setAttribute(named: "href", value: "data:image/png;base64,\(pngData.base64EncodedString())", on: element)
                setAttribute(named: "preserveAspectRatio", value: "none", on: element)
                primaryScreenshotRect = slotRect
                framingAnalysis = analysis
            } else if let textValue = scene.textSlotValues[slotID],
                      (element.localName ?? element.name ?? "").lowercased() == "text" {
                element.stringValue = textValue
            }
        }

        for child in element.children ?? [] {
            replaceSlots(
                in: child as? XMLElement,
                scene: scene,
                contentImage: contentImage,
                primarySlot: primarySlot,
                renderScale: renderScale,
                logicalContentSize: logicalContentSize,
                canvasSize: canvasSize,
                geometry: geometry,
                primaryScreenshotRect: &primaryScreenshotRect,
                framingAnalysis: &framingAnalysis
            )
        }
    }

    private static func setAttribute(named name: String, value: String, on element: XMLElement) {
        if let attribute = element.attribute(forName: name) {
            attribute.stringValue = value
        } else {
            element.addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode)
        }
    }

    private static func rect(from element: XMLElement) -> CGRect {
        func length(_ name: String, fallback: CGFloat) -> CGFloat {
            PresentationSceneGeometryResolver.length(element.attribute(forName: name)?.stringValue, default: fallback) ?? fallback
        }
        return CGRect(
            x: length("x", fallback: 0),
            y: length("y", fallback: 0),
            width: max(length("width", fallback: 1), 0.000001),
            height: max(length("height", fallback: 1), 0.000001)
        )
    }

    private static func sceneMetrics(for scene: AppliedPresentationScene) -> SceneMetrics? {
        guard let validated = try? PresentationSceneValidator.validate(
            svgText: scene.sanitizedSVGText,
            source: validationSource(for: scene)
        ),
              let document = try? XMLDocument(
                data: Data(validated.sanitizedSVGText.utf8),
                options: [.nodeLoadExternalEntitiesNever, .nodePreserveWhitespace]
              ),
              let primaryScreenshotRect = primaryScreenshotRect(in: document.rootElement()) else {
            return nil
        }

        return SceneMetrics(
            metadata: validated.metadata,
            primaryScreenshotRect: primaryScreenshotRect
        )
    }

    private static func primaryScreenshotRect(in element: XMLElement?) -> CGRect? {
        guard let element else {
            return nil
        }

        if element.attribute(forName: "data-sss-slot")?.stringValue == PresentationSceneStore.primaryScreenshotSlotID,
           (element.localName ?? element.name ?? "").lowercased() == "image" {
            return rect(from: element)
        }

        for child in element.children ?? [] {
            if let rect = primaryScreenshotRect(in: child as? XMLElement) {
                return rect
            }
        }

        return nil
    }

    private static func resolvedFraming(
        contentSize: CGSize,
        slotRect: CGRect,
        slot: PresentationSceneSlot,
        settings: PresentationSceneScreenshotSlotSettings
    ) -> PresentationSceneFramingAnalysis {
        let safeContentSize = CGSize(
            width: max(contentSize.width, 1),
            height: max(contentSize.height, 1)
        )
        let safeSlotRect = CGRect(
            x: slotRect.minX,
            y: slotRect.minY,
            width: max(slotRect.width, 1),
            height: max(slotRect.height, 1)
        )
        let autoFit = smartAutoFit(
            contentSize: safeContentSize,
            slotSize: safeSlotRect.size,
            maxAutoEnlargement: slot.effectiveMaxAutoEnlargement
        )

        let fit: PresentationSceneScreenshotFit
        if settings.framingPreset == .auto {
            fit = autoFit
        } else {
            fit = settings.fit
        }

        let alignment = settings.hasManualAdjustment
            ? settings.alignment
            : (settings.framingPreset == .auto ? .center : settings.framingPreset.defaultAlignment)
        let baseScale = baseScale(
            fit: fit,
            contentSize: safeContentSize,
            slotSize: safeSlotRect.size
        )
        let userScale = settings.hasManualAdjustment
            ? min(max(settings.scale, slot.effectiveMinScale), slot.effectiveMaxScale)
            : 1
        let resolvedScale = max(baseScale * userScale, 0.01)
        let contentDrawSize = CGSize(
            width: safeContentSize.width * resolvedScale,
            height: safeContentSize.height * resolvedScale
        )
        let offset = settings.hasManualAdjustment ? settings.offset : .zero
        let localOrigin = CGPoint(
            x: (safeSlotRect.width - contentDrawSize.width) * alignment.xFactor + offset.width,
            y: (safeSlotRect.height - contentDrawSize.height) * alignment.yFactor + offset.height
        )
        let contentRect = CGRect(
            x: safeSlotRect.minX + localOrigin.x,
            y: safeSlotRect.minY + localOrigin.y,
            width: contentDrawSize.width,
            height: contentDrawSize.height
        )
        let overlap = contentRect.intersection(safeSlotRect)
        let contentArea = max(contentRect.width * contentRect.height, 1)
        let visibleArea = overlap.isNull ? 0 : max(overlap.width, 0) * max(overlap.height, 0)
        let cropPercentage = min(max(1 - visibleArea / contentArea, 0), 1)
        let hasLetterbox = overlap.isNull
            || overlap.width < safeSlotRect.width - 0.5
            || overlap.height < safeSlotRect.height - 0.5

        return PresentationSceneFramingAnalysis(
            slotRect: safeSlotRect,
            contentRect: contentRect,
            fit: fit,
            alignment: alignment,
            cropPercentage: cropPercentage,
            enlargement: resolvedScale,
            hasLetterbox: hasLetterbox,
            hasManualAdjustment: settings.hasManualAdjustment
        )
    }

    private static func smartAutoFit(
        contentSize: CGSize,
        slotSize: CGSize,
        maxAutoEnlargement: CGFloat
    ) -> PresentationSceneScreenshotFit {
        let containScale = min(
            slotSize.width / max(contentSize.width, 1),
            slotSize.height / max(contentSize.height, 1)
        )

        if containScale > maxAutoEnlargement {
            return .actualSize
        }

        let contentAspect = contentSize.width / max(contentSize.height, 1)
        let slotAspect = slotSize.width / max(slotSize.height, 1)
        let aspectMismatch = max(contentAspect / max(slotAspect, 0.0001), slotAspect / max(contentAspect, 0.0001))
        let coverScale = max(
            slotSize.width / max(contentSize.width, 1),
            slotSize.height / max(contentSize.height, 1)
        )
        let scaledArea = max(contentSize.width * coverScale * contentSize.height * coverScale, 1)
        let cropPercentage = min(max(1 - (slotSize.width * slotSize.height / scaledArea), 0), 1)

        if aspectMismatch <= 1.12 && cropPercentage <= 0.12 && coverScale <= maxAutoEnlargement {
            return .cover
        }

        return .contain
    }

    private static func baseScale(
        fit: PresentationSceneScreenshotFit,
        contentSize: CGSize,
        slotSize: CGSize
    ) -> CGFloat {
        switch fit {
        case .contain:
            return min(
                slotSize.width / max(contentSize.width, 1),
                slotSize.height / max(contentSize.height, 1)
            )
        case .cover:
            return max(
                slotSize.width / max(contentSize.width, 1),
                slotSize.height / max(contentSize.height, 1)
            )
        case .actualSize:
            return 1
        }
    }

    private static func slotImage(
        contentImage: CGImage,
        analysis: PresentationSceneFramingAnalysis,
        renderScale: CGFloat,
        canvasSize: CGSize,
        geometry: PresentationSceneGeometry?
    ) -> CGImage? {
        let transform = geometry?.localToLogicalCanvas ?? .identity
        let desiredWidth = analysis.slotRect.width * hypot(transform.a, transform.b) * renderScale
        let desiredHeight = analysis.slotRect.height * hypot(transform.c, transform.d) * renderScale
        guard desiredWidth.isFinite, desiredHeight.isFinite, desiredWidth > 0, desiredHeight > 0 else { return nil }
        // A large local slot can be small after its SVG transform. Size its
        // bitmap for those transformed pixels and bound off-canvas oversampling.
        let maximumDimension = min(CGFloat(PresentationSceneValidator.maximumCanvasDimension), max(canvasSize.width, canvasSize.height) * renderScale * 2)
        let maximumPixels = min(CGFloat(PresentationSceneValidator.maximumCanvasPixels), canvasSize.width * canvasSize.height * renderScale * renderScale * 4)
        let rasterScale = min(1, maximumDimension / max(desiredWidth, desiredHeight), sqrt(maximumPixels / desiredWidth / desiredHeight))
        let width = max(Int((desiredWidth * rasterScale).rounded()), 1)
        let height = max(Int((desiredHeight * rasterScale).rounded()), 1)

        guard let context = SRGBBitmapContext.make(
            width: width,
            height: height
        ) else {
            return nil
        }

        let localContentRect = CGRect(
            x: (analysis.contentRect.minX - analysis.slotRect.minX) * CGFloat(width) / analysis.slotRect.width,
            y: (analysis.contentRect.minY - analysis.slotRect.minY) * CGFloat(height) / analysis.slotRect.height,
            width: analysis.contentRect.width * CGFloat(width) / analysis.slotRect.width,
            height: analysis.contentRect.height * CGFloat(height) / analysis.slotRect.height
        )
        let drawRect = CGRect(
            x: localContentRect.minX,
            y: CGFloat(height) - localContentRect.maxY,
            width: localContentRect.width,
            height: localContentRect.height
        )
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = analysis.enlargement > 1 ? .high : .medium
        context.draw(contentImage, in: drawRect)
        return context.makeImage()
    }

    private static func rasterize(svgText: String, canvasSize: CGSize, scale: CGFloat) -> CGImage? {
        let body: () -> CGImage? = {
            guard let svgData = svgText.data(using: .utf8),
                  let image = NSImage(data: svgData) else {
                return nil
            }

            let rasterSize = CGSize(width: canvasSize.width * scale, height: canvasSize.height * scale)
            let width = max(Int(rasterSize.width.rounded()), 1)
            let height = max(Int(rasterSize.height.rounded()), 1)
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .calibratedRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else {
                return nil
            }

            rep.size = rasterSize
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.clear.setFill()
            NSRect(origin: .zero, size: rasterSize).fill()
            image.draw(
                in: NSRect(origin: .zero, size: rasterSize),
                from: .zero,
                operation: .copy,
                fraction: 1
            )
            NSGraphicsContext.restoreGraphicsState()
            return rep.cgImage
        }

        return PresentationPerformanceMetrics.measure(
            "scene.rasterize",
            context: "canvas=\(PresentationPerformanceMetrics.size(canvasSize)) scale=\(String(format: "%.3f", Double(scale)))",
            warnAfterMS: 35,
            body
        )
    }

    private static func validationSource(for scene: AppliedPresentationScene) -> PresentationSceneSource {
        scene.sceneID.hasPrefix("builtin.") ? .bundled : .user
    }

    private static func validSettings(_ settings: PresentationSceneScreenshotSlotSettings) -> Bool {
        settings.scale.isFinite && settings.scale > 0 && settings.scale <= PresentationSceneValidator.maximumGeometryMagnitude
            && settings.offset.width.isFinite && settings.offset.height.isFinite
            && abs(settings.offset.width) <= PresentationSceneValidator.maximumGeometryMagnitude
            && abs(settings.offset.height) <= PresentationSceneValidator.maximumGeometryMagnitude
    }

    private static func finiteAnalysis(_ analysis: PresentationSceneFramingAnalysis) -> Bool {
        [analysis.contentRect.minX, analysis.contentRect.minY, analysis.contentRect.width,
         analysis.contentRect.height, analysis.cropPercentage, analysis.enlargement].allSatisfy(\.isFinite)
    }

}
