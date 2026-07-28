import CoreGraphics
import Foundation

/// The single content pipeline used by editor previews, clipboard output,
/// document previews, recovery, and export. Composition is always assembled
/// before Presentation styling so Plain and Styled differ only at the final
/// wrapper boundary.
nonisolated enum CompositionDocumentRenderError: LocalizedError {
    case failedToRenderSingleCapture
    case failedToApplyPresentation

    var errorDescription: String? {
        switch self {
        case .failedToRenderSingleCapture:
            return "The screenshot content could not be rendered."
        case .failedToApplyPresentation:
            return "The Polish Look or Mockup could not be rendered."
        }
    }
}

/// Immutable input for package, recovery, and history previews. The repository
/// contains encoded source assets only; preview rendering asks it for
/// destination-sized item pixels and never resolves full-resolution captures.
nonisolated struct CompositionDocumentPreviewInput: @unchecked Sendable {
    let baseImage: CGImage
    let snapshot: EditorSnapshot
    let assetRepository: CompositionAssetRepository
    let pinnedUIMapElements: [UIMapElement]
    let uiMapOverlayOptions: UIMapOverlayOptions
    let isPrivate: Bool

    init(
        baseImage: CGImage,
        snapshot: EditorSnapshot,
        assetRepository: CompositionAssetRepository,
        pinnedUIMapElements: [UIMapElement] = [],
        uiMapOverlayOptions: UIMapOverlayOptions = UIMapOverlayOptions(),
        isPrivate: Bool = false
    ) {
        self.baseImage = baseImage
        self.snapshot = snapshot
        self.assetRepository = assetRepository
        self.pinnedUIMapElements = pinnedUIMapElements
        self.uiMapOverlayOptions = uiMapOverlayOptions
        self.isPrivate = isPrivate
    }
}

/// Shared bounded preview path for editable packages and recovery/history.
///
/// The cap applies to the final Presentation-wrapped image. Activated
/// compositions assemble through `renderPreview`, so source PNGs are
/// downsampled before item edits and no full-resolution composition is created.
nonisolated enum CompositionDocumentPreviewRenderer {
    static let maximumPixelDimension = 2_048

    static func render(
        _ input: CompositionDocumentPreviewInput,
        maximumPixelDimension requestedMaximumPixelDimension: Int = maximumPixelDimension
    ) throws -> CGImage {
        let maximumPixelDimension = max(requestedMaximumPixelDimension, 1)

        return try PresentationPerformanceMetrics.withLoggingSuppressed(
            input.isPrivate
        ) {
            try PresentationPerformanceMetrics.measure(
                "document.preview.render",
                context: "base=\(input.baseImage.width)x\(input.baseImage.height) compositionItems=\(input.snapshot.composition?.items.count ?? 0) \(PresentationPerformanceMetrics.presentationSummary(input.snapshot.presentation, maxPixelDimension: CGFloat(maximumPixelDimension)))",
                warnAfterMS: 180
            ) {
                let comparisonPhase: CompositionComparisonPhase
                if let composition = input.snapshot.composition,
                   composition.layout.mode == .compare,
                   composition.comparison.mode == .blink {
                    comparisonPhase = composition.comparison.posterFrame == .secondary
                        ? .secondary
                        : .primary
                } else {
                    comparisonPhase = .primary
                }
                let options = CompositionRenderOptions(
                    comparisonPhase: comparisonPhase,
                    targetMaximumPixelDimension: maximumPixelDimension,
                    uiMapOverlayOptions: input.uiMapOverlayOptions
                )
                guard let content = try CompositionDocumentRenderer.renderContent(
                    baseImage: input.baseImage,
                    snapshot: input.snapshot,
                    compositionAssetRepository: input.assetRepository,
                    pinnedUIMapElements: input.pinnedUIMapElements,
                    uiMapOverlayOptions: input.uiMapOverlayOptions,
                    compositionOptions: options
                )?.image,
                let presented = ScreenshotPresentationRenderer.renderWithLayout(
                    contentImage: content,
                    presentation: input.snapshot.presentation,
                    maxPixelDimension: CGFloat(maximumPixelDimension)
                )?.image else {
                    throw CompositionDocumentRenderError.failedToApplyPresentation
                }
                return try boundedImage(
                    presented,
                    maximumPixelDimension: maximumPixelDimension
                )
            }
        }
    }

    private static func boundedImage(
        _ image: CGImage,
        maximumPixelDimension: Int
    ) throws -> CGImage {
        let longestSide = max(image.width, image.height)
        guard longestSide > maximumPixelDimension else {
            return image
        }
        let scale = CGFloat(maximumPixelDimension) / CGFloat(longestSide)
        let width = max(
            min(Int(floor(CGFloat(image.width) * scale)), maximumPixelDimension),
            1
        )
        let height = max(
            min(Int(floor(CGFloat(image.height) * scale)), maximumPixelDimension),
            1
        )
        guard let context = SRGBBitmapContext.make(
            width: width,
            height: height
        ) else {
            throw CompositionDocumentRenderError.failedToApplyPresentation
        }
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        guard let bounded = context.makeImage() else {
            throw CompositionDocumentRenderError.failedToApplyPresentation
        }
        return bounded
    }
}

nonisolated enum CompositionDocumentRenderer {
    static func renderContent(
        baseImage: CGImage,
        snapshot: EditorSnapshot,
        compositionAssets: [UUID: CompositionAsset] = [:],
        compositionAssetRepository: CompositionAssetRepository? = nil,
        pinnedUIMapElements: [UIMapElement] = [],
        uiMapOverlayOptions: UIMapOverlayOptions = UIMapOverlayOptions(),
        compositionOptions: CompositionRenderOptions? = nil
    ) throws -> CompositionRenderResult? {
        guard let composition = snapshot.composition,
              composition.isActivated else {
            guard let image = EditorRenderer.render(
                baseImage: baseImage,
                snapshot: snapshot,
                pinnedUIMapElements: pinnedUIMapElements,
                uiMapOverlayOptions: uiMapOverlayOptions
            ) else {
                throw CompositionDocumentRenderError.failedToRenderSingleCapture
            }
            return CompositionRenderResult(
                image: image,
                layout: CompositionRenderLayout.singleImage(
                    size: CGSize(width: image.width, height: image.height)
                )
            )
        }

        var options = compositionOptions ?? CompositionRenderOptions()
        options.uiMapOverlayOptions = uiMapOverlayOptions
        if options.targetMaximumPixelDimension != nil,
           let compositionAssetRepository {
            return try CompositionRenderer.renderPreview(
                composition: composition,
                assetRepository: compositionAssetRepository,
                options: options
            )
        }
        return try CompositionRenderer.render(
            composition: composition,
            assets: compositionAssets,
            options: options
        )
    }

    static func renderImage(
        baseImage: CGImage,
        snapshot: EditorSnapshot,
        compositionAssets: [UUID: CompositionAsset] = [:],
        pinnedUIMapElements: [UIMapElement] = [],
        uiMapOverlayOptions: UIMapOverlayOptions = UIMapOverlayOptions(),
        compositionOptions: CompositionRenderOptions? = nil
    ) throws -> CGImage {
        let resolvedCompositionOptions: CompositionRenderOptions?
        if compositionOptions == nil,
           let composition = snapshot.composition,
           composition.layout.mode == .compare,
           composition.comparison.mode == .blink {
            resolvedCompositionOptions = CompositionRenderOptions(
                comparisonPhase: composition.comparison.posterFrame == .secondary
                    ? .secondary
                    : .primary
            )
        } else {
            resolvedCompositionOptions = compositionOptions
        }
        guard let content = try renderContent(
            baseImage: baseImage,
            snapshot: snapshot,
            compositionAssets: compositionAssets,
            pinnedUIMapElements: pinnedUIMapElements,
            uiMapOverlayOptions: uiMapOverlayOptions,
            compositionOptions: resolvedCompositionOptions
        )?.image,
        let presented = ScreenshotPresentationRenderer.render(
            contentImage: content,
            presentation: snapshot.presentation
        ) else {
            throw CompositionDocumentRenderError.failedToApplyPresentation
        }
        return presented
    }
}

private extension CompositionRenderLayout {
    nonisolated static func singleImage(size: CGSize) -> CompositionRenderLayout {
        let rect = CGRect(origin: .zero, size: size)
        return CompositionRenderLayout(
            requestedMode: .auto,
            resolvedMode: .auto,
            canvasSize: size,
            contentRect: rect,
            items: [],
            connectors: [],
            comparison: nil,
            omittedItemIDs: []
        )
    }
}
