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
        archive: ArchiveWorkflowModel,
        tools: ToolWorkflowModel
    ) {
        permissions.outputSink = coordinator
        capture.outputSink = coordinator
        capture.automationCoordinator = coordinator
        capture.documents = documents
        capture.video = video
        documents.automationCoordinator = coordinator
        clipboard.outputSink = coordinator
        clipboard.documents = documents
        video.documents = documents
        archive.documents = documents
        tools.outputSink = coordinator
    }
}
