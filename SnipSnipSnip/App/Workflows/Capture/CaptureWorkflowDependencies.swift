import Foundation

@MainActor
struct CaptureWorkflowDependencies {
    let capabilities: AppCapabilitySnapshot
    let systemServices: AppSystemServices
    let appWindowPresenter: any AppWindowPresenting
    let permissions: any PermissionGatekeeping
    let lifecycle: any WorkflowLifecyclePresenting
    let makeScrollingCaptureService: (any ScreenCaptureServiceType) -> ScrollingCaptureService
    let preferenceStore: CapturePreferenceStore
    let automationPreferenceStore: AutomationPreferenceStore
    var chooseScrollingMode: () -> ScrollingCaptureMode? = {
        ScrollingCaptureModeSelection.present()
    }
    var confirmScrollingTarget: (ScrollingCaptureTarget) -> ScrollingCaptureTargetConfirmation.Choice = {
        ScrollingCaptureTargetConfirmation.present(target: $0)
    }
}
