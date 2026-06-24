import Foundation

@MainActor
struct PermissionWorkflowDependencies {
    let capabilities: AppCapabilitySnapshot
    let permissions: any CapturePermissionServicing
    let scheduler: any Scheduling
    let lifecycle: any WorkflowLifecyclePresenting
}

enum PermissionGateResult {
    case granted(CapturePermissionStatus)
    case blocked(missing: [CapturePermissionRequirement])
    case unavailable

    var isGranted: Bool {
        if case .granted = self {
            return true
        }

        return false
    }
}

@MainActor
protocol PermissionGatekeeping: AnyObject {
    var permissionStatus: CapturePermissionStatus { get }
    var permissionSetupGuide: PermissionSetupGuide? { get }
    var activePermissionRequest: CapturePermissionRequirement? { get }

    func refreshPermissions()
    func preflight(_ requirements: [CapturePermissionRequirement], featureName: String) -> PermissionGateResult
    func requestPermission(_ requirement: CapturePermissionRequirement)
    func requestScreenRecordingAccess()
    func requestAccessibilityAccess()
    func requestNextMissingSetupRequirement()
    func openPermissionSettings(_ requirement: CapturePermissionRequirement)
    func presentPermissionSetupGuide(for requirement: CapturePermissionRequirement)
    func dismissPermissionSetupGuide()
    func revealAppForPermissionSetup()
    func copyAppPathForPermissionSetup()
    func openPermissionSettingsFromGuide()
    func checkPermissionSetupGuideStatus()
    func reconcileScreenRecordingPermissionDenied(after error: Error?)
    @discardableResult
    func reconcileScreenRecordingPermissionFailureIfNeeded(after error: Error) -> Bool
}
