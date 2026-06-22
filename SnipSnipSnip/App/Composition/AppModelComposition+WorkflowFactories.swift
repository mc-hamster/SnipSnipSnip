import Foundation

@MainActor
extension AppModelComposition {
    static func makeLifecycleWorkflow(context: AppModelCompositionContext) -> AppLifecycleModel {
        AppLifecycleModel(
            capabilities: context.environment.capabilities,
            preferenceStore: context.preferenceStores.lifecycle,
            confirmsBeforeQuitting: context.preferenceStores.lifecycle.loadConfirmsBeforeQuitting(),
            launchAtLoginController: context.overrides.launchAtLoginController,
            workspace: context.environment.systemServices.workspace,
            shouldPresentOnboardingWindowOnLaunch: context.shouldPresentOnboardingWindowOnLaunch,
            shouldPresentMainWindowOnLaunch: context.shouldPresentMainWindowOnLaunch
        )
    }

    static func makeAppWindowPresenter(lifecycle: AppLifecycleModel) -> any AppWindowPresenting {
        LiveAppWindowPresenter {
            lifecycle.requestMainWindowPresentation()
        }
    }

    static func makePermissionWorkflow(
        context: AppModelCompositionContext,
        lifecycle: AppLifecycleModel
    ) -> PermissionWorkflowModel {
        PermissionWorkflowModel(
            dependencies: PermissionWorkflowDependencies(
                capabilities: context.environment.capabilities,
                permissions: context.environment.permissions,
                scheduler: context.environment.systemServices.scheduler,
                lifecycle: lifecycle
            )
        )
    }

    static func makeCaptureWorkflow(
        context: AppModelCompositionContext,
        lifecycle: AppLifecycleModel,
        permissions: PermissionWorkflowModel,
        appWindowPresenter: any AppWindowPresenting
    ) -> CaptureWorkflowModel {
        CaptureWorkflowModel(
            dependencies: CaptureWorkflowDependencies(
                capabilities: context.environment.capabilities,
                systemServices: context.environment.systemServices,
                appWindowPresenter: appWindowPresenter,
                permissions: permissions,
                lifecycle: lifecycle,
                makeScrollingCaptureService: { captureService in
                    context.environment.makeScrollingCaptureService(captureService: captureService)
                },
                preferenceStore: context.preferenceStores.capture,
                automationPreferenceStore: context.preferenceStores.automation
            ),
            captureService: context.overrides.captureService ?? context.environment.makeScreenCaptureService(),
            uiMapCaptureService: context.overrides.uiMapCaptureService ?? context.environment.makeUIMapCaptureService(),
            connectedDeviceCaptureService: context.overrides.connectedDeviceCaptureService ?? context.environment.makeConnectedDeviceCaptureService()
        )
    }

    static func makeClipboardWorkflow(context: AppModelCompositionContext) -> ClipboardWorkflowModel {
        let clipboardMonitor = ClipboardMonitor(
            store: context.clipboardHistoryStore,
            pasteboard: context.environment.systemServices.pasteboard,
            workspace: context.environment.systemServices.workspace
        )
        return ClipboardWorkflowModel(
            dependencies: ClipboardWorkflowDependencies(
                systemServices: context.environment.systemServices,
                ignoredAppPresenter: LiveClipboardIgnoredAppPresenter(),
                managerPresenter: LiveClipboardManagerPresenter()
            ),
            historyStore: context.clipboardHistoryStore,
            monitor: clipboardMonitor,
            pasteboard: context.environment.systemServices.pasteboard,
            preferenceStore: context.preferenceStores.clipboard
        )
    }

    static func makeVideoWorkflow(
        context: AppModelCompositionContext,
        lifecycle: AppLifecycleModel,
        capture: CaptureWorkflowModel,
        permissions: PermissionWorkflowModel,
        appWindowPresenter: any AppWindowPresenting
    ) -> VideoWorkflowModel {
        VideoWorkflowModel(
            dependencies: VideoWorkflowDependencies(
                capabilities: context.environment.capabilities,
                systemServices: context.environment.systemServices,
                appWindowPresenter: appWindowPresenter,
                permissions: permissions,
                lifecycle: lifecycle,
                capture: capture
            ),
            recordingService: context.overrides.screenRecordingService ?? context.environment.makeScreenRecordingService(),
            preferenceStore: context.preferenceStores.video
        )
    }

    static func makeArchiveWorkflow(
        context: AppModelCompositionContext,
        lifecycle: AppLifecycleModel,
        shouldStartArchiveMaintenance: Bool
    ) -> ArchiveWorkflowModel {
        let archiveWorkflow = ArchiveWorkflowModel(
            dependencies: ArchiveWorkflowDependencies(
                systemServices: context.environment.systemServices,
                lifecycle: lifecycle,
                locationPresenter: LiveArchiveLocationPresenter()
            ),
            recoveryStore: context.recoveryStore,
            configuredArchiveLocationURL: context.configuredArchiveLocationURL,
            preferenceStore: context.preferenceStores.archive
        )
        archiveWorkflow.shouldStartMaintenance = shouldStartArchiveMaintenance
        return archiveWorkflow
    }
}
