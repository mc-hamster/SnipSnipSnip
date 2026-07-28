import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum CompositionOutputFormat: String, CaseIterable, Identifiable, Sendable {
    case png
    case jpeg
    case pdf
    case gif
    case apng
    case mp4
    case html

    var id: String { rawValue }

    var label: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .pdf: "PDF"
        case .gif: "GIF"
        case .apng: "APNG"
        case .mp4: "MP4"
        case .html: "Interactive HTML"
        }
    }

    var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .pdf: "pdf"
        case .gif: "gif"
        case .apng: "apng"
        case .mp4: "mp4"
        case .html: "html"
        }
    }

    var contentType: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .pdf: .pdf
        case .gif: .gif
        case .apng: UTType(filenameExtension: "apng") ?? .png
        case .mp4: .mpeg4Movie
        case .html: .html
        }
    }

    var isAnimated: Bool {
        switch self {
        case .gif, .apng, .mp4:
            true
        case .png, .jpeg, .pdf, .html:
            false
        }
    }

    init?(imageFormat: ImageExportFormat) {
        switch imageFormat {
        case .png: self = .png
        case .jpeg: self = .jpeg
        case .pdf: self = .pdf
        }
    }
}

nonisolated struct CompositionOutputInput: @unchecked Sendable {
    let baseImage: CGImage
    let snapshot: EditorSnapshot
    let compositionAssets: [UUID: CompositionAsset]
    let compositionAssetRepository: CompositionAssetRepository?
    let compositionAssetDescriptors: [UUID: CompositionAssetDescriptor]
    let pinnedUIMapElements: [UIMapElement]
    let uiMapOverlayOptions: UIMapOverlayOptions
    let appearance: ScreenshotOutputAppearance
    let suppressesContentDiagnostics: Bool

    init(
        baseImage: CGImage,
        snapshot: EditorSnapshot,
        compositionAssets: [UUID: CompositionAsset],
        compositionAssetRepository: CompositionAssetRepository? = nil,
        compositionAssetDescriptors: [UUID: CompositionAssetDescriptor]? = nil,
        pinnedUIMapElements: [UIMapElement] = [],
        uiMapOverlayOptions: UIMapOverlayOptions = UIMapOverlayOptions(),
        appearance: ScreenshotOutputAppearance,
        suppressesContentDiagnostics: Bool = false
    ) {
        self.baseImage = baseImage
        self.snapshot = snapshot
        self.compositionAssets = compositionAssets
        self.compositionAssetRepository = compositionAssetRepository
        self.compositionAssetDescriptors =
            compositionAssetDescriptors
            ?? compositionAssetRepository?.descriptors
            ?? compositionAssets.mapValues(\.descriptor)
        self.pinnedUIMapElements = pinnedUIMapElements
        self.uiMapOverlayOptions = uiMapOverlayOptions
        self.appearance = appearance
        self.suppressesContentDiagnostics =
            suppressesContentDiagnostics
    }
}

nonisolated struct CompositionOutputResult: Equatable, Sendable {
    let url: URL
    let format: CompositionOutputFormat
    let appearance: ScreenshotOutputAppearance
    let pageCount: Int
    let pixelSize: CGSize?
    let wasScaledToAnimatedLimit: Bool
    let wasScaledToRasterSafetyLimit: Bool

    var disclosure: String? {
        if wasScaledToAnimatedLimit {
            return "Animated output was scaled to the 4,096-pixel longest-side safety limit."
        }
        if wasScaledToRasterSafetyLimit {
            return "Output was scaled to fit the safe raster size and memory limits."
        }
        return nil
    }
}

nonisolated enum CompositionOutputProgressPhase: Equatable, Sendable {
    case rendering
    case encoding
    case assembling
    case saving
    case finalizing
}

nonisolated struct CompositionOutputProgressUpdate: Equatable, Sendable {
    let phase: CompositionOutputProgressPhase
    let detail: String
    let fractionCompleted: Double
}

typealias CompositionOutputProgressHandler =
    @Sendable (CompositionOutputProgressUpdate) async -> Void

nonisolated struct CompositionExportProgressState: Equatable, Sendable {
    let fractionCompleted: Double
    let detail: String
    let isCancellationRequested: Bool
}

nonisolated struct CompositionOutputPreflight: Equatable, Sendable {
    let estimatedPixelSize: CGSize
    let estimatedWorkingSetBytes: Int
    let isOversized: Bool
    let recommendedMaximumOutputDimension: Int?
    let canUsePaginatedPDF: Bool
    let estimatedPageCount: Int

    var sizeDescription: String {
        "\(Int(estimatedPixelSize.width.rounded(.up))) × \(Int(estimatedPixelSize.height.rounded(.up)))"
    }
}

nonisolated enum CompositionOutputError: LocalizedError, Equatable {
    case compositionRequired(format: CompositionOutputFormat)
    case blinkComparisonRequired(format: CompositionOutputFormat)
    case htmlRequiresStepsOrComparison
    case noIncludedItems
    case outputTooLarge(width: Int?, height: Int?)
    case estimatedWorkingSetTooLarge
    case transparentPresentationRequiresPNG
    case failedToRender
    case failedToEncode(format: CompositionOutputFormat)
    case mediaWriterFailed(String)

    var errorDescription: String? {
        switch self {
        case .compositionRequired(let format):
            return "\(format.label) composition export requires a multi-capture composition."
        case .blinkComparisonRequired(let format):
            return "\(format.label) animation requires a composition using Compare → Blink."
        case .htmlRequiresStepsOrComparison:
            return "Interactive HTML is available for Steps and Compare compositions."
        case .noIncludedItems:
            return "The composition has no included images to export."
        case .outputTooLarge(let width, let height):
            if let width, let height {
                return "The \(width) × \(height) output is too large to render safely. Reduce the export scale, use a paginated PDF, or reduce the canvas size."
            }
            return "The output is too large to render safely. Reduce the export scale, use a paginated PDF, or reduce the canvas size."
        case .estimatedWorkingSetTooLarge:
            return "The estimated export working set exceeds 1 GiB. Reduce the export scale, use a paginated PDF, or reduce the canvas size."
        case .transparentPresentationRequiresPNG:
            return ImageExportError.transparentPresentationRequiresPNG.errorDescription
        case .failedToRender:
            return "The composition output could not be rendered."
        case .failedToEncode(let format):
            return "The composition could not be encoded as \(format.label)."
        case .mediaWriterFailed(let reason):
            return "The MP4 could not be written. \(reason)"
        }
    }

    var isUnsupportedCombination: Bool {
        switch self {
        case .compositionRequired, .blinkComparisonRequired, .htmlRequiresStepsOrComparison:
            true
        case .noIncludedItems, .outputTooLarge, .estimatedWorkingSetTooLarge,
             .transparentPresentationRequiresPNG, .failedToRender, .failedToEncode,
             .mediaWriterFailed:
            false
        }
    }

    var isOversized: Bool {
        switch self {
        case .outputTooLarge, .estimatedWorkingSetTooLarge:
            true
        default:
            false
        }
    }
}

/// Exports a frozen editor snapshot through the same content → Presentation
/// pipeline used by previews, clipboard output, document previews, and still
/// exports. Animated and HTML output never receives source-file bytes or source
/// metadata; it is built exclusively from fully rendered pixels.
nonisolated enum CompositionOutputExporter {
    static let maximumRasterDimension = 16_384
    static let maximumRasterPixelCount = 134_217_728
    static let maximumEstimatedWorkingSetBytes = 1_073_741_824
    static let maximumAnimatedDimension = 4_096

    private static let animatedCrossfadeFrameRate = 30.0
    private static let maximumCrossfadeFrameCount = 12

    static func preflight(
        _ input: CompositionOutputInput,
        format: CompositionOutputFormat,
        forcedPDFItemsPerPage: Int? = nil
    ) throws -> CompositionOutputPreflight {
        // Animated and HTML exporters always render directly at their own
        // bounded target sizes. Their result disclosure communicates that cap.
        guard !format.isAnimated, format != .html else {
            return CompositionOutputPreflight(
                estimatedPixelSize: .zero,
                estimatedWorkingSetBytes: 0,
                isOversized: false,
                recommendedMaximumOutputDimension: nil,
                canUsePaginatedPDF: false,
                estimatedPageCount: 1
            )
        }

        let snapshots = try estimatedPageSnapshots(
            input,
            usesPDFPagination: format == .pdf,
            forcedPDFItemsPerPage: forcedPDFItemsPerPage
        )
        let descriptors = input.compositionAssetDescriptors
        var largestSize = CGSize.zero
        var largestPixels = 0
        var recommendedCap: Int?
        var oversized = false

        for snapshot in snapshots {
            let contentSize: CGSize
            if let composition = snapshot.composition, composition.isActivated {
                do {
                    contentSize = try CompositionLayoutEngine.layout(
                        composition: composition,
                        assetDescriptors: descriptors
                    ).canvasSize
                } catch {
                    throw CompositionOutputError.failedToRender
                }
            } else {
                let crop = snapshot.cropRect.integral
                contentSize = crop.width > 0 && crop.height > 0
                    ? crop.size
                    : CGSize(width: input.baseImage.width, height: input.baseImage.height)
            }

            let outputSize = ScreenshotPresentationRenderer.outputSize(
                for: contentSize,
                presentation: snapshot.presentation
            )
            guard outputSize.width.isFinite,
                  outputSize.height.isFinite,
                  outputSize.width > 0,
                  outputSize.height > 0 else {
                throw CompositionOutputError.failedToRender
            }
            let width = Int(outputSize.width.rounded(.up))
            let height = Int(outputSize.height.rounded(.up))
            let pixels = width.multipliedReportingOverflow(by: height)
            guard !pixels.overflow else {
                throw CompositionOutputError.outputTooLarge(width: width, height: height)
            }
            if pixels.partialValue > largestPixels {
                largestPixels = pixels.partialValue
                largestSize = CGSize(width: width, height: height)
            }
            if outputExceedsSafetyLimits(
                width: width,
                height: height,
                pixels: pixels.partialValue
            ) {
                oversized = true
                let cap = safeMaximumDimension(
                    width: width,
                    height: height,
                    pixels: pixels.partialValue
                )
                recommendedCap = min(recommendedCap ?? cap, cap)
            }
        }

        let estimatedBytes = largestPixels.multipliedReportingOverflow(by: 8)
        return CompositionOutputPreflight(
            estimatedPixelSize: largestSize,
            estimatedWorkingSetBytes: estimatedBytes.overflow
                ? Int.max
                : estimatedBytes.partialValue,
            isOversized: oversized,
            recommendedMaximumOutputDimension: recommendedCap,
            canUsePaginatedPDF: format == .pdf
                && input.snapshot.composition?.layout.mode == .steps
                && (input.snapshot.composition?.items.filter(\.isIncluded).count ?? 0) > 1,
            estimatedPageCount: snapshots.count
        )
    }

    static func export(
        _ input: CompositionOutputInput,
        format: CompositionOutputFormat,
        to destination: URL,
        imageOptions: ImageExportOptions = .default,
        maximumOutputDimension: Int? = nil,
        forcedPDFItemsPerPage: Int? = nil,
        progress: CompositionOutputProgressHandler? = nil
    ) async throws -> CompositionOutputResult {
        try await PresentationPerformanceMetrics.withLoggingSuppressed(
            input.suppressesContentDiagnostics
        ) {
            try await exportWithDiagnosticsPolicyApplied(
                input,
                format: format,
                to: destination,
                imageOptions: imageOptions,
                maximumOutputDimension: maximumOutputDimension,
                forcedPDFItemsPerPage: forcedPDFItemsPerPage,
                progress: progress
            )
        }
    }

    private static func exportWithDiagnosticsPolicyApplied(
        _ input: CompositionOutputInput,
        format: CompositionOutputFormat,
        to destination: URL,
        imageOptions: ImageExportOptions,
        maximumOutputDimension: Int?,
        forcedPDFItemsPerPage: Int?,
        progress: CompositionOutputProgressHandler?
    ) async throws -> CompositionOutputResult {
        try Task.checkCancellation()
        if input.appearance == .styled,
           input.snapshot.presentation.requiresPNGForFaithfulExport,
           format == .jpeg || format == .pdf {
            throw CompositionOutputError.transparentPresentationRequiresPNG
        }
        let didAccess = destination.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                destination.stopAccessingSecurityScopedResource()
            }
        }

        let resolvedInput = inputWithForcedPDFPagination(
            input,
            itemsPerPage: forcedPDFItemsPerPage
        )

        switch format {
        case .png, .jpeg:
            let rendered = try renderStatic(
                resolvedInput,
                maximumOutputDimension: maximumOutputDimension
            )
            let image = rendered.image
            try await atomicFileAsync(destination) { temporaryURL in
                let imageFormat: ImageExportFormat = format == .png ? .png : .jpeg
                try await ImageExporter.write(
                    image,
                    format: imageFormat,
                    to: temporaryURL,
                    mode: .direct,
                    options: imageOptions
                )
            }
            return result(
                input: resolvedInput,
                format: format,
                destination: destination,
                pageCount: 1,
                image: image,
                wasSafetyScaled: rendered.wasScaled
            )

        case .pdf:
            var summary: PDFRenderSummary?
            try atomicFile(destination) { temporaryURL in
                summary = try writePDF(
                    resolvedInput,
                    maximumOutputDimension: maximumOutputDimension,
                    to: temporaryURL
                )
            }
            guard let summary else {
                throw CompositionOutputError.failedToEncode(format: .pdf)
            }
            return result(
                input: resolvedInput,
                format: format,
                destination: destination,
                pageCount: summary.pageCount,
                pixelSize: summary.firstPixelSize,
                wasSafetyScaled: summary.wasScaled
            )

        case .gif, .apng:
            let animation = try renderedBlinkAnimation(input, format: format)
            try atomicFile(destination) { temporaryURL in
                try writeAnimatedImage(
                    animation.frames,
                    loops: animation.loops,
                    format: format,
                    to: temporaryURL
                )
            }
            return result(
                input: resolvedInput,
                format: format,
                destination: destination,
                pageCount: 1,
                image: animation.frames.first?.image,
                wasScaled: animation.wasScaled
            )

        case .mp4:
            let animation = try renderedBlinkAnimation(input, format: format)
            try await atomicFileAsync(destination) { temporaryURL in
                try await writeMP4(animation.frames, to: temporaryURL)
            }
            return result(
                input: resolvedInput,
                format: format,
                destination: destination,
                pageCount: 1,
                image: animation.frames.first?.image,
                wasScaled: animation.wasScaled
            )

        case .html:
            await progress?(
                CompositionOutputProgressUpdate(
                    phase: .rendering,
                    detail: String(localized: "Rendering images…"),
                    fractionCompleted: 0.05
                )
            )
            let document = try renderedHTMLDocument(resolvedInput)
            try await atomicFileAsync(destination) { temporaryURL in
                try await CompositionHTMLExporter.write(
                    document,
                    to: temporaryURL,
                    progress: progress
                )
            }
            await progress?(
                CompositionOutputProgressUpdate(
                    phase: .finalizing,
                    detail: String(localized: "Finishing Interactive HTML export…"),
                    fractionCompleted: 1
                )
            )
            return result(
                input: resolvedInput,
                format: format,
                destination: destination,
                pageCount: 1,
                image: nil
            )
        }
    }

    static func staticImage(
        _ input: CompositionOutputInput,
        maximumOutputDimension: Int? = nil
    ) throws -> CGImage {
        try PresentationPerformanceMetrics.withLoggingSuppressed(
            input.suppressesContentDiagnostics
        ) {
            try renderStatic(
                input,
                maximumOutputDimension: maximumOutputDimension
            ).image
        }
    }

    // MARK: - Rendering

    private struct RenderedAnimation {
        let frames: [TimedFrame]
        let loops: Bool
        let wasScaled: Bool
    }

    struct TimedFrame: @unchecked Sendable {
        let image: CGImage
        let duration: TimeInterval
    }

    private static func renderStatic(
        _ input: CompositionOutputInput,
        maximumOutputDimension: Int?
    ) throws -> PresentedRender {
        let phase: CompositionComparisonPhase
        if let composition = input.snapshot.composition,
           composition.layout.mode == .compare,
           composition.comparison.mode == .blink {
            phase = composition.comparison.posterFrame == .secondary ? .secondary : .primary
        } else {
            phase = .primary
        }
        return try renderPresented(
            input,
            snapshot: input.snapshot,
            phase: phase,
            maximumOutputDimension: maximumOutputDimension
        )
    }

    private static func renderedBlinkAnimation(
        _ input: CompositionOutputInput,
        format: CompositionOutputFormat
    ) throws -> RenderedAnimation {
        guard let composition = input.snapshot.composition else {
            throw CompositionOutputError.compositionRequired(format: format)
        }
        guard composition.layout.mode == .compare,
              composition.comparison.mode == .blink else {
            throw CompositionOutputError.blinkComparisonRequired(format: format)
        }

        let primary = try renderPresented(
            input,
            snapshot: input.snapshot,
            phase: .primary,
            maximumOutputDimension: maximumAnimatedDimension
        )
        let secondary = try renderPresented(
            input,
            snapshot: input.snapshot,
            phase: .secondary,
            maximumOutputDimension: maximumAnimatedDimension
        )
        guard primary.image.width == secondary.image.width,
              primary.image.height == secondary.image.height else {
            throw CompositionOutputError.failedToRender
        }

        let settings = composition.comparison
        return RenderedAnimation(
            frames: animationFrames(
                primary: primary.image,
                secondary: secondary.image,
                interval: settings.blinkInterval,
                crossfade: settings.blinkCrossfadeDuration,
                loops: settings.blinkLoops
            ),
            loops: settings.blinkLoops,
            wasScaled: primary.wasScaled || secondary.wasScaled
        )
    }

    private struct PresentedRender {
        let image: CGImage
        let wasScaled: Bool
    }

    private static func renderPresented(
        _ input: CompositionOutputInput,
        snapshot: EditorSnapshot,
        phase: CompositionComparisonPhase,
        maximumOutputDimension: Int?
    ) throws -> PresentedRender {
        let unboundedContentSize = try estimatedUnboundedContentSize(
            input,
            snapshot: snapshot
        )
        let unboundedOutputSize = try estimatedUnboundedOutputSize(
            contentSize: unboundedContentSize,
            presentation: snapshot.presentation
        )
        let repositoryRenderTarget: Int?
        if input.compositionAssetRepository != nil,
           snapshot.composition?.isActivated == true {
            repositoryRenderTarget = maximumOutputDimension
                ?? max(
                    Int(unboundedOutputSize.width.rounded(.up)),
                    Int(unboundedOutputSize.height.rounded(.up)),
                    1
                )
        } else {
            repositoryRenderTarget = maximumOutputDimension
        }
        let compositionOptions = CompositionRenderOptions(
            comparisonPhase: phase,
            maximumPixelDimension: maximumRasterDimension,
            maximumPixelCount: maximumRasterPixelCount,
            targetMaximumPixelDimension: repositoryRenderTarget,
            uiMapOverlayOptions: input.uiMapOverlayOptions
        )
        let content: CGImage
        do {
            guard let renderedContent = try CompositionDocumentRenderer.renderContent(
                baseImage: input.baseImage,
                snapshot: snapshot,
                compositionAssets: input.compositionAssets,
                compositionAssetRepository:
                    input.compositionAssetRepository,
                pinnedUIMapElements: input.pinnedUIMapElements,
                uiMapOverlayOptions: input.uiMapOverlayOptions,
                compositionOptions: compositionOptions
            )?.image else {
                throw CompositionOutputError.failedToRender
            }
            content = renderedContent
        } catch CompositionRenderError.canvasTooLarge {
            throw CompositionOutputError.outputTooLarge(width: nil, height: nil)
        }

        let expectedSize = ScreenshotPresentationRenderer.outputSize(
            for: CGSize(width: content.width, height: content.height),
            presentation: snapshot.presentation
        )
        if maximumOutputDimension == nil {
            try validateStaticOutputSize(expectedSize)
        }
        let requestedCap = maximumOutputDimension.map(CGFloat.init)
        guard let rendered = ScreenshotPresentationRenderer.renderWithLayout(
            contentImage: content,
            presentation: snapshot.presentation,
            maxPixelDimension: requestedCap
        )?.image else {
            throw CompositionOutputError.failedToRender
        }
        try validateStaticOutputSize(
            CGSize(width: rendered.width, height: rendered.height)
        )
        let wasScaled = maximumOutputDimension.map {
            max(unboundedOutputSize.width, unboundedOutputSize.height)
                > CGFloat($0) + 0.5
        } ?? false
        return PresentedRender(image: rendered, wasScaled: wasScaled)
    }

    private static func estimatedUnboundedContentSize(
        _ input: CompositionOutputInput,
        snapshot: EditorSnapshot
    ) throws -> CGSize {
        if let composition = snapshot.composition, composition.isActivated {
            do {
                return try CompositionLayoutEngine.layout(
                    composition: composition,
                    assetDescriptors: input.compositionAssetDescriptors
                ).canvasSize
            } catch {
                throw CompositionOutputError.failedToRender
            }
        } else {
            let crop = snapshot.cropRect.integral
            return crop.width > 0 && crop.height > 0
                ? crop.size
                : CGSize(
                    width: input.baseImage.width,
                    height: input.baseImage.height
                )
        }
    }

    private static func estimatedUnboundedOutputSize(
        contentSize: CGSize,
        presentation: ScreenshotPresentation
    ) throws -> CGSize {
        let outputSize = ScreenshotPresentationRenderer.outputSize(
            for: contentSize,
            presentation: presentation
        )
        guard outputSize.width.isFinite,
              outputSize.height.isFinite,
              outputSize.width > 0,
              outputSize.height > 0 else {
            throw CompositionOutputError.failedToRender
        }
        return outputSize
    }

    private static func validateStaticOutputSize(_ size: CGSize) throws {
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else {
            throw CompositionOutputError.failedToRender
        }
        let width = Int(size.width.rounded(.up))
        let height = Int(size.height.rounded(.up))
        let pixels = width.multipliedReportingOverflow(by: height)
        guard width <= maximumRasterDimension,
              height <= maximumRasterDimension,
              !pixels.overflow,
              pixels.partialValue <= maximumRasterPixelCount else {
            throw CompositionOutputError.outputTooLarge(width: width, height: height)
        }
        let estimatedBytes = pixels.partialValue.multipliedReportingOverflow(by: 8)
        guard !estimatedBytes.overflow,
              estimatedBytes.partialValue <= maximumEstimatedWorkingSetBytes else {
            throw CompositionOutputError.estimatedWorkingSetTooLarge
        }
    }

    private static func outputExceedsSafetyLimits(
        width: Int,
        height: Int,
        pixels: Int
    ) -> Bool {
        guard width > 0, height > 0, pixels > 0 else {
            return true
        }
        let estimatedBytes = pixels.multipliedReportingOverflow(by: 8)
        return width > maximumRasterDimension
            || height > maximumRasterDimension
            || pixels > maximumRasterPixelCount
            || estimatedBytes.overflow
            || estimatedBytes.partialValue > maximumEstimatedWorkingSetBytes
    }

    private static func safeMaximumDimension(
        width: Int,
        height: Int,
        pixels: Int
    ) -> Int {
        let longest = max(width, height)
        guard longest > 0, pixels > 0 else { return 1 }
        let dimensionScale = min(
            1,
            Double(maximumRasterDimension) / Double(longest)
        )
        let pixelScale = min(
            1,
            sqrt(Double(maximumRasterPixelCount) / Double(pixels))
        )
        let memoryPixelBudget = maximumEstimatedWorkingSetBytes / 8
        let memoryScale = min(
            1,
            sqrt(Double(memoryPixelBudget) / Double(pixels))
        )
        let scale = min(dimensionScale, pixelScale, memoryScale)
        return max(1, Int(floor(Double(longest) * scale)))
    }

    // MARK: - Deterministic blink animation

    static func animationFrames(
        primary: CGImage,
        secondary: CGImage,
        interval: TimeInterval,
        crossfade: TimeInterval,
        loops: Bool
    ) -> [TimedFrame] {
        let resolvedInterval = min(max(interval.isFinite ? interval : 0.75, 0.05), 10)
        let resolvedCrossfade = min(
            max(crossfade.isFinite ? crossfade : 0, 0),
            resolvedInterval
        )
        guard resolvedCrossfade > 0.001 else {
            return [
                TimedFrame(image: primary, duration: resolvedInterval),
                TimedFrame(image: secondary, duration: resolvedInterval),
            ]
        }

        let transitionFrameCount = min(
            max(Int((resolvedCrossfade * animatedCrossfadeFrameRate).rounded()), 2),
            maximumCrossfadeFrameCount
        )
        let transitionFrameDuration = resolvedCrossfade / Double(transitionFrameCount)
        let holdDuration = max(resolvedInterval - resolvedCrossfade, 0.02)
        var frames = [TimedFrame(image: primary, duration: holdDuration)]
        for index in 1...transitionFrameCount {
            let fraction = CGFloat(index) / CGFloat(transitionFrameCount + 1)
            frames.append(TimedFrame(
                image: blend(primary, secondary, fraction: fraction) ?? primary,
                duration: transitionFrameDuration
            ))
        }
        frames.append(TimedFrame(
            image: secondary,
            duration: loops ? holdDuration : resolvedInterval
        ))
        if loops {
            for index in 1...transitionFrameCount {
                let fraction = CGFloat(index) / CGFloat(transitionFrameCount + 1)
                frames.append(TimedFrame(
                    image: blend(secondary, primary, fraction: fraction) ?? secondary,
                    duration: transitionFrameDuration
                ))
            }
        }
        return frames
    }

    private static func blend(
        _ first: CGImage,
        _ second: CGImage,
        fraction: CGFloat
    ) -> CGImage? {
        guard first.width == second.width,
              first.height == second.height,
              let context = SRGBBitmapContext.make(
                  width: first.width,
                  height: first.height
              ) else {
            return nil
        }
        let rect = CGRect(x: 0, y: 0, width: first.width, height: first.height)
        context.clear(rect)
        context.draw(first, in: rect)
        context.setAlpha(min(max(fraction, 0), 1))
        context.draw(second, in: rect)
        return context.makeImage()
    }

    // MARK: - Animated encoders

    private static func writeAnimatedImage(
        _ frames: [TimedFrame],
        loops: Bool,
        format: CompositionOutputFormat,
        to destination: URL
    ) throws {
        guard !frames.isEmpty,
              format == .gif || format == .apng else {
            throw CompositionOutputError.failedToEncode(format: format)
        }
        let type = format == .gif ? UTType.gif.identifier : UTType.png.identifier
        guard let output = CGImageDestinationCreateWithURL(
            destination as CFURL,
            type as CFString,
            frames.count,
            nil
        ) else {
            throw CompositionOutputError.failedToEncode(format: format)
        }

        let loopCount = loops ? 0 : 1
        if format == .gif {
            CGImageDestinationSetProperties(output, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFLoopCount: loopCount,
                ],
            ] as CFDictionary)
        } else {
            CGImageDestinationSetProperties(output, [
                kCGImagePropertyPNGDictionary: [
                    kCGImagePropertyAPNGLoopCount: loopCount,
                ],
            ] as CFDictionary)
        }

        for frame in frames {
            try Task.checkCancellation()
            let delay = min(max(frame.duration, 0.02), 10)
            let properties: CFDictionary = format == .gif
                ? [
                    kCGImagePropertyGIFDictionary: [
                        kCGImagePropertyGIFDelayTime: delay,
                        kCGImagePropertyGIFUnclampedDelayTime: delay,
                    ],
                ] as CFDictionary
                : [
                    kCGImagePropertyPNGDictionary: [
                        kCGImagePropertyAPNGDelayTime: delay,
                        kCGImagePropertyAPNGUnclampedDelayTime: delay,
                    ],
                ] as CFDictionary
            CGImageDestinationAddImage(output, frame.image, properties)
        }
        guard CGImageDestinationFinalize(output) else {
            throw CompositionOutputError.failedToEncode(format: format)
        }
    }

    private static func writeMP4(
        _ frames: [TimedFrame],
        to destination: URL
    ) async throws {
        guard let first = frames.first else {
            throw CompositionOutputError.failedToEncode(format: .mp4)
        }
        let width = max(first.image.width + first.image.width % 2, 2)
        let height = max(first.image.height + first.image.height % 2, 2)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        } catch {
            throw CompositionOutputError.mediaWriterFailed(error.localizedDescription)
        }
        defer {
            if writer.status == .writing {
                writer.cancelWriting()
            }
        }

        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 8_000_000,
                    AVVideoMaxKeyFrameIntervalKey: 30,
                    AVVideoAllowFrameReorderingKey: false,
                ],
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(input) else {
            throw CompositionOutputError.mediaWriterFailed("The video encoder rejected the output settings.")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw CompositionOutputError.mediaWriterFailed(
                writer.error?.localizedDescription ?? "The video encoder could not start."
            )
        }
        writer.startSession(atSourceTime: .zero)

        var timestamp = CMTime.zero
        for frame in frames {
            try Task.checkCancellation()
            try await waitUntilReady(input, writer: writer)
            guard let pixelBuffer = pixelBuffer(
                image: frame.image,
                width: width,
                height: height
            ), adaptor.append(pixelBuffer, withPresentationTime: timestamp) else {
                throw CompositionOutputError.mediaWriterFailed(
                    writer.error?.localizedDescription ?? "A comparison frame could not be written."
                )
            }
            timestamp = CMTimeAdd(
                timestamp,
                CMTime(seconds: max(frame.duration, 0.02), preferredTimescale: 600)
            )
        }

        try await waitUntilReady(input, writer: writer)
        if let last = frames.last,
           let finalBuffer = pixelBuffer(image: last.image, width: width, height: height) {
            _ = adaptor.append(finalBuffer, withPresentationTime: timestamp)
        }
        writer.endSession(atSourceTime: timestamp)
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw CompositionOutputError.mediaWriterFailed(
                writer.error?.localizedDescription ?? "The video encoder could not finish."
            )
        }
    }

    private static func waitUntilReady(
        _ input: AVAssetWriterInput,
        writer: AVAssetWriter
    ) async throws {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            if writer.status == .failed || writer.status == .cancelled {
                throw CompositionOutputError.mediaWriterFailed(
                    writer.error?.localizedDescription ?? "The video encoder stopped."
                )
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func pixelBuffer(
        image: CGImage,
        width: Int,
        height: Int
    ) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: CFDictionary = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ] as CFDictionary
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes,
            &buffer
        ) == kCVReturnSuccess,
        let buffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(rect)
        context.draw(
            image,
            in: CGRect(
                x: (width - image.width) / 2,
                y: (height - image.height) / 2,
                width: image.width,
                height: image.height
            )
        )
        return buffer
    }

    // MARK: - PDF

    private struct PDFRenderSummary {
        let pageCount: Int
        let firstPixelSize: CGSize
        let wasScaled: Bool
    }

    private static func estimatedPageSnapshots(
        _ input: CompositionOutputInput,
        usesPDFPagination: Bool,
        forcedPDFItemsPerPage: Int?
    ) throws -> [EditorSnapshot] {
        guard usesPDFPagination,
              let composition = input.snapshot.composition,
              composition.layout.mode == .steps,
              let requestedItemsPerPage = forcedPDFItemsPerPage
                ?? composition.steps.itemsPerPage,
              requestedItemsPerPage > 0 else {
            return [input.snapshot]
        }
        let included = composition.items.filter(\.isIncluded)
        guard !included.isEmpty else {
            throw CompositionOutputError.noIncludedItems
        }

        let itemsPerPage = max(requestedItemsPerPage, 1)
        var snapshots: [EditorSnapshot] = []
        snapshots.reserveCapacity(
            Int(ceil(Double(included.count) / Double(itemsPerPage)))
        )
        for start in stride(from: 0, to: included.count, by: itemsPerPage) {
            try Task.checkCancellation()
            let end = min(start + itemsPerPage, included.count)
            var pageComposition = composition
            pageComposition.items = Array(included[start..<end])
            pageComposition.selectedItemIDs = []
            pageComposition.steps.startIndex = composition.steps.startIndex + start
            pageComposition.canvas = filteredCanvas(
                composition.canvas,
                visibleItemIDs: Set(pageComposition.items.map(\.id))
            )
            var pageSnapshot = input.snapshot
            pageSnapshot.composition = pageComposition
            snapshots.append(pageSnapshot)
        }
        return snapshots
    }

    private static func inputWithForcedPDFPagination(
        _ input: CompositionOutputInput,
        itemsPerPage: Int?
    ) -> CompositionOutputInput {
        guard let itemsPerPage,
              var composition = input.snapshot.composition else {
            return input
        }
        composition.steps.itemsPerPage = max(itemsPerPage, 1)
        var snapshot = input.snapshot
        snapshot.composition = composition
        return CompositionOutputInput(
            baseImage: input.baseImage,
            snapshot: snapshot,
            compositionAssets: input.compositionAssets,
            compositionAssetRepository:
                input.compositionAssetRepository,
            compositionAssetDescriptors:
                input.compositionAssetDescriptors,
            pinnedUIMapElements: input.pinnedUIMapElements,
            uiMapOverlayOptions: input.uiMapOverlayOptions,
            appearance: input.appearance,
            suppressesContentDiagnostics:
                input.suppressesContentDiagnostics
        )
    }

    private static func writePDF(
        _ input: CompositionOutputInput,
        maximumOutputDimension: Int?,
        to destination: URL
    ) throws -> PDFRenderSummary {
        let snapshots = try estimatedPageSnapshots(
            input,
            usesPDFPagination: true,
            forcedPDFItemsPerPage: nil
        )
        guard let firstSnapshot = snapshots.first else {
            throw CompositionOutputError.noIncludedItems
        }
        let first = try renderPresented(
            input,
            snapshot: firstSnapshot,
            phase: .primary,
            maximumOutputDimension: maximumOutputDimension
        )
        var firstMediaBox = CGRect(
            x: 0,
            y: 0,
            width: first.image.width,
            height: first.image.height
        )
        guard let context = CGContext(
            destination as CFURL,
            mediaBox: &firstMediaBox,
            nil
        ) else {
            throw CompositionOutputError.failedToEncode(format: .pdf)
        }
        var wasScaled = first.wasScaled
        for (index, snapshot) in snapshots.enumerated() {
            try Task.checkCancellation()
            let rendered = index == 0
                ? first
                : try renderPresented(
                    input,
                    snapshot: snapshot,
                    phase: .primary,
                    maximumOutputDimension: maximumOutputDimension
                )
            let image = rendered.image
            wasScaled = wasScaled || rendered.wasScaled
            let mediaBox = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.beginPDFPage([
                kCGPDFContextMediaBox as String: mediaBox,
            ] as CFDictionary)
            context.draw(image, in: mediaBox)
            context.endPDFPage()
        }
        context.closePDF()
        return PDFRenderSummary(
            pageCount: snapshots.count,
            firstPixelSize: CGSize(
                width: first.image.width,
                height: first.image.height
            ),
            wasScaled: wasScaled
        )
    }

    // MARK: - Offline HTML

    private static func renderedHTMLDocument(
        _ input: CompositionOutputInput
    ) throws -> CompositionHTMLDocument {
        guard let composition = input.snapshot.composition else {
            throw CompositionOutputError.compositionRequired(format: .html)
        }
        let title = composition.canvas.title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        switch composition.layout.mode {
        case .steps:
            let included = composition.items.filter(\.isIncluded)
            guard !included.isEmpty else {
                throw CompositionOutputError.noIncludedItems
            }
            let itemDimensionCap = htmlItemMaximumDimension(
                renderedImageCount: included.count
            )
            var htmlItems: [CompositionHTMLItem] = []
            htmlItems.reserveCapacity(included.count)
            for (index, item) in included.enumerated() {
                try Task.checkCancellation()
                var stepComposition = composition
                stepComposition.items = [item]
                stepComposition.selectedItemIDs = []
                stepComposition.steps.startIndex = composition.steps.startIndex + index
                stepComposition.canvas.title = ""
                stepComposition.canvas = filteredCanvas(
                    stepComposition.canvas,
                    visibleItemIDs: [item.id]
                )
                var stepSnapshot = input.snapshot
                stepSnapshot.composition = stepComposition
                let image = try renderPresented(
                    input,
                    snapshot: stepSnapshot,
                    phase: .primary,
                    maximumOutputDimension: itemDimensionCap
                ).image
                let label = composition.steps.label(for: index) ?? "\(index + 1)"
                // Item titles commonly mirror capture-window names or file
                // paths, so the privacy-safe HTML navigation derives only
                // from explicit step numbering and captions.
                let resolvedTitle = composition.steps.numberingStyle == .none
                    ? "Step"
                    : "Step \(label)"
                htmlItems.append(CompositionHTMLItem(
                    image: image,
                    title: resolvedTitle,
                    caption: composition.steps.showsCaptions
                        ? item.caption
                        : nil,
                    accessibilityLabel: item.accessibilityLabel
                        ?? "Rendered step \(label)",
                    stepLabel: composition.steps.numberingStyle == .none
                        ? nil
                        : label,
                    showsStepNumber: composition.steps.numberingStyle != .none
                ))
            }
            return CompositionHTMLDocument(
                title: title.isEmpty ? "Steps" : title,
                layout: .steps,
                items: htmlItems,
                languageTag: currentHTMLLanguageTag
            )

        case .compare:
            var flattenedComparison = composition
            flattenedComparison.comparison.mode = .blink
            flattenedComparison.comparison.showsLabels = false
            let visibleComparisonItemIDs = Set(
                [
                    flattenedComparison.comparison.primaryItemID,
                    flattenedComparison.comparison.secondaryItemID,
                ].compactMap { $0 }
            )
            flattenedComparison.canvas = filteredCanvas(
                flattenedComparison.canvas,
                visibleItemIDs: visibleComparisonItemIDs
            )
            var comparisonSnapshot = input.snapshot
            comparisonSnapshot.composition = flattenedComparison
            let before = try renderPresented(
                input,
                snapshot: comparisonSnapshot,
                phase: .primary,
                maximumOutputDimension: maximumAnimatedDimension
            ).image
            let after = try renderPresented(
                input,
                snapshot: comparisonSnapshot,
                phase: .secondary,
                maximumOutputDimension: maximumAnimatedDimension
            ).image
            var differenceComposition = composition
            differenceComposition.comparison.mode = .difference
            differenceComposition.comparison.showsLabels = false
            differenceComposition.canvas = filteredCanvas(
                differenceComposition.canvas,
                visibleItemIDs: visibleComparisonItemIDs
            )
            var differenceSnapshot = input.snapshot
            differenceSnapshot.composition = differenceComposition
            let differenceImage = try renderPresented(
                input,
                snapshot: differenceSnapshot,
                phase: .primary,
                maximumOutputDimension: maximumAnimatedDimension
            ).image
            let renderedDifference = CompositionHTMLItem(
                image: differenceImage,
                title: "Difference",
                accessibilityLabel: "Rendered difference between \(composition.comparison.primaryLabel) and \(composition.comparison.secondaryLabel)"
            )
            var changeHighlightComposition = composition
            changeHighlightComposition.comparison.mode = .changeHighlight
            changeHighlightComposition.comparison.showsLabels = false
            changeHighlightComposition.canvas = filteredCanvas(
                changeHighlightComposition.canvas,
                visibleItemIDs: visibleComparisonItemIDs
            )
            var changeHighlightSnapshot = input.snapshot
            changeHighlightSnapshot.composition = changeHighlightComposition
            let changeHighlightImage = try renderPresented(
                input,
                snapshot: changeHighlightSnapshot,
                phase: .primary,
                maximumOutputDimension: maximumAnimatedDimension
            ).image
            let renderedChangeHighlight = CompositionHTMLItem(
                image: changeHighlightImage,
                title: "Highlight Changes",
                accessibilityLabel: "Rendered change highlight between \(composition.comparison.primaryLabel) and \(composition.comparison.secondaryLabel)"
            )
            return CompositionHTMLDocument(
                title: title.isEmpty ? "Comparison" : title,
                layout: .comparison(htmlComparison(for: composition.comparison)),
                items: [
                    CompositionHTMLItem(
                        image: before,
                        title: composition.comparison.primaryLabel,
                        accessibilityLabel: "Rendered \(composition.comparison.primaryLabel) image"
                    ),
                    CompositionHTMLItem(
                        image: after,
                        title: composition.comparison.secondaryLabel,
                        accessibilityLabel: "Rendered \(composition.comparison.secondaryLabel) image"
                    ),
                ],
                renderedDifference: renderedDifference,
                renderedChangeHighlight: renderedChangeHighlight,
                languageTag: currentHTMLLanguageTag
            )

        case .auto, .row, .column, .grid, .freeform:
            throw CompositionOutputError.htmlRequiresStepsOrComparison
        }
    }

    private static func htmlComparison(
        for settings: CompositionComparisonSettings
    ) -> CompositionHTMLComparison {
        let mode: CompositionHTMLComparisonMode
        switch settings.mode {
        case .sideBySide:
            mode = .sideBySide
        case .overlay:
            mode = .overlay(
                afterOpacityPercent: Int(
                    (min(max(settings.overlayOpacity, 0), 1) * 100).rounded()
                )
            )
        case .wipe:
            mode = .wipe(
                axis: settings.axis == .horizontal ? .horizontal : .vertical,
                positionPercent: Int(
                    (min(max(settings.wipePosition, 0), 1) * 100).rounded()
                )
            )
        case .blink:
            mode = .blink(
                intervalMilliseconds: Int(
                    (min(max(settings.blinkInterval, 0.25), 10) * 1_000).rounded()
                ),
                poster: settings.posterFrame == .secondary ? .after : .before
            )
        case .difference:
            mode = .renderedDifference
        case .changeHighlight:
            mode = .renderedChangeHighlight
        }
        return CompositionHTMLComparison(
            mode: mode,
            beforeLabel: settings.primaryLabel,
            afterLabel: settings.secondaryLabel,
            wipeAxis: settings.axis == .horizontal ? .horizontal : .vertical,
            wipePositionPercent: Int(
                (min(max(settings.wipePosition, 0), 1) * 100).rounded()
            ),
            overlayOpacityPercent: Int(
                (min(max(settings.overlayOpacity, 0), 1) * 100).rounded()
            ),
            blinkIntervalMilliseconds: Int(
                (min(max(settings.blinkInterval, 0.25), 10) * 1_000).rounded()
            ),
            blinkPoster: settings.posterFrame == .secondary ? .after : .before,
            differenceVisibilityPercent: Int(
                (min(max(settings.differenceIntensity, 0), 1) * 100).rounded()
            )
        )
    }

    private static var currentHTMLLanguageTag: String {
        let identifier = Locale.current.identifier
        return String(identifier.split(separator: "@", maxSplits: 1)[0])
            .replacingOccurrences(of: "_", with: "-")
    }

    static func htmlItemMaximumDimension(
        renderedImageCount: Int
    ) -> Int {
        let count = max(renderedImageCount, 1)
        let perImagePixelBudget = max(
            CompositionHTMLExporter.maximumAggregateImagePixelCount / count,
            1
        )
        return min(
            maximumAnimatedDimension,
            max(1, Int(floor(sqrt(Double(perImagePixelBudget)))))
        )
    }

    private static func filteredCanvas(
        _ canvas: CompositionCanvasState,
        visibleItemIDs: Set<UUID>
    ) -> CompositionCanvasState {
        var filtered = canvas
        let keptIDs = Set(canvas.annotations.compactMap { annotation -> UUID? in
            guard let anchors = canvas.annotationAnchors[annotation.id] else {
                return annotation.id
            }
            let targets = [anchors.primary, anchors.secondary].compactMap { $0 }
            let referencedItemIDs = targets.compactMap { anchor -> UUID? in
                if case .itemNormalized(let itemID, _) = anchor.target {
                    return itemID
                }
                return nil
            }
            return referencedItemIDs.allSatisfy(visibleItemIDs.contains)
                ? annotation.id
                : nil
        })
        filtered.annotations.removeAll { !keptIDs.contains($0.id) }
        filtered.annotationAnchors = filtered.annotationAnchors.filter {
            keptIDs.contains($0.key)
        }
        filtered.selectedAnnotationIDs = []
        return filtered
    }

    // MARK: - Atomic destination

    private static func result(
        input: CompositionOutputInput,
        format: CompositionOutputFormat,
        destination: URL,
        pageCount: Int,
        image: CGImage?,
        wasScaled: Bool = false,
        wasSafetyScaled: Bool = false
    ) -> CompositionOutputResult {
        result(
            input: input,
            format: format,
            destination: destination,
            pageCount: pageCount,
            pixelSize: image.map {
                CGSize(width: $0.width, height: $0.height)
            },
            wasScaled: wasScaled,
            wasSafetyScaled: wasSafetyScaled
        )
    }

    private static func result(
        input: CompositionOutputInput,
        format: CompositionOutputFormat,
        destination: URL,
        pageCount: Int,
        pixelSize: CGSize?,
        wasScaled: Bool = false,
        wasSafetyScaled: Bool = false
    ) -> CompositionOutputResult {
        CompositionOutputResult(
            url: destination,
            format: format,
            appearance: input.appearance,
            pageCount: pageCount,
            pixelSize: pixelSize,
            wasScaledToAnimatedLimit: wasScaled,
            wasScaledToRasterSafetyLimit: wasSafetyScaled
        )
    }

    private static func temporaryURL(for destination: URL) -> URL {
        let pathExtension = destination.pathExtension
        let stem = destination.deletingPathExtension().lastPathComponent
        let suffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        return destination.deletingLastPathComponent().appendingPathComponent(
            "\(stem).\(UUID().uuidString).tmp\(suffix)"
        )
    }

    private static func atomicFile(
        _ destination: URL,
        operation: (URL) throws -> Void
    ) throws {
        let temporary = temporaryURL(for: destination)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try operation(temporary)
        try install(temporary, at: destination)
    }

    private static func atomicFileAsync(
        _ destination: URL,
        operation: (URL) async throws -> Void
    ) async throws {
        let temporary = temporaryURL(for: destination)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await operation(temporary)
        try Task.checkCancellation()
        try install(temporary, at: destination)
    }

    private static func install(_ temporary: URL, at destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }
}
