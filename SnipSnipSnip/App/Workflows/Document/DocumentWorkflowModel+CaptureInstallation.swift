import Foundation

extension DocumentWorkflowModel {
    @discardableResult
    func installCapturedScreenshot(
        _ result: CaptureWorkflowResult
    ) -> CaptureInstallationResult {
        switch result.intent {
        case .newDocument:
            return .newDocument(installNewCapturedScreenshot(result))
        case let .append(documentGenerationID, afterItemID):
            guard let controller = editorController,
                  controller.documentGenerationID
                    == documentGenerationID,
                  afterItemID == nil
                    || controller.snapshot.composition?.items.contains(
                        where: { $0.id == afterItemID }
                    ) == true else {
                return handleStaleCompositionCapture(result)
            }
            return appendCapturedScreenshot(
                result,
                to: controller,
                afterItemID: afterItemID
            )
        case let .replace(documentGenerationID, itemID):
            guard let controller = editorController,
                  controller.documentGenerationID
                    == documentGenerationID,
                  controller.snapshot.composition?.items.contains(
                      where: { $0.id == itemID }
                  ) == true else {
                return handleStaleCompositionCapture(result)
            }
            return replaceCapturedScreenshot(
                result,
                in: controller,
                itemID: itemID
            )
        }
    }

    private func appendCapturedScreenshot(
        _ result: CaptureWorkflowResult,
        to controller: EditorController,
        afterItemID: UUID?
    ) -> CaptureInstallationResult {
        controller.beginCoalescedEditorGesture()
        do {
            let insertion = try controller.appendCaptureToComposition(
                result.capture,
                isPrivate: result.isPrivateCapture,
                afterItemID: afterItemID
            )
            applyCaptureCompletionRole(
                result.completionRole,
                afterAppendingTo: controller
            )
            controller.endCoalescedEditorGesture()
            routeToFocusedContentWorkspace(
                for: result.completionRole,
                in: controller
            )
            finishCompositionCaptureInstallation(
                result,
                in: controller
            )
            return CaptureInstallationResult(
                controller: controller,
                disposition: .appended,
                itemID: insertion.itemID,
                assetID: insertion.assetID
            )
        } catch {
            controller.cancelCoalescedEditorGesture()
            return failedCaptureInstallation(error)
        }
    }

    private func replaceCapturedScreenshot(
        _ result: CaptureWorkflowResult,
        in controller: EditorController,
        itemID: UUID
    ) -> CaptureInstallationResult {
        do {
            let insertion = try controller.replaceCompositionItem(
                itemID: itemID,
                with: result.capture,
                isPrivate: result.isPrivateCapture
            )
            finishCompositionCaptureInstallation(
                result,
                in: controller
            )
            return CaptureInstallationResult(
                controller: controller,
                disposition: .replaced,
                itemID: insertion.itemID,
                assetID: insertion.assetID
            )
        } catch {
            return failedCaptureInstallation(error)
        }
    }

    private func finishCompositionCaptureInstallation(
        _ result: CaptureWorkflowResult,
        in controller: EditorController
    ) {
        if result.shouldProcessUIMap {
            controller.beginUIMapProcessing()
        }
        if result.isPrivateCapture {
            excludeCurrentPrivateDocumentFromRecoveryAndHistory()
        }
        updateDocumentChangeTracking()
    }

    private func installNewCapturedScreenshot(
        _ result: CaptureWorkflowResult,
        completionRole: CaptureCompletionRole? = nil
    ) -> EditorController {
        shelveCurrentDocumentForRecents()
        let workflow = captureWorkflowConfiguration(
            for: completionRole ?? result.completionRole
        )
        let controller = EditorController(
            capture: result.capture,
            capabilities: capabilities,
            uiMapOverlayOptions: uiMapPinnedOverlayDefaults,
            isPrivateDocument: result.isPrivateCapture,
            documentPurpose: workflow.purpose,
            workflowResumeState: workflow.resumeState
        )
        routeToFocusedContentWorkspace(
            for: completionRole ?? result.completionRole,
            in: controller
        )
        if result.shouldProcessUIMap {
            controller.beginUIMapProcessing()
        }
        installEditorController(
            controller,
            documentURL: nil,
            savedSession: nil,
            shouldCreateRecoverySession: !result.isPrivateCapture,
            initialCheckpointLabel:
                result.isPrivateCapture ? nil : result.checkpointLabel
        )
        return controller
    }

    private func handleStaleCompositionCapture(
        _ result: CaptureWorkflowResult
    ) -> CaptureInstallationResult {
        if result.isPrivateCapture {
            let controller = installNewCapturedScreenshot(
                result,
                completionRole: .standalone
            )
            controller.showNotice(
                "The original composition changed, so the private capture opened in a separate editor."
            )
            return .newDocument(controller)
        }

        do {
            let detachedController = EditorController(
                capture: result.capture,
                capabilities: capabilities,
                uiMapOverlayOptions: uiMapPinnedOverlayDefaults,
                documentPurpose: .screenshot,
                workflowResumeState: ScreenshotWorkflowResumeState(
                    stage: .editing
                )
            )
            let preview = try detachedController.exportedImage(
                appearance: .plain
            )
            let sessionID = try recoveryStore.createSession(
                title: result.capture.sourceName,
                sourceDocumentURL: nil
            )
            try recoveryStore.saveCheckpoint(
                sessionID: sessionID,
                title: result.capture.sourceName,
                sourceDocumentURL: nil,
                label: "Recent Snip",
                document: detachedController.editableDocument,
                previewImage: preview,
                pendingRecovery: true,
                hasUnsavedChanges: true,
                includeUIMapSearchText: windowUIMapEnabled
            )
            refreshRecoveryPresentationState()
            editorController?.showNotice(
                "The composition changed before capture finished. The capture was kept in Recent Snips."
            )
            return CaptureInstallationResult(
                controller: nil,
                disposition: .unattachedRecent,
                itemID: nil,
                assetID: nil
            )
        } catch {
            return failedCaptureInstallation(error)
        }
    }

    private func failedCaptureInstallation(
        _ error: Error
    ) -> CaptureInstallationResult {
        present(error)
        return CaptureInstallationResult(
            controller: nil,
            disposition: .discarded,
            itemID: nil,
            assetID: nil
        )
    }

    func captureWorkflowConfiguration(
        for role: CaptureCompletionRole
    ) -> (
        purpose: ScreenshotDocumentPurpose,
        resumeState: ScreenshotWorkflowResumeState
    ) {
        switch role {
        case .comparisonBefore:
            return (
                .comparison,
                ScreenshotWorkflowResumeState(
                    stage: .awaitingComparisonAfter
                )
            )
        case .step:
            return (
                .steps,
                ScreenshotWorkflowResumeState(stage: .collecting)
            )
        case .collectionItem:
            return (
                .collection,
                ScreenshotWorkflowResumeState(stage: .collecting)
            )
        case .standalone, .comparisonAfter, .replacement:
            return (
                .screenshot,
                ScreenshotWorkflowResumeState(stage: .editing)
            )
        }
    }

    func applyCaptureCompletionRole(
        _ role: CaptureCompletionRole,
        afterAppendingTo controller: EditorController
    ) {
        switch role {
        case .comparisonBefore:
            controller.setDocumentPurpose(
                .comparison,
                layoutMode: .compare
            )
            controller.setWorkflowStage(.awaitingComparisonAfter)
        case .comparisonAfter:
            controller.setDocumentPurpose(
                .comparison,
                layoutMode: .compare
            )
            controller.setWorkflowStage(.reviewingComparison)
        case .step:
            controller.setDocumentPurpose(.steps, layoutMode: .steps)
            controller.setWorkflowStage(.collecting)
        case .collectionItem:
            controller.setDocumentPurpose(
                .collection,
                layoutMode: .auto
            )
            controller.setWorkflowStage(.arranging)
        case .standalone:
            applyInheritedPurposeAfterAppend(to: controller)
        case .replacement:
            break
        }
    }

    /// Stage navigation is resume state, not document content. Route successful
    /// creation and append operations to the goal's focused workspace without
    /// creating undo history or a dirty document transition.
    func routeToFocusedContentWorkspace(
        for role: CaptureCompletionRole,
        in controller: EditorController
    ) {
        switch role {
        case .standalone:
            if controller.documentPurpose == .screenshot {
                controller.setWorkspaceMode(.edit)
            } else {
                controller.presentationInspectorTab = .layout
                controller.setWorkspaceMode(.presentation)
            }
        case .comparisonBefore:
            controller.setWorkspaceMode(.edit)
        case .comparisonAfter, .step, .collectionItem:
            controller.presentationInspectorTab = .layout
            controller.setWorkspaceMode(.presentation)
        case .replacement:
            break
        }
    }

    /// Technical append callers, including v1 automation, inherit an existing
    /// focused workflow. A one-image Screenshot has no multi-item intent to
    /// inherit, so its first non-interactive append deterministically promotes
    /// it to a Collection with Auto layout.
    private func applyInheritedPurposeAfterAppend(
        to controller: EditorController
    ) {
        switch controller.documentPurpose {
        case .screenshot:
            controller.setDocumentPurpose(
                .collection,
                layoutMode: .auto
            )
            controller.setWorkflowStage(.arranging)
        case .comparison:
            if controller.includedCompositionItemCount >= 2,
               controller.workflowStage == .awaitingComparisonAfter {
                controller.setWorkflowStage(.reviewingComparison)
            }
        case .steps:
            controller.setWorkflowStage(.collecting)
        case .collection:
            if controller.workflowStage != .collecting {
                controller.setWorkflowStage(.arranging)
            }
        }
    }
}
