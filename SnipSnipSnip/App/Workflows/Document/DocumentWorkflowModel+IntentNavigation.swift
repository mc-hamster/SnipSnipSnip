import CoreGraphics
import Foundation

@MainActor
extension DocumentWorkflowModel {
    /// Branches one editable composition item into a new one-image Screenshot
    /// document. The source composition is not mutated; it is shelved through
    /// the same recoverable path used before a new capture replaces the active
    /// editor.
    func openCompositionItemAsNewScreenshot(_ itemID: UUID) {
        guard let sourceController = editorController,
              let item = sourceController.composition?.items.first(
                  where: { $0.id == itemID }
              ) else {
            return
        }

        do {
            let capture = try sourceController.compositionCapture(
                for: itemID
            )
            let fullImageRect = CGRect(
                origin: .zero,
                size: CGSize(
                    width: capture.image.width,
                    height: capture.image.height
                )
            )
            let itemSnapshot = EditorSnapshot(
                cropRect: item.editState.cropRect ?? fullImageRect,
                annotations: item.editState.annotations,
                selectedAnnotationIDs: [],
                nextCalloutNumber: item.editState.nextCalloutNumber,
                presentation: .plain,
                pinnedUIMapElementIDs:
                    item.editState.pinnedUIMapElementIDs,
                documentPurpose: .screenshot
            )
            let session = EditorDocumentSession(
                initialSnapshot: itemSnapshot,
                currentSnapshot: itemSnapshot,
                undoStack: [],
                redoStack: [],
                toolStyles: sourceController.toolStyles,
                savedPresentations: []
            )
            let selectedAssetIsPrivate = sourceController
                .compositionAssetRepository
                .storedAsset(for: item.assetID)?
                .descriptor.isPrivate == true
            let isPrivate =
                sourceController.isPrivateDocument
                || selectedAssetIsPrivate
            let newController = EditorController(
                capture: capture,
                session: session,
                capabilities: capabilities,
                uiMapOverlayOptions: uiMapPinnedOverlayDefaults,
                isPrivateDocument: isPrivate,
                workflowResumeState: ScreenshotWorkflowResumeState(
                    stage: .editing
                )
            )

            shelveCurrentDocumentForRecents()
            installEditorController(
                newController,
                documentURL: nil,
                savedSession: nil,
                shouldCreateRecoverySession: !isPrivate,
                initialCheckpointLabel:
                    isPrivate ? nil : "Opened Selected Capture"
            )
            newController.showNotice(
                "Opened the selected capture as a new Screenshot."
            )
            updateDocumentChangeTracking()
            requestMainWindowPresentation()
        } catch {
            present(error)
        }
    }
}
