import Foundation

@MainActor
extension AppModelComposition {
    static func makeDocumentWorkflow(
        context: AppModelCompositionContext,
        lifecycle: AppLifecycleModel,
        capture: CaptureWorkflowModel,
        clipboard: ClipboardWorkflowModel,
        video: VideoWorkflowModel,
        archive: ArchiveWorkflowModel
    ) -> DocumentWorkflowModel {
        DocumentWorkflowModel(
            dependencies: DocumentWorkflowDependencies(
                capabilities: context.environment.capabilities,
                systemServices: context.environment.systemServices,
                lifecycle: lifecycle,
                capture: capture,
                clipboard: clipboard,
                video: video,
                archive: archive,
                panels: LiveDocumentPanelPresenter(),
                windowPresenter: LiveDocumentWindowPresenter(screens: context.environment.systemServices.screens),
                pasteboardImporter: LiveDocumentPasteboardImporter(),
                floatingReferenceCoordinator: context.floatingReferenceCoordinator,
                historyPreviewCoordinator: context.historyPreviewCoordinator,
                textRecognitionCoordinator: CaptureTextRecognitionCoordinator(
                    files: context.environment.systemServices.files,
                    scheduler: context.environment.systemServices.scheduler
                )
            ),
            recoveryStore: context.recoveryStore,
            videoRecoveryStore: context.videoRecoveryStore,
            incompatibleDocumentCoordinator: context.overrides.incompatibleDocumentCoordinator,
            preferenceStore: context.preferenceStores.editor,
            pendingRecoverySession: context.pendingRecoverySession,
            allCaptureHistoryEntries: context.recoveryStore.allHistoryEntries(limit: DocumentWorkflowConstants.captureHistoryLimit),
            recentSnipEntries: context.recoveryStore.pendingRecoveryEntries(limit: DocumentWorkflowConstants.recentSnipLimit),
            recycleBinEntries: context.recoveryStore.recycledHistoryEntries(limit: DocumentWorkflowConstants.recycleBinLimit)
        )
    }

    static func makeToolWorkflow(context: AppModelCompositionContext) -> ToolWorkflowModel {
        let screenRulerPreferences = context.preferenceStores.screenTools.loadRulerPreferences()
        let screenInspectorPreferences = context.preferenceStores.screenTools.loadInspectorPreferences()
        return ToolWorkflowModel(
            screenRulerCoordinator: ScreenRulerCoordinator(preferences: screenRulerPreferences),
            screenInspectorCoordinator: ScreenInspectorCoordinator(
                preferences: screenInspectorPreferences,
                capturePlatform: context.overrides.screenInspectorCapturePlatform
                    ?? context.environment.systemServices.screenCapturePlatform,
                screens: context.environment.systemServices.screens,
                permissions: context.environment.permissions
            ),
            preferenceStore: context.preferenceStores.screenTools,
            screenRulerPreferences: screenRulerPreferences,
            screenInspectorPreferences: screenInspectorPreferences
        )
    }

    static func makeAutomationWorkflow(
        context: AppModelCompositionContext,
        capture: CaptureWorkflowModel,
        document: DocumentWorkflowModel,
        clipboard: ClipboardWorkflowModel,
        guide: GuideWorkflowModel
    ) -> AutomationWorkflowModel {
        AutomationWorkflowModel(
            statusPort: capture,
            capturePort: capture,
            documentPort: document,
            clipboardPort: clipboard,
            guidePort: guide,
            files: context.environment.systemServices.files,
            workspace: context.environment.systemServices.workspace,
            pasteboard: context.environment.systemServices.pasteboard
        )
    }
}
