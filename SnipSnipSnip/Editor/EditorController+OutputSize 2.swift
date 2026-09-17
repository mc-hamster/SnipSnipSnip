import CoreGraphics

@MainActor
extension EditorController {
    func originalOutputPixelSize(for appearance: ScreenshotOutputAppearance) throws -> CGSize {
        var output = documentSession.currentSnapshot
        if appearance == .plain { output.presentation = .plain }
        if output.composition?.isActivated == true {
            let input = CompositionOutputInput(baseImage: documentCapture.image, snapshot: output,
                compositionAssets: [:], compositionAssetRepository: compositionAssetRepository,
                pinnedUIMapElements: pinnedUIMapElements, uiMapOverlayOptions: uiMapOverlayOptions,
                appearance: appearance, suppressesContentDiagnostics: isPrivateDocument)
            return try CompositionOutputExporter.preflight(input, format: .png).estimatedPixelSize
        }
        return ScreenshotPresentationRenderer.outputSize(for: output.cropRect.size, presentation: output.presentation)
    }
}
