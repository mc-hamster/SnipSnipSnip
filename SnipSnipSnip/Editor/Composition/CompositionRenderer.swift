import AppKit
import CoreGraphics
import CoreImage
import Foundation

nonisolated enum CompositionComparisonPhase: String, Codable, Sendable {
    case primary
    case secondary
}

nonisolated private extension CGPoint {
    func gscScaled(by scale: CGFloat) -> CGPoint {
        CGPoint(x: x * scale, y: y * scale)
    }
}

nonisolated private extension CGSize {
    func gscScaled(by scale: CGFloat) -> CGSize {
        CGSize(width: width * scale, height: height * scale)
    }
}

nonisolated private extension CGRect {
    func gscScaled(by scale: CGFloat) -> CGRect {
        CGRect(
            x: origin.x * scale,
            y: origin.y * scale,
            width: size.width * scale,
            height: size.height * scale
        )
    }
}

nonisolated struct CompositionRenderOptions: Equatable, Codable, Sendable {
    var comparisonPhase: CompositionComparisonPhase
    var appliesItemEdits: Bool
    var drawsCanvasAnnotations: Bool
    var maximumPixelDimension: Int
    var maximumPixelCount: Int
    /// Optional preview cap. Rendering scales directly into the capped bitmap,
    /// so an on-screen preview never allocates a full-resolution composite.
    var targetMaximumPixelDimension: Int?
    var uiMapOverlayOptions: UIMapOverlayOptions

    init(
        comparisonPhase: CompositionComparisonPhase = .primary,
        appliesItemEdits: Bool = true,
        drawsCanvasAnnotations: Bool = true,
        maximumPixelDimension: Int = 16_384,
        maximumPixelCount: Int = 134_217_728,
        targetMaximumPixelDimension: Int? = nil,
        uiMapOverlayOptions: UIMapOverlayOptions = UIMapOverlayOptions()
    ) {
        self.comparisonPhase = comparisonPhase
        self.appliesItemEdits = appliesItemEdits
        self.drawsCanvasAnnotations = drawsCanvasAnnotations
        self.maximumPixelDimension = maximumPixelDimension
        self.maximumPixelCount = maximumPixelCount
        self.targetMaximumPixelDimension = targetMaximumPixelDimension
        self.uiMapOverlayOptions = uiMapOverlayOptions
    }
}

nonisolated struct CompositionRenderResult: @unchecked Sendable {
    let image: CGImage
    let layout: CompositionRenderLayout
    let registrationOutcome: CompositionRegistrationOutcome?

    init(
        image: CGImage,
        layout: CompositionRenderLayout,
        registrationOutcome: CompositionRegistrationOutcome? = nil
    ) {
        self.image = image
        self.layout = layout
        self.registrationOutcome = registrationOutcome
    }
}

nonisolated enum CompositionRegistrationOutcome: Equatable, Sendable {
    case disabled
    case manual(offset: CGSize)
    case automaticSucceeded(offset: CGSize, confidence: CGFloat)
    case automaticFailed
}

nonisolated enum CompositionRenderError: LocalizedError, Equatable {
    case layout(CompositionLayoutError)
    case missingAsset(assetID: UUID)
    case failedToRenderItem(itemID: UUID)
    case invalidCanvasSize
    case canvasTooLarge
    case failedToCreateCanvas
    case failedToRenderCanvasAnnotations

    var errorDescription: String? {
        switch self {
        case .layout(let error):
            return error.errorDescription
        case .missingAsset(let assetID):
            return "The composition is missing image pixels for \(assetID.uuidString)."
        case .failedToRenderItem(let itemID):
            return "An edited image could not be rendered for composition item \(itemID.uuidString)."
        case .invalidCanvasSize:
            return "The composition canvas has invalid dimensions."
        case .canvasTooLarge:
            return "The composition canvas is too large to render safely."
        case .failedToCreateCanvas:
            return "The composition canvas could not be created."
        case .failedToRenderCanvasAnnotations:
            return "The whole-canvas annotations could not be rendered."
        }
    }
}

/// Renders the deterministic layout produced by `CompositionLayoutEngine`.
///
/// The raw-asset overload applies item crop/annotation state first. The
/// rendered-item overload accepts images keyed by composition item ID, allowing
/// the editor/controller to provide its own already-rendered pixels without
/// duplicating any layout or composition code.
nonisolated enum CompositionRenderer {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func render(
        composition: CompositionSnapshot,
        assets: [UUID: CompositionAsset],
        options: CompositionRenderOptions = CompositionRenderOptions()
    ) throws -> CompositionRenderResult {
        var renderedItemImages: [UUID: CGImage] = [:]

        for item in composition.items where item.isIncluded {
            guard let asset = assets[item.assetID] else {
                throw CompositionRenderError.missingAsset(assetID: item.assetID)
            }

            if !options.appliesItemEdits || item.editState.isPixelIdentity(for: asset.image) {
                renderedItemImages[item.id] = asset.image
                continue
            }

            let cropRect = item.editState.cropRect
                ?? CGRect(x: 0, y: 0, width: asset.image.width, height: asset.image.height)
            let snapshot = EditorSnapshot(
                cropRect: cropRect,
                annotations: item.editState.annotations,
                selectedAnnotationIDs: [],
                nextCalloutNumber: item.editState.nextCalloutNumber,
                presentation: .plain,
                pinnedUIMapElementIDs: item.editState.pinnedUIMapElementIDs
            )
            let pinnedUIMapElements = item.editState.pinnedUIMapElementIDs.compactMap {
                asset.uiMap?.element(matching: $0)
            }
            guard let rendered = EditorRenderer.render(
                baseImage: asset.image,
                snapshot: snapshot,
                pinnedUIMapElements: pinnedUIMapElements,
                uiMapOverlayOptions: options.uiMapOverlayOptions
            ) else {
                throw CompositionRenderError.failedToRenderItem(itemID: item.id)
            }
            renderedItemImages[item.id] = rendered
        }

        return try render(
            composition: composition,
            renderedItemImages: renderedItemImages,
            options: options
        )
    }

    static func render(
        composition: CompositionSnapshot,
        renderedItemImages: [UUID: CGImage],
        options: CompositionRenderOptions = CompositionRenderOptions()
    ) throws -> CompositionRenderResult {
        let itemSizes = renderedItemImages.mapValues {
            CGSize(width: $0.width, height: $0.height)
        }
        let layout: CompositionRenderLayout
        do {
            layout = try CompositionLayoutEngine.layout(
                composition: composition,
                renderedItemSizes: itemSizes
            )
        } catch let error as CompositionLayoutError {
            throw CompositionRenderError.layout(error)
        }

        return try render(
            composition: composition,
            renderedItemImages: renderedItemImages,
            layout: layout,
            options: options
        )
    }

    /// Resolves geometry from immutable source descriptors first, then asks
    /// the repository for only the visible pixels each destination cell can
    /// display. Full-resolution export intentionally uses the overload above.
    static func renderPreview(
        composition: CompositionSnapshot,
        assetRepository: CompositionAssetRepository,
        options: CompositionRenderOptions
    ) throws -> CompositionRenderResult {
        let layout: CompositionRenderLayout
        do {
            if options.appliesItemEdits {
                layout = try CompositionLayoutEngine.layout(
                    composition: composition,
                    assetDescriptors: assetRepository.descriptors
                )
            } else {
                let descriptors = assetRepository.descriptors
                var itemSizes: [UUID: CGSize] = [:]
                for item in composition.items where item.isIncluded {
                    guard let descriptor = descriptors[item.assetID] else {
                        throw CompositionLayoutError.missingAssetDescriptor(
                            assetID: item.assetID
                        )
                    }
                    itemSizes[item.id] = descriptor.pixelSize
                }
                layout = try CompositionLayoutEngine.layout(
                    composition: composition,
                    renderedItemSizes: itemSizes
                )
            }
        } catch let error as CompositionLayoutError {
            throw CompositionRenderError.layout(error)
        }

        let renderScale = previewRenderScale(for: layout, options: options)
        try validate(layout: layout, renderScale: renderScale, options: options)
        let itemsByID = Dictionary(
            uniqueKeysWithValues: composition.items.map { ($0.id, $0) }
        )
        var renderedItemImages: [UUID: CGImage] = [:]

        // Compare retains non-A/B items in the document. Since they have no
        // placement in this layout, they must not be decoded for a preview.
        for placement in layout.items {
            guard renderedItemImages[placement.itemID] == nil,
                  let item = itemsByID[placement.itemID] else {
                continue
            }
            let targetSize = CGSize(
                width: max(placement.imageDrawRect.width * renderScale, 1),
                height: max(placement.imageDrawRect.height * renderScale, 1)
            )
            do {
                renderedItemImages[item.id] = try autoreleasepool {
                    try assetRepository.renderedPreview(
                        for: item,
                        targetRenderedPixelSize: targetSize,
                        appliesItemEdits: options.appliesItemEdits,
                        uiMapOverlayOptions: options.uiMapOverlayOptions
                    )
                }
            } catch let error as CompositionAssetRepositoryError {
                switch error {
                case .missingAsset(let assetID):
                    throw CompositionRenderError.missingAsset(assetID: assetID)
                case .invalidImage, .descriptorMismatch:
                    throw CompositionRenderError.failedToRenderItem(
                        itemID: item.id
                    )
                }
            }
        }

        return try render(
            composition: composition,
            renderedItemImages: renderedItemImages,
            layout: layout,
            options: options
        )
    }

    private static func render(
        composition: CompositionSnapshot,
        renderedItemImages: [UUID: CGImage],
        layout: CompositionRenderLayout,
        options: CompositionRenderOptions
    ) throws -> CompositionRenderResult {
        let renderScale = previewRenderScale(for: layout, options: options)
        try validate(layout: layout, renderScale: renderScale, options: options)

        if renderScale == 1, let identityImage = pixelIdentityImage(
            composition: composition,
            layout: layout,
            renderedItemImages: renderedItemImages,
            options: options
        ) {
            return CompositionRenderResult(image: identityImage, layout: layout)
        }

        let width = max(Int((layout.canvasSize.width * renderScale).rounded(.up)), 1)
        let height = max(Int((layout.canvasSize.height * renderScale).rounded(.up)), 1)
        guard let context = makeContext(width: width, height: height) else {
            throw CompositionRenderError.failedToCreateCanvas
        }
        let outputCanvasRect = CGRect(x: 0, y: 0, width: width, height: height)
        let sourceCanvasRect = CGRect(origin: .zero, size: layout.canvasSize)
        context.clear(outputCanvasRect)
        context.interpolationQuality = .high
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        if renderScale != 1 {
            context.scaleBy(x: renderScale, y: renderScale)
        }

        let appearance = composition.canvas.appearance
        drawCanvasFill(appearance.fill, in: context, canvasRect: sourceCanvasRect)
        drawTitle(
            composition.canvas.title,
            rect: layout.titleRect,
            appearance: appearance,
            in: context,
            canvasHeight: layout.canvasSize.height
        )
        drawConnectors(
            layout.connectors,
            appearance: appearance,
            in: context,
            canvasHeight: layout.canvasSize.height
        )

        let itemsByID = Dictionary(uniqueKeysWithValues: composition.items.map { ($0.id, $0) })
        let registrationOutcome: CompositionRegistrationOutcome?
        if let comparison = layout.comparison,
           comparison.mode != .sideBySide {
            registrationOutcome = try drawComparison(
                comparison,
                layout: layout,
                composition: composition,
                itemsByID: itemsByID,
                images: renderedItemImages,
                options: options,
                renderScale: renderScale,
                in: context,
                canvasHeight: layout.canvasSize.height
            )
        } else {
            registrationOutcome = nil
            for placement in layout.items.sorted(by: { $0.zIndex < $1.zIndex }) {
                guard let item = itemsByID[placement.itemID],
                      let image = renderedItemImages[placement.itemID] else {
                    throw CompositionRenderError.missingAsset(assetID: placement.assetID)
                }
                drawItem(
                    item,
                    image: image,
                    placement: placement,
                    appearance: appearance,
                    in: context,
                    canvasHeight: layout.canvasSize.height
                )
            }
            if let comparison = layout.comparison {
                drawComparisonLabels(
                    comparison,
                    layout: layout,
                    settings: composition.comparison,
                    in: context,
                    canvasHeight: layout.canvasSize.height
                )
            }
        }

        guard let composedImage = context.makeImage() else {
            throw CompositionRenderError.failedToCreateCanvas
        }

        let finalImage: CGImage
        if options.drawsCanvasAnnotations, !composition.canvas.annotations.isEmpty {
            let resolvedAnnotations = resolvedCanvasAnnotations(
                composition: composition,
                layout: layout
            )
            let scaledAnnotations = renderScale == 1
                ? resolvedAnnotations
                : resolvedAnnotations.map {
                    scaledCanvasAnnotation(
                        $0,
                        sourceCanvasSize: layout.canvasSize,
                        renderScale: renderScale
                    )
                }
            let canvasSnapshot = EditorSnapshot(
                cropRect: outputCanvasRect,
                annotations: scaledAnnotations,
                selectedAnnotationIDs: [],
                nextCalloutNumber: composition.canvas.nextCalloutNumber,
                presentation: .plain,
                pinnedUIMapElementIDs: []
            )
            guard let annotated = EditorRenderer.render(
                baseImage: composedImage,
                snapshot: canvasSnapshot
            ) else {
                throw CompositionRenderError.failedToRenderCanvasAnnotations
            }
            finalImage = annotated
        } else {
            finalImage = composedImage
        }

        return CompositionRenderResult(
            image: finalImage,
            layout: renderScale == 1 ? layout : scaledLayout(layout, by: renderScale),
            registrationOutcome: registrationOutcome
        )
    }

    static func resolvedCanvasAnnotations(
        composition: CompositionSnapshot,
        layout: CompositionRenderLayout
    ) -> [Annotation] {
        composition.canvas.annotations.compactMap { annotation in
            guard let anchors = composition.canvas.annotationAnchors[annotation.id] else {
                return annotation
            }
            let referencedItemIDs = [anchors.primary, anchors.secondary]
                .compactMap { anchor -> UUID? in
                    guard let anchor,
                          case .itemNormalized(let itemID, _) = anchor.target else {
                        return nil
                    }
                    return itemID
                }
            let visibleItemIDs = Set(layout.items.map(\.itemID))
            guard referencedItemIDs.allSatisfy(visibleItemIDs.contains) else {
                // An anchor that is still attached to an excluded or unused
                // panel is intentionally hidden. Explicitly detached and
                // canvas-pinned annotations remain visible.
                return nil
            }
            let primary = resolvedCanvasPoint(
                for: anchors.primary,
                layout: layout
            )
            if let secondaryAnchor = anchors.secondary {
                let secondary = resolvedCanvasPoint(
                    for: secondaryAnchor,
                    layout: layout
                )
                var copy = annotation
                switch annotation.kind {
                case .line:
                    copy.kind = .line(LineShape(start: primary, end: secondary))
                case .arrow(var shape):
                    shape.start = primary
                    shape.end = secondary
                    copy.kind = .arrow(shape)
                case .measurement:
                    copy.kind = .measurement(
                        MeasurementShape(start: primary, end: secondary)
                    )
                default:
                    copy = annotation.translated(
                        by: CGSize(
                            width: primary.x - anchors.primary.lastCanvasPoint.x,
                            height: primary.y - anchors.primary.lastCanvasPoint.y
                        )
                    )
                }
                return copy
            }
            return annotation.translated(
                by: CGSize(
                    width: primary.x - anchors.primary.lastCanvasPoint.x,
                    height: primary.y - anchors.primary.lastCanvasPoint.y
                )
            )
        }
    }

    static func resolvedCanvasPoint(
        for anchor: CompositionAnnotationAnchor,
        layout: CompositionRenderLayout
    ) -> CGPoint {
        switch anchor.target {
        case .canvasNormalized(let point):
            return CGPoint(
                x: point.x * layout.canvasSize.width,
                y: point.y * layout.canvasSize.height
            )
        case .itemNormalized(let itemID, let point):
            guard let item = layout.itemLayout(for: itemID) else {
                return anchor.lastCanvasPoint
            }
            return CGPoint(
                x: item.imageDrawRect.minX + point.x * item.imageDrawRect.width,
                y: item.imageDrawRect.minY + point.y * item.imageDrawRect.height
            )
        case .detachedCanvas(let point):
            return point
        }
    }

    // MARK: - Validation and identity

    private static func previewRenderScale(
        for layout: CompositionRenderLayout,
        options: CompositionRenderOptions
    ) -> CGFloat {
        guard let target = options.targetMaximumPixelDimension, target > 0 else {
            return 1
        }
        let longestSide = max(layout.canvasSize.width, layout.canvasSize.height)
        guard longestSide.isFinite, longestSide > CGFloat(target) else {
            return 1
        }
        return CGFloat(target) / longestSide
    }

    private static func validate(
        layout: CompositionRenderLayout,
        renderScale: CGFloat,
        options: CompositionRenderOptions
    ) throws {
        let width = layout.canvasSize.width
        let height = layout.canvasSize.height
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            throw CompositionRenderError.invalidCanvasSize
        }
        let renderedWidth = width * renderScale
        let renderedHeight = height * renderScale
        let maximumDimension = max(options.maximumPixelDimension, 1)
        let maximumPixelCount = max(options.maximumPixelCount, 1)
        guard renderedWidth <= CGFloat(maximumDimension),
              renderedHeight <= CGFloat(maximumDimension),
              renderedWidth <= CGFloat(Int.max) / renderedHeight,
              Int(renderedWidth.rounded(.up)) * Int(renderedHeight.rounded(.up)) <= maximumPixelCount else {
            throw CompositionRenderError.canvasTooLarge
        }
    }

    private static func scaledCanvasAnnotation(
        _ annotation: Annotation,
        sourceCanvasSize: CGSize,
        renderScale: CGFloat
    ) -> Annotation {
        let sourceBounds = CGRect(origin: .zero, size: sourceCanvasSize)
        let outputBounds = CGRect(
            origin: .zero,
            size: CGSize(
                width: sourceCanvasSize.width * renderScale,
                height: sourceCanvasSize.height * renderScale
            )
        )
        var scaled = annotation.scaled(from: sourceBounds, to: outputBounds)
        var style = scaled.style.scaledForDisplay(by: renderScale)
        style.effectRadius *= renderScale
        scaled.style = style
        if case .arrow(var shape) = scaled.kind {
            shape.labelFontSize *= renderScale
            scaled.kind = .arrow(shape)
        }
        return scaled
    }

    private static func scaledLayout(
        _ layout: CompositionRenderLayout,
        by scale: CGFloat
    ) -> CompositionRenderLayout {
        CompositionRenderLayout(
            requestedMode: layout.requestedMode,
            resolvedMode: layout.resolvedMode,
            canvasSize: layout.canvasSize.gscScaled(by: scale),
            contentRect: layout.contentRect.gscScaled(by: scale),
            titleRect: layout.titleRect?.gscScaled(by: scale),
            items: layout.items.map { item in
                CompositionItemRenderLayout(
                    itemID: item.itemID,
                    assetID: item.assetID,
                    sourceSize: item.sourceSize,
                    frameRect: item.frameRect.gscScaled(by: scale),
                    imageClipRect: item.imageClipRect.gscScaled(by: scale),
                    imageDrawRect: item.imageDrawRect.gscScaled(by: scale),
                    captionRect: item.captionRect?.gscScaled(by: scale),
                    badgeRect: item.badgeRect?.gscScaled(by: scale),
                    opacity: item.opacity,
                    zIndex: item.zIndex,
                    role: item.role
                )
            },
            connectors: layout.connectors.map {
                CompositionConnectorRenderLayout(
                    start: $0.start.gscScaled(by: scale),
                    end: $0.end.gscScaled(by: scale),
                    style: $0.style
                )
            },
            comparison: layout.comparison.map {
                CompositionComparisonRenderLayout(
                    mode: $0.mode,
                    axis: $0.axis,
                    primaryItemID: $0.primaryItemID,
                    secondaryItemID: $0.secondaryItemID,
                    sharedFrame: $0.sharedFrame?.gscScaled(by: scale),
                    dividerRect: $0.dividerRect?.gscScaled(by: scale),
                    wipePosition: $0.wipePosition
                )
            },
            omittedItemIDs: layout.omittedItemIDs
        )
    }

    private static func pixelIdentityImage(
        composition: CompositionSnapshot,
        layout: CompositionRenderLayout,
        renderedItemImages: [UUID: CGImage],
        options: CompositionRenderOptions
    ) -> CGImage? {
        guard composition.layout.mode == .auto,
              composition.canvas.appearance == .pixelPreserving,
              (!options.drawsCanvasAnnotations || composition.canvas.annotations.isEmpty),
              layout.items.count == 1,
              layout.connectors.isEmpty,
              layout.comparison == nil,
              let placement = layout.items.first,
              placement.captionRect == nil,
              placement.badgeRect == nil,
              placement.opacity == 1,
              placement.frameRect == layout.canvasRect,
              placement.imageClipRect == layout.canvasRect,
              placement.imageDrawRect == layout.canvasRect,
              let image = renderedItemImages[placement.itemID],
              image.width == Int(layout.canvasSize.width),
              image.height == Int(layout.canvasSize.height) else {
            return nil
        }
        return image
    }

    // MARK: - Items and cards

    private static func drawItem(
        _ item: CompositionItem,
        image: CGImage,
        placement: CompositionItemRenderLayout,
        appearance: CompositionCanvasAppearance,
        in context: CGContext,
        canvasHeight: CGFloat
    ) {
        drawCardBase(placement, appearance: appearance, in: context, canvasHeight: canvasHeight)
        drawImage(
            image,
            placement: placement,
            opacity: placement.opacity,
            cornerRadius: appearance.itemCornerRadius,
            in: context,
            canvasHeight: canvasHeight
        )
        drawCaption(
            item.caption,
            placement: placement,
            appearance: appearance,
            in: context
        )
        drawStepBadge(
            placement,
            appearance: appearance,
            in: context
        )
        drawCardBorder(placement, appearance: appearance, in: context, canvasHeight: canvasHeight)
    }

    private static func drawCardBase(
        _ placement: CompositionItemRenderLayout,
        appearance: CompositionCanvasAppearance,
        in context: CGContext,
        canvasHeight: CGFloat
    ) {
        let quartzFrame = quartzRect(placement.frameRect, canvasHeight: canvasHeight)
        let radius = min(max(appearance.itemCornerRadius, 0), min(quartzFrame.width, quartzFrame.height) / 2)
        let path = CGPath(
            roundedRect: quartzFrame,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )

        context.saveGState()
        if appearance.itemShadowBlur > 0, appearance.itemShadowColor.alpha > 0 {
            context.setShadow(
                offset: CGSize(
                    width: appearance.itemShadowOffset.width,
                    height: -appearance.itemShadowOffset.height
                ),
                blur: appearance.itemShadowBlur,
                color: appearance.itemShadowColor.cgColor
            )
        }
        context.setFillColor(appearance.itemFill.cgColor)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()

    }

    private static func drawCardBorder(
        _ placement: CompositionItemRenderLayout,
        appearance: CompositionCanvasAppearance,
        in context: CGContext,
        canvasHeight: CGFloat
    ) {
        guard appearance.itemBorderWidth > 0, appearance.itemBorderColor.alpha > 0 else {
            return
        }
        let halfWidth = appearance.itemBorderWidth / 2
        let rect = quartzRect(placement.frameRect, canvasHeight: canvasHeight)
            .insetBy(dx: halfWidth, dy: halfWidth)
        let radius = min(
            max(appearance.itemCornerRadius - halfWidth, 0),
            min(rect.width, rect.height) / 2
        )
        context.saveGState()
        context.setStrokeColor(appearance.itemBorderColor.cgColor)
        context.setLineWidth(appearance.itemBorderWidth)
        context.addPath(
            CGPath(
                roundedRect: rect,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            )
        )
        context.strokePath()
        context.restoreGState()
    }

    private static func drawImage(
        _ image: CGImage,
        placement: CompositionItemRenderLayout,
        opacity: CGFloat,
        clipOverride: CGRect? = nil,
        blendMode: CGBlendMode = .normal,
        cornerRadius: CGFloat = 0,
        in context: CGContext,
        canvasHeight: CGFloat
    ) {
        let clip = clipOverride.map { placement.imageClipRect.intersection($0) }
            ?? placement.imageClipRect
        guard !clip.isNull, clip.width > 0, clip.height > 0 else { return }

        context.saveGState()
        let clipRect = quartzRect(clip, canvasHeight: canvasHeight)
        let quartzFrame = quartzRect(placement.frameRect, canvasHeight: canvasHeight)
        let radius = min(max(cornerRadius, 0), min(quartzFrame.width, quartzFrame.height) / 2)
        if radius > 0 {
            context.addPath(
                CGPath(
                    roundedRect: quartzFrame,
                    cornerWidth: radius,
                    cornerHeight: radius,
                    transform: nil
                )
            )
            context.clip()
        }
        context.clip(to: clipRect)
        context.setAlpha(opacity.clampedCompositionUnit)
        context.setBlendMode(blendMode)
        context.draw(image, in: quartzRect(placement.imageDrawRect, canvasHeight: canvasHeight))
        context.restoreGState()
    }

    private static func drawCaption(
        _ caption: String?,
        placement: CompositionItemRenderLayout,
        appearance: CompositionCanvasAppearance,
        in context: CGContext
    ) {
        guard let caption,
              !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let captionRect = placement.captionRect else {
            return
        }
        if appearance.captionBackgroundColor.alpha > 0 {
            context.saveGState()
            context.setFillColor(appearance.captionBackgroundColor.cgColor)
            context.fill(
                quartzRect(
                    captionRect,
                    canvasHeight: CGFloat(context.height)
                )
            )
            context.restoreGState()
        }
        let textRect = CGRect(
            x: captionRect.minX + appearance.captionInsets.leading,
            y: captionRect.minY + appearance.captionInsets.top,
            width: max(
                1,
                captionRect.width - appearance.captionInsets.leading - appearance.captionInsets.trailing
            ),
            height: max(
                1,
                captionRect.height - appearance.captionInsets.top - appearance.captionInsets.bottom
            )
        )
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = appearance.captionTextAlignment.nsTextAlignment
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: compositionFont(
                name: appearance.captionFontName,
                size: max(appearance.captionFontSize, 1),
                weight: appearance.captionFontWeight
            ),
            .foregroundColor: appearance.captionColor.nsColor,
            .paragraphStyle: paragraph,
        ]

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        (caption as NSString).draw(
            with: textRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawTitle(
        _ title: String,
        rect: CGRect?,
        appearance: CompositionCanvasAppearance,
        in context: CGContext,
        canvasHeight: CGFloat
    ) {
        guard let rect,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        if appearance.titleBackgroundColor.alpha > 0 {
            context.saveGState()
            context.setFillColor(appearance.titleBackgroundColor.cgColor)
            context.fill(quartzRect(rect, canvasHeight: canvasHeight))
            context.restoreGState()
        }
        let textRect = CGRect(
            x: rect.minX + appearance.titleInsets.leading,
            y: rect.minY + appearance.titleInsets.top,
            width: max(
                rect.width - appearance.titleInsets.leading - appearance.titleInsets.trailing,
                1
            ),
            height: max(
                rect.height - appearance.titleInsets.top - appearance.titleInsets.bottom,
                1
            )
        )
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = appearance.titleTextAlignment.nsTextAlignment
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: compositionFont(
                name: appearance.titleFontName,
                size: max(appearance.titleFontSize, 1),
                weight: appearance.titleFontWeight
            ),
            .foregroundColor: appearance.titleColor.nsColor,
            .paragraphStyle: paragraph,
        ]
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        (title as NSString).draw(
            with: textRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func compositionFont(
        name: String?,
        size: CGFloat,
        weight: CompositionTextWeight
    ) -> NSFont {
        if let name,
           !name.isEmpty,
           let font = NSFont(name: name, size: size) {
            return font
        }
        return NSFont.systemFont(ofSize: size, weight: weight.nsFontWeight)
    }

    private static func drawStepBadge(
        _ placement: CompositionItemRenderLayout,
        appearance: CompositionCanvasAppearance,
        in context: CGContext
    ) {
        guard case .step(_, let label) = placement.role,
              let label,
              let badgeRect = placement.badgeRect else {
            return
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let badgePath = NSBezierPath(ovalIn: badgeRect)
        appearance.stepBadgeFill.nsColor.setFill()
        badgePath.fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let fontSize = min(max(badgeRect.height * 0.48, 9), 18)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: appearance.stepBadgeForeground.nsColor,
            .paragraphStyle: paragraph,
        ]
        let textRect = badgeRect.offsetBy(dx: 0, dy: (badgeRect.height - fontSize * 1.25) / 2)
        (label as NSString).draw(in: textRect, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Comparison

    private static func drawComparison(
        _ comparison: CompositionComparisonRenderLayout,
        layout: CompositionRenderLayout,
        composition: CompositionSnapshot,
        itemsByID: [UUID: CompositionItem],
        images: [UUID: CGImage],
        options: CompositionRenderOptions,
        renderScale: CGFloat,
        in context: CGContext,
        canvasHeight: CGFloat
    ) throws -> CompositionRegistrationOutcome {
        guard let primaryPlacement = layout.itemLayout(for: comparison.primaryItemID),
              let secondaryPlacement = layout.itemLayout(for: comparison.secondaryItemID),
              let primaryItem = itemsByID[comparison.primaryItemID],
              let secondaryItem = itemsByID[comparison.secondaryItemID],
              let primaryImage = images[comparison.primaryItemID],
              let secondaryImage = images[comparison.secondaryItemID] else {
            throw CompositionRenderError.failedToCreateCanvas
        }

        let appearance = composition.canvas.appearance
        let registeredSecondaryPlacement: CompositionItemRenderLayout
        let registrationOutcome: CompositionRegistrationOutcome
        if comparison.mode == .sideBySide {
            registeredSecondaryPlacement = secondaryPlacement
            registrationOutcome = .disabled
        } else {
            let offset: CGSize
            switch composition.comparison.registrationMode {
            case .disabled:
                offset = .zero
                registrationOutcome = .disabled
            case .manual:
                offset = composition.comparison.manualRegistrationOffset.isFiniteCompositionSize
                    ? composition.comparison.manualRegistrationOffset
                    : .zero
                registrationOutcome = .manual(offset: offset)
            case .automatic:
                if let result = automaticRegistration(
                    primaryImage: primaryImage,
                    secondaryImage: secondaryImage,
                    destinationSize: primaryPlacement.imageClipRect.size,
                    sensitivity: composition.comparison.registrationSensitivity
                ) {
                    offset = result.offset
                    registrationOutcome = .automaticSucceeded(
                        offset: result.offset,
                        confidence: result.confidence
                    )
                } else {
                    offset = .zero
                    registrationOutcome = .automaticFailed
                }
            }
            registeredSecondaryPlacement = secondaryPlacement.offsettingImage(by: offset)
        }
        drawCardBase(primaryPlacement, appearance: appearance, in: context, canvasHeight: canvasHeight)

        switch comparison.mode {
        case .sideBySide:
            break
        case .overlay:
            drawImage(
                primaryImage,
                placement: primaryPlacement,
                opacity: primaryPlacement.opacity,
                cornerRadius: appearance.itemCornerRadius,
                in: context,
                canvasHeight: canvasHeight
            )
            drawImage(
                secondaryImage,
                placement: registeredSecondaryPlacement,
                opacity: registeredSecondaryPlacement.opacity * composition.comparison.overlayOpacity.clampedCompositionUnit,
                cornerRadius: appearance.itemCornerRadius,
                in: context,
                canvasHeight: canvasHeight
            )
        case .wipe:
            drawImage(
                primaryImage,
                placement: primaryPlacement,
                opacity: primaryPlacement.opacity,
                cornerRadius: appearance.itemCornerRadius,
                in: context,
                canvasHeight: canvasHeight
            )
            let position = composition.comparison.wipePosition.clampedCompositionUnit
            let shared = comparison.sharedFrame ?? registeredSecondaryPlacement.imageClipRect
            let reveal: CGRect
            switch comparison.axis {
            case .horizontal:
                reveal = CGRect(
                    x: shared.minX,
                    y: shared.minY,
                    width: shared.width * position,
                    height: shared.height
                )
            case .vertical:
                reveal = CGRect(
                    x: shared.minX,
                    y: shared.minY,
                    width: shared.width,
                    height: shared.height * position
                )
            }
            drawImage(
                secondaryImage,
                placement: registeredSecondaryPlacement,
                opacity: registeredSecondaryPlacement.opacity,
                clipOverride: reveal,
                cornerRadius: appearance.itemCornerRadius,
                in: context,
                canvasHeight: canvasHeight
            )
            if let dividerRect = comparison.dividerRect {
                context.saveGState()
                context.setFillColor(appearance.comparisonDividerColor.cgColor)
                context.fill(quartzRect(dividerRect, canvasHeight: canvasHeight))
                context.restoreGState()
            }
        case .blink:
            let showsSecondary = options.comparisonPhase == .secondary
            drawImage(
                showsSecondary ? secondaryImage : primaryImage,
                placement: showsSecondary ? registeredSecondaryPlacement : primaryPlacement,
                opacity: showsSecondary ? registeredSecondaryPlacement.opacity : primaryPlacement.opacity,
                cornerRadius: appearance.itemCornerRadius,
                in: context,
                canvasHeight: canvasHeight
            )
        case .difference, .changeHighlight:
            guard let differenceImage = differenceImage(
                primaryImage: primaryImage,
                primaryPlacement: primaryPlacement,
                secondaryImage: secondaryImage,
                secondaryPlacement: registeredSecondaryPlacement,
                highlightColor: comparison.mode == .changeHighlight
                    ? composition.comparison.changeHighlightColor
                    : nil,
                threshold: composition.comparison.changeThreshold,
                cueStyle: composition.comparison.differenceCueStyle,
                renderScale: renderScale
            ) else {
                throw CompositionRenderError.failedToCreateCanvas
            }
            if comparison.mode == .changeHighlight {
                drawImage(
                    primaryImage,
                    placement: primaryPlacement,
                    opacity: primaryPlacement.opacity
                        * composition.comparison.unchangedContentOpacity.clampedCompositionUnit,
                    cornerRadius: appearance.itemCornerRadius,
                    in: context,
                    canvasHeight: canvasHeight
                )
                context.saveGState()
                context.setBlendMode(.screen)
                context.setAlpha(composition.comparison.differenceIntensity.clampedCompositionUnit)
                context.draw(
                    differenceImage,
                    in: quartzRect(primaryPlacement.imageClipRect, canvasHeight: canvasHeight)
                )
                context.restoreGState()
            } else {
                drawImage(
                    primaryImage,
                    placement: primaryPlacement,
                    opacity: primaryPlacement.opacity
                        * composition.comparison.unchangedContentOpacity.clampedCompositionUnit,
                    cornerRadius: appearance.itemCornerRadius,
                    in: context,
                    canvasHeight: canvasHeight
                )
                context.saveGState()
                context.setAlpha(composition.comparison.differenceIntensity.clampedCompositionUnit)
                context.draw(
                    differenceImage,
                    in: quartzRect(primaryPlacement.imageClipRect, canvasHeight: canvasHeight)
                )
                context.restoreGState()
            }
        }

        let caption = primaryItem.caption ?? secondaryItem.caption
        drawCaption(
            caption,
            placement: primaryPlacement,
            appearance: appearance,
            in: context
        )
        drawCardBorder(primaryPlacement, appearance: appearance, in: context, canvasHeight: canvasHeight)
        drawComparisonLabels(
            comparison,
            layout: layout,
            settings: composition.comparison,
            in: context,
            canvasHeight: canvasHeight
        )
        return registrationOutcome
    }

    private static func differenceImage(
        primaryImage: CGImage,
        primaryPlacement: CompositionItemRenderLayout,
        secondaryImage: CGImage,
        secondaryPlacement: CompositionItemRenderLayout,
        highlightColor: RGBAColor?,
        threshold: CGFloat,
        cueStyle: CompositionDifferenceCueStyle,
        renderScale: CGFloat
    ) -> CGImage? {
        let clip = primaryPlacement.imageClipRect
        let width = max(Int(ceil(clip.width * renderScale)), 1)
        let height = max(Int(ceil(clip.height * renderScale)), 1)
        guard let context = makeContext(width: width, height: height) else { return nil }
        let localHeight = CGFloat(height)
        let localClip = CGRect(x: 0, y: 0, width: width, height: height)
        context.clear(localClip)
        context.interpolationQuality = .high

        func localPlacement(_ placement: CompositionItemRenderLayout) -> CompositionItemRenderLayout {
            CompositionItemRenderLayout(
                itemID: placement.itemID,
                assetID: placement.assetID,
                sourceSize: placement.sourceSize,
                frameRect: placement.frameRect
                    .offsetBy(dx: -clip.minX, dy: -clip.minY)
                    .gscScaled(by: renderScale),
                imageClipRect: placement.imageClipRect
                    .offsetBy(dx: -clip.minX, dy: -clip.minY)
                    .gscScaled(by: renderScale),
                imageDrawRect: placement.imageDrawRect
                    .offsetBy(dx: -clip.minX, dy: -clip.minY)
                    .gscScaled(by: renderScale),
                captionRect: nil,
                badgeRect: nil,
                opacity: 1,
                zIndex: placement.zIndex,
                role: placement.role
            )
        }

        drawImage(
            primaryImage,
            placement: localPlacement(primaryPlacement),
            opacity: 1,
            in: context,
            canvasHeight: localHeight
        )
        drawImage(
            secondaryImage,
            placement: localPlacement(secondaryPlacement),
            opacity: 1,
            blendMode: .difference,
            in: context,
            canvasHeight: localHeight
        )
        if let highlightColor {
            context.saveGState()
            context.setBlendMode(.multiply)
            context.setFillColor(highlightColor.withAlpha(1).cgColor)
            context.fill(localClip)
            context.restoreGState()
        }

        guard let rawDifference = context.makeImage() else { return nil }
        let clampedThreshold = threshold.clampedCompositionUnit
        guard clampedThreshold > 0 else { return rawDifference }

        let adjusted = CIImage(cgImage: rawDifference).applyingFilter(
            "CIColorControls",
            parameters: [
                kCIInputContrastKey: 1 + clampedThreshold * 8,
                kCIInputBrightnessKey: -clampedThreshold * 0.5,
                kCIInputSaturationKey: highlightColor == nil ? 1 : 1.2,
            ]
        )
        let cued: CIImage
        switch cueStyle {
        case .luminance:
            cued = adjusted
        case .outline:
            cued = adjusted.applyingFilter(
                "CIEdges",
                parameters: [kCIInputIntensityKey: 2.5]
            )
        case .pattern, .outlineAndPattern:
            let stripes = CIFilter(
                name: "CIStripesGenerator",
                parameters: [
                    "inputCenter": CIVector(x: 0, y: 0),
                    "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 0.95),
                    "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0.12),
                    "inputWidth": 7,
                    "inputSharpness": 0.85,
                ]
            )?.outputImage?.cropped(to: adjusted.extent) ?? adjusted
            let patterned = stripes.applyingFilter(
                "CIBlendWithMask",
                parameters: [
                    kCIInputBackgroundImageKey: CIImage(
                        color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)
                    )
                        .cropped(to: adjusted.extent),
                    kCIInputMaskImageKey: adjusted,
                ]
            )
            if cueStyle == .outlineAndPattern {
                let edges = adjusted.applyingFilter(
                    "CIEdges",
                    parameters: [kCIInputIntensityKey: 3]
                )
                cued = edges.composited(over: patterned)
            } else {
                cued = patterned
            }
        }
        return ciContext.createCGImage(cued, from: adjusted.extent)
    }

    private struct AutomaticRegistrationResult {
        let offset: CGSize
        let confidence: CGFloat
    }

    private static func automaticRegistration(
        primaryImage: CGImage,
        secondaryImage: CGImage,
        destinationSize: CGSize,
        sensitivity: CGFloat
    ) -> AutomaticRegistrationResult? {
        let sampleSide = 80
        guard let primary = grayscaleSample(primaryImage, side: sampleSide),
              let secondary = grayscaleSample(secondaryImage, side: sampleSide) else {
            return nil
        }
        guard grayscaleStandardDeviation(primary) >= 2,
              grayscaleStandardDeviation(secondary) >= 2 else {
            // Flat or nearly flat images do not contain enough local structure
            // to infer a trustworthy translation.
            return nil
        }
        let clampedSensitivity = sensitivity.clampedCompositionUnit
        let searchRadius = 3 + Int((clampedSensitivity * 17).rounded())
        var bestScore = Double.greatestFiniteMagnitude
        var bestDX = 0
        var bestDY = 0

        // Coarse-to-fine search keeps automatic registration comfortably
        // inside the live-preview budget even in unoptimized test builds. The
        // coarse pass samples every other pixel and offset; the full-resolution
        // pass then resolves the best neighborhood to the original one-sample
        // precision.
        var coarseOffsets = Array(
            stride(from: -searchRadius, through: searchRadius, by: 2)
        )
        if !coarseOffsets.contains(0) {
            coarseOffsets.append(0)
            coarseOffsets.sort()
        }
        for dy in coarseOffsets {
            for dx in coarseOffsets {
                guard let score = registrationScore(
                    primary: primary,
                    secondary: secondary,
                    side: sampleSide,
                    dx: dx,
                    dy: dy,
                    pixelStride: 2
                ) else {
                    continue
                }
                if score < bestScore {
                    bestScore = score
                    bestDX = dx
                    bestDY = dy
                }
            }
        }

        let coarseDX = bestDX
        let coarseDY = bestDY
        bestScore = .greatestFiniteMagnitude
        for dy in max(-searchRadius, coarseDY - 2)...min(searchRadius, coarseDY + 2) {
            for dx in max(-searchRadius, coarseDX - 2)...min(searchRadius, coarseDX + 2) {
                guard let score = registrationScore(
                    primary: primary,
                    secondary: secondary,
                    side: sampleSide,
                    dx: dx,
                    dy: dy,
                    pixelStride: 1
                ) else {
                    continue
                }
                if score < bestScore {
                    bestScore = score
                    bestDX = dx
                    bestDY = dy
                }
            }
        }

        // If correlation has no meaningful advantage, avoid inventing a
        // registration shift and leave manual fallback available.
        guard bestScore < 42 else {
            return nil
        }
        return AutomaticRegistrationResult(
            offset: CGSize(
                width: -CGFloat(bestDX) * destinationSize.width / CGFloat(sampleSide),
                height: -CGFloat(bestDY) * destinationSize.height / CGFloat(sampleSide)
            ),
            confidence: min(max(CGFloat(1 - bestScore / 42), 0), 1)
        )
    }

    private static func grayscaleStandardDeviation(_ pixels: [UInt8]) -> Double {
        guard !pixels.isEmpty else { return 0 }
        let mean = pixels.reduce(0) { $0 + Double($1) } / Double(pixels.count)
        let variance = pixels.reduce(0) {
            let delta = Double($1) - mean
            return $0 + delta * delta
        } / Double(pixels.count)
        return sqrt(variance)
    }

    private static func registrationScore(
        primary: [UInt8],
        secondary: [UInt8],
        side: Int,
        dx: Int,
        dy: Int,
        pixelStride: Int
    ) -> Double? {
        let minX = max(0, -dx)
        let maxX = min(side, side - dx)
        let minY = max(0, -dy)
        let maxY = min(side, side - dy)
        guard maxX - minX >= side / 2,
              maxY - minY >= side / 2 else {
            return nil
        }

        var total = 0
        var count = 0
        var y = minY
        while y < maxY {
            let primaryRow = y * side
            let secondaryRow = (y + dy) * side
            var x = minX
            while x < maxX {
                total += abs(
                    Int(primary[primaryRow + x])
                        - Int(secondary[secondaryRow + x + dx])
                )
                count += 1
                x += pixelStride
            }
            y += pixelStride
        }
        guard count > 0 else { return nil }

        let overlapArea = (maxX - minX) * (maxY - minY)
        let overlap = Double(overlapArea) / Double(side * side)
        return Double(total) / Double(count) + (1 - overlap) * 16
    }

    private static func grayscaleSample(
        _ image: CGImage,
        side: Int
    ) -> [UInt8]? {
        var pixels = Array(repeating: UInt8.zero, count: side * side)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearGray),
              let context = CGContext(
                data: &pixels,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
              ) else {
            return nil
        }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return pixels
    }

    private static func drawComparisonLabels(
        _ comparison: CompositionComparisonRenderLayout,
        layout: CompositionRenderLayout,
        settings: CompositionComparisonSettings,
        in context: CGContext,
        canvasHeight: CGFloat
    ) {
        guard settings.showsLabels else {
            return
        }
        guard let primary = layout.itemLayout(for: comparison.primaryItemID),
              let secondary = layout.itemLayout(for: comparison.secondaryItemID) else {
            return
        }
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let primarySize = (settings.primaryLabel as NSString).size(withAttributes: [.font: font])
        let secondarySize = (settings.secondaryLabel as NSString).size(withAttributes: [.font: font])
        let horizontalPadding: CGFloat = 8
        let verticalPadding: CGFloat = 5

        let primaryRect = CGRect(
            x: primary.imageClipRect.minX + 10,
            y: primary.imageClipRect.minY + 10,
            width: primarySize.width + horizontalPadding * 2,
            height: primarySize.height + verticalPadding * 2
        )
        let secondaryAnchor = comparison.mode == .sideBySide
            ? secondary.imageClipRect
            : primary.imageClipRect
        let secondaryRect = CGRect(
            x: secondaryAnchor.maxX - secondarySize.width - horizontalPadding * 2 - 10,
            y: secondaryAnchor.minY + 10,
            width: secondarySize.width + horizontalPadding * 2,
            height: secondarySize.height + verticalPadding * 2
        )

        drawLabel(
            settings.primaryLabel,
            rect: primaryRect,
            font: font,
            in: context,
            canvasHeight: canvasHeight
        )
        drawLabel(
            settings.secondaryLabel,
            rect: secondaryRect,
            font: font,
            in: context,
            canvasHeight: canvasHeight
        )
    }

    private static func drawLabel(
        _ text: String,
        rect: CGRect,
        font: NSFont,
        in context: CGContext,
        canvasHeight: CGFloat
    ) {
        guard !text.isEmpty else { return }
        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(0.68).cgColor)
        let quartz = quartzRect(rect, canvasHeight: canvasHeight)
        context.addPath(
            CGPath(
                roundedRect: quartz,
                cornerWidth: 6,
                cornerHeight: 6,
                transform: nil
            )
        )
        context.fillPath()
        context.restoreGState()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        (text as NSString).draw(
            in: rect.offsetBy(dx: 0, dy: (rect.height - font.pointSize * 1.25) / 2),
            withAttributes: attributes
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Canvas decoration

    private static func drawCanvasFill(
        _ fill: CompositionCanvasFill,
        in context: CGContext,
        canvasRect: CGRect
    ) {
        switch fill {
        case .transparent:
            break
        case .color(let color):
            context.saveGState()
            context.setFillColor(color.cgColor)
            context.fill(canvasRect)
            context.restoreGState()
        }
    }

    private static func drawConnectors(
        _ connectors: [CompositionConnectorRenderLayout],
        appearance: CompositionCanvasAppearance,
        in context: CGContext,
        canvasHeight: CGFloat
    ) {
        for connector in connectors where connector.style != .none {
            let start = quartzPoint(connector.start, canvasHeight: canvasHeight)
            let end = quartzPoint(connector.end, canvasHeight: canvasHeight)
            context.saveGState()
            context.setStrokeColor(appearance.connectorColor.cgColor)
            context.setFillColor(appearance.connectorColor.cgColor)
            context.setLineWidth(max(appearance.connectorWidth, 0.5))
            context.setLineCap(.round)
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()

            if connector.style == .arrow {
                let angle = atan2(end.y - start.y, end.x - start.x)
                let length = max(appearance.connectorWidth * 4, 7)
                let spread: CGFloat = .pi / 7
                let left = CGPoint(
                    x: end.x - cos(angle - spread) * length,
                    y: end.y - sin(angle - spread) * length
                )
                let right = CGPoint(
                    x: end.x - cos(angle + spread) * length,
                    y: end.y - sin(angle + spread) * length
                )
                context.move(to: end)
                context.addLine(to: left)
                context.addLine(to: right)
                context.closePath()
                context.fillPath()
            }
            context.restoreGState()
        }
    }

    // MARK: - Quartz helpers

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        guard width > 0,
              height > 0 else {
            return nil
        }
        return SRGBBitmapContext.make(width: width, height: height)
    }

    private static func quartzRect(_ topLeftRect: CGRect, canvasHeight: CGFloat) -> CGRect {
        CGRect(
            x: topLeftRect.minX,
            y: canvasHeight - topLeftRect.maxY,
            width: topLeftRect.width,
            height: topLeftRect.height
        )
    }

    private static func quartzPoint(_ topLeftPoint: CGPoint, canvasHeight: CGFloat) -> CGPoint {
        CGPoint(x: topLeftPoint.x, y: canvasHeight - topLeftPoint.y)
    }
}

private nonisolated extension ScreenshotEditState {
    func isPixelIdentity(for image: CGImage) -> Bool {
        let fullRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let resolvedCrop = cropRect?.standardized.integral ?? fullRect
        return resolvedCrop == fullRect
            && annotations.isEmpty
            && pinnedUIMapElementIDs.isEmpty
    }
}

private nonisolated extension CGFloat {
    var clampedCompositionUnit: CGFloat {
        guard isFinite else { return 0 }
        return Swift.min(Swift.max(self, 0), 1)
    }
}

private nonisolated extension CompositionTextWeight {
    var nsFontWeight: NSFont.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }
}

private nonisolated extension CompositionTextAlignment {
    var nsTextAlignment: NSTextAlignment {
        switch self {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }
    }
}

private nonisolated extension CGSize {
    var isFiniteCompositionSize: Bool {
        width.isFinite && height.isFinite
    }
}

private nonisolated extension CompositionItemRenderLayout {
    func offsettingImage(by offset: CGSize) -> CompositionItemRenderLayout {
        CompositionItemRenderLayout(
            itemID: itemID,
            assetID: assetID,
            sourceSize: sourceSize,
            frameRect: frameRect,
            imageClipRect: imageClipRect,
            imageDrawRect: imageDrawRect.offsetBy(
                dx: offset.width,
                dy: offset.height
            ),
            captionRect: captionRect,
            badgeRect: badgeRect,
            opacity: opacity,
            zIndex: zIndex,
            role: role
        )
    }
}
