import CoreGraphics
import Foundation

extension EditorController {
    var supportsAnimatedCompositionOutput: Bool {
        guard let composition = snapshot.composition else {
            return false
        }
        return composition.layout.mode == .compare
            && composition.comparison.mode == .blink
            && composition.items.filter(\.isIncluded).count >= 2
    }

    var supportsInteractiveCompositionHTML: Bool {
        guard let composition = snapshot.composition else {
            return false
        }
        switch composition.layout.mode {
        case .steps:
            return composition.items.contains(where: \.isIncluded)
        case .compare:
            return composition.items.filter(\.isIncluded).count >= 2
        case .auto, .row, .column, .grid, .freeform:
            return false
        }
    }

    func compositionOutputInput(
        appearance: ScreenshotOutputAppearance
    ) throws -> CompositionOutputInput {
        commitPendingTextEdits()
        var outputSnapshot = snapshot
        switch appearance {
        case .plain:
            outputSnapshot.presentation = .plain
        case .styled:
            guard outputSnapshot.presentation.isEnabled else {
                throw ScreenshotOutputError.styledOutputNotConfigured
            }
        }
        return CompositionOutputInput(
            baseImage: capture.image,
            snapshot: outputSnapshot,
            compositionAssets: [:],
            compositionAssetRepository: compositionAssetRepository,
            compositionAssetDescriptors:
                compositionAssetRepository.descriptors,
            pinnedUIMapElements: pinnedUIMapElements,
            uiMapOverlayOptions: uiMapOverlayOptions,
            appearance: appearance,
            suppressesContentDiagnostics: isPrivateDocument
        )
    }

    func exportComposition(
        format: CompositionOutputFormat,
        appearance: ScreenshotOutputAppearance,
        to destination: URL,
        imageOptions: ImageExportOptions = .default
    ) async throws -> CompositionOutputResult {
        let input = try compositionOutputInput(appearance: appearance)
        if appearance == .styled,
           snapshot.presentation.requiresPNGForFaithfulExport,
           format != .png,
           format != .gif,
           format != .apng,
           format != .mp4,
           format != .html {
            throw CompositionOutputError.transparentPresentationRequiresPNG
        }
        return try await CompositionOutputExporter.export(
            input,
            format: format,
            to: destination,
            imageOptions: imageOptions
        )
    }
}
