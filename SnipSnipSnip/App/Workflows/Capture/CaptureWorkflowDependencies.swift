import CoreGraphics
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
    var chooseScrollingMode: @MainActor (CGDirectDisplayID?) async -> ScrollingCaptureMode? = {
        await ScrollingCaptureModeSelection.present(on: $0)
    }
    var confirmScrollingTarget: @MainActor (ScrollingCaptureTarget) async -> ScrollingCaptureTargetConfirmation.Choice = {
        await ScrollingCaptureTargetConfirmation.present(target: $0)
    }
}
