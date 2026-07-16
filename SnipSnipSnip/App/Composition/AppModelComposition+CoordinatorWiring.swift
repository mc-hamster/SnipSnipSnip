import Foundation

@MainActor
extension AppModelComposition {
    static func makeWorkflowCoordinator(
        lifecycle: any CoordinatorLifecyclePort,
        permissions: any CoordinatorPermissionPort,
        capture: any CoordinatorCapturePort,
        documents: any CoordinatorDocumentPort,
        clipboard: any CoordinatorClipboardPort,
        video: any CoordinatorVideoPort,
        guide: any CoordinatorGuidePort,
        archive: any CoordinatorArchivePort,
        tools: any CoordinatorToolPort,
        automation: any CoordinatorAutomationPort
    ) -> AppWorkflowCoordinator {
        AppWorkflowCoordinator(
            lifecycle: lifecycle,
            permissions: permissions,
            capture: capture,
            documents: documents,
            clipboard: clipboard,
            video: video,
            guide: guide,
            archive: archive,
            tools: tools,
            automation: automation
        )
    }

    static func wireWorkflowReferences(
        coordinator: AppWorkflowCoordinator,
        permissions: PermissionWorkflowModel,
        capture: CaptureWorkflowModel,
        documents: DocumentWorkflowModel,
        clipboard: ClipboardWorkflowModel,
        video: VideoWorkflowModel,
        guide: GuideWorkflowModel,
        archive: ArchiveWorkflowModel,
        tools: ToolWorkflowModel
    ) {
        permissions.outputSink = coordinator
        capture.outputSink = coordinator
        capture.automationCoordinator = coordinator
        capture.documents = documents
        capture.video = video
        capture.guide = guide
        documents.automationCoordinator = coordinator
        clipboard.outputSink = coordinator
        clipboard.documents = documents
        video.documents = documents
        guide.outputSink = coordinator
        archive.documents = documents
        tools.outputSink = coordinator
    }
}
