import Foundation

@MainActor
struct AppModelComposition {
    let environment: AppEnvironment
    let lifecycle: AppLifecycleModel
    let capture: CaptureWorkflowModel
    let permissions: PermissionWorkflowModel
    let documents: DocumentWorkflowModel
    let clipboard: ClipboardWorkflowModel
    let video: VideoWorkflowModel
    let guide: GuideWorkflowModel
    let archive: ArchiveWorkflowModel
    let tools: ToolWorkflowModel
    let automation: AutomationWorkflowModel
    let workflowCoordinator: AppWorkflowCoordinator
    let configuredArchiveLocationURL: URL?

    init(
        defaults: UserDefaults,
        environment providedEnvironment: AppEnvironment?,
        overrides: AppModelCompositionOverrides,
        shouldStartArchiveMaintenance: Bool
    ) {
        let context = AppModelCompositionContext(
            defaults: defaults,
            environment: providedEnvironment,
            overrides: overrides
        )
        let lifecycleWorkflow = Self.makeLifecycleWorkflow(context: context)
        let appWindowPresenter = Self.makeAppWindowPresenter(lifecycle: lifecycleWorkflow)
        let permissionWorkflow = Self.makePermissionWorkflow(context: context, lifecycle: lifecycleWorkflow)
        let captureWorkflow = Self.makeCaptureWorkflow(
            context: context,
            lifecycle: lifecycleWorkflow,
            permissions: permissionWorkflow,
            appWindowPresenter: appWindowPresenter
        )
        let clipboardWorkflow = Self.makeClipboardWorkflow(context: context)
        let videoWorkflow = Self.makeVideoWorkflow(
            context: context,
            lifecycle: lifecycleWorkflow,
            capture: captureWorkflow,
            permissions: permissionWorkflow,
            appWindowPresenter: appWindowPresenter
        )
        let guideWorkflow = Self.makeGuideWorkflow(
            context: context,
            lifecycle: lifecycleWorkflow,
            capture: captureWorkflow,
            permissions: permissionWorkflow,
            video: videoWorkflow,
            appWindowPresenter: appWindowPresenter
        )
        let archiveWorkflow = Self.makeArchiveWorkflow(
            context: context,
            lifecycle: lifecycleWorkflow,
            shouldStartArchiveMaintenance: shouldStartArchiveMaintenance
        )
        let documentWorkflow = Self.makeDocumentWorkflow(
            context: context,
            lifecycle: lifecycleWorkflow,
            capture: captureWorkflow,
            clipboard: clipboardWorkflow,
            video: videoWorkflow,
            archive: archiveWorkflow
        )
        let toolWorkflow = Self.makeToolWorkflow(context: context)
        let automationWorkflow = Self.makeAutomationWorkflow(
            context: context,
            capture: captureWorkflow,
            document: documentWorkflow,
            clipboard: clipboardWorkflow,
            guide: guideWorkflow
        )
        let workflowCoordinator = Self.makeWorkflowCoordinator(
            lifecycle: lifecycleWorkflow,
            permissions: permissionWorkflow,
            capture: captureWorkflow,
            documents: documentWorkflow,
            clipboard: clipboardWorkflow,
            video: videoWorkflow,
            guide: guideWorkflow,
            archive: archiveWorkflow,
            tools: toolWorkflow,
            automation: automationWorkflow
        )
        Self.wireWorkflowReferences(
            coordinator: workflowCoordinator,
            permissions: permissionWorkflow,
            capture: captureWorkflow,
            documents: documentWorkflow,
            clipboard: clipboardWorkflow,
            video: videoWorkflow,
            guide: guideWorkflow,
            archive: archiveWorkflow,
            tools: toolWorkflow
        )

        self.environment = context.environment
        self.lifecycle = lifecycleWorkflow
        self.capture = captureWorkflow
        self.permissions = permissionWorkflow
        self.documents = documentWorkflow
        self.clipboard = clipboardWorkflow
        self.video = videoWorkflow
        self.guide = guideWorkflow
        self.archive = archiveWorkflow
        self.tools = toolWorkflow
        self.automation = automationWorkflow
        self.workflowCoordinator = workflowCoordinator
        self.configuredArchiveLocationURL = context.configuredArchiveLocationURL
    }
}
