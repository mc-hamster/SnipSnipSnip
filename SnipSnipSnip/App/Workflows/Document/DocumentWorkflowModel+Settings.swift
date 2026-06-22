import CoreGraphics
import Foundation

@MainActor
extension DocumentWorkflowModel {
    var editorCropOutsideOverlayDimmingDescription: String {
        String(format: "%d%% dimming", Int(round(editorCropOutsideOverlayAlpha * 100)))
    }

    var presentationScenesRootDescription: String {
        presentationScenesRootURL.path
    }

    var usesDefaultPresentationScenesRoot: Bool {
        presentationScenesRootURL.standardizedFileURL == PresentationSceneStore.defaultRootURL.standardizedFileURL
    }

    func updateEditorCropOutsideOverlayAlpha(_ value: CGFloat) {
        let clampedAlpha = EditorPreferenceStore.clampedCropOutsideOverlayAlpha(value)

        guard editorCropOutsideOverlayAlpha != clampedAlpha else {
            return
        }

        editorCropOutsideOverlayAlpha = clampedAlpha
    }

    func updateEditorOutOfCapturePatternSettings(_ settings: EditorOutOfCapturePatternSettings) {
        let sanitizedSettings = settings.sanitized()

        guard editorOutOfCapturePatternSettings != sanitizedSettings else {
            return
        }

        editorOutOfCapturePatternSettings = sanitizedSettings
    }

    func choosePresentationScenesRoot() {
        guard let selectedURL = dependencies.panels.selectPresentationScenesRoot(initialDirectory: presentationScenesRootURL) else {
            return
        }

        updatePresentationScenesRootURL(selectedURL)
    }

    func revealPresentationScenesRoot() {
        do {
            try systemServices.files.createDirectory(at: presentationScenesRootURL, withIntermediateDirectories: true)
            systemServices.workspace.activateFileViewerSelecting([presentationScenesRootURL])
        } catch {
            present(error)
        }
    }

    func resetPresentationScenesRootToDefault() {
        preferenceStore.savePresentationScenesRootURL(nil)
        updatePresentationScenesRootURL(PresentationSceneStore.defaultRootURL, persists: false)
    }

    func reloadPresentationScenes() {
        if let editorController {
            editorController.reloadPresentationScenes()
            return
        }

        do {
            _ = try PresentationSceneStore(rootURL: presentationScenesRootURL).reload()
        } catch {
            present(error)
        }
    }
}
