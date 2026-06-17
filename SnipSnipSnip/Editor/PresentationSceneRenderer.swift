import AppKit
import CoreGraphics
import Foundation

nonisolated enum PresentationSceneRenderer {
    static func renderWithLayout(
        contentImage: CGImage,
        scene: AppliedPresentationScene,
        maxPixelDimension: CGFloat? = nil
    ) -> ScreenshotPresentationRenderResult? {
        PresentationPerformanceMetrics.measure(
            "scene.render.total",
            context: "scene=\(scene.sceneID) version=\(scene.version) content=\(contentImage.width)x\(contentImage.height) cap=\(maxPixelDimension.map { String(Int($0.rounded())) } ?? "none")",
            warnAfterMS: 55
        ) {
            let originalCanvasSize = outputSize(for: scene) ?? CGSize(width: 1600, height: 900)
            let renderScale = maxPixelDimension.map {
                min($0 / max(max(originalCanvasSize.width, originalCanvasSize.height), 1), 1)
            } ?? 1
            guard let prepared = preparedSVG(
                contentImage: contentImage,
                scene: scene,
                renderScale: renderScale
            ),
                  let image = rasterize(svgText: prepared.svgText, canvasSize: prepared.metadata.canvas.size, scale: renderScale) else {
                return nil
            }

            let canvasSize = CGSize(
                width: prepared.metadata.canvas.size.width * renderScale,
                height: prepared.metadata.canvas.size.height * renderScale
            )
            let screenshotRect = CGRect(
                x: prepared.primaryScreenshotRect.minX * renderScale,
                y: prepared.primaryScreenshotRect.minY * renderScale,
                width: prepared.primaryScreenshotRect.width * renderScale,
                height: prepared.primaryScreenshotRect.height * renderScale
            ).integral
            let contentRect = CGRect(
                x: prepared.framingAnalysis.contentRect.minX * renderScale,
                y: prepared.framingAnalysis.contentRect.minY * renderScale,
                width: prepared.framingAnalysis.contentRect.width * renderScale,
                height: prepared.framingAnalysis.contentRect.height * renderScale
            ).integral
            let layout = ScreenshotPresentationRenderLayout(
                canvasSize: canvasSize,
                subjectRect: screenshotRect,
                screenRect: screenshotRect,
                contentRect: contentRect,
                subjectScale: contentRect.width / max(CGFloat(contentImage.width), 1),
                frame: .none
            )

            PresentationPerformanceMetrics.logEvent(
                "scene.render.output",
                context: "scene=\(scene.sceneID) image=\(image.width)x\(image.height) slot=\(PresentationPerformanceMetrics.size(screenshotRect.size))"
            )

            return ScreenshotPresentationRenderResult(image: image, layout: layout)
        }
    }

    static func framingAnalysis(
        contentSize: CGSize,
        scene: AppliedPresentationScene
    ) -> PresentationSceneFramingAnalysis? {
        guard let metrics = sceneMetrics(for: scene),
              let slot = metrics.metadata.primaryScreenshotSlot else {
            return nil
        }

        return resolvedFraming(
            contentSize: contentSize,
            slotRect: metrics.primaryScreenshotRect,
            slot: slot,
            settings: scene.screenshotSlotSettings
        )
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
    }

    private struct SceneMetrics {
        var metadata: PresentationSceneMetadata
        var primaryScreenshotRect: CGRect
    }

    private static func preparedSVG(
        contentImage: CGImage,
        scene: AppliedPresentationScene,
        renderScale: CGFloat
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
            replaceSlots(
                in: document.rootElement(),
                scene: scene,
                contentImage: contentImage,
                primarySlot: primarySlot,
                renderScale: renderScale,
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
                framingAnalysis: framingAnalysis
            )
        }
    }

    private static func replaceSlots(
        in element: XMLElement?,
        scene: AppliedPresentationScene,
        contentImage: CGImage,
        primarySlot: PresentationSceneSlot,
        renderScale: CGFloat,
        primaryScreenshotRect: inout CGRect?,
        framingAnalysis: inout PresentationSceneFramingAnalysis?
    ) {
        guard let element else {
            return
        }

        if let slotID = element.attribute(forName: "data-sss-slot")?.stringValue {
            if slotID == PresentationSceneStore.primaryScreenshotSlotID,
               (element.name ?? "").lowercased() == "image" {
                let slotRect = rect(from: element)
                let analysis = resolvedFraming(
                    contentSize: CGSize(width: contentImage.width, height: contentImage.height),
                    slotRect: slotRect,
                    slot: primarySlot,
                    settings: scene.screenshotSlotSettings
                )
                guard let slotImage = slotImage(
                    contentImage: contentImage,
                    analysis: analysis,
                    renderScale: renderScale
                ),
                    let pngData = try? ImageExporter.pngData(for: slotImage) else {
                    return
                }

                setAttribute(named: "href", value: "data:image/png;base64,\(pngData.base64EncodedString())", on: element)
                setAttribute(named: "preserveAspectRatio", value: "none", on: element)
                primaryScreenshotRect = slotRect
                framingAnalysis = analysis
            } else if let textValue = scene.textSlotValues[slotID],
                      (element.name ?? "").lowercased() == "text" {
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
        CGRect(
            x: CGFloat(Double(element.attribute(forName: "x")?.stringValue ?? "") ?? 0),
            y: CGFloat(Double(element.attribute(forName: "y")?.stringValue ?? "") ?? 0),
            width: max(CGFloat(Double(element.attribute(forName: "width")?.stringValue ?? "") ?? 1), 1),
            height: max(CGFloat(Double(element.attribute(forName: "height")?.stringValue ?? "") ?? 1), 1)
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
           (element.name ?? "").lowercased() == "image" {
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
        let hasLetterbox = contentDrawSize.width < safeSlotRect.width - 0.5
            || contentDrawSize.height < safeSlotRect.height - 0.5

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

        if aspectMismatch <= 1.12 && cropPercentage <= 0.12 {
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
        renderScale: CGFloat
    ) -> CGImage? {
        let width = max(Int((analysis.slotRect.width * renderScale).rounded()), 1)
        let height = max(Int((analysis.slotRect.height * renderScale).rounded()), 1)

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

        let localContentRect = CGRect(
            x: (analysis.contentRect.minX - analysis.slotRect.minX) * renderScale,
            y: (analysis.contentRect.minY - analysis.slotRect.minY) * renderScale,
            width: analysis.contentRect.width * renderScale,
            height: analysis.contentRect.height * renderScale
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

}
