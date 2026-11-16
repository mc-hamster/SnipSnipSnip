import Foundation

@MainActor
extension PermissionWorkflowModel {
    func statusTitle(for requirement: CapturePermissionRequirement) -> String {
        if permissionStatus.hasAccess(to: requirement) { return String(localized: "Allowed") }
        if requirement == .screenRecording && screenRecordingSetupNeedsAttention { return String(localized: "Restart Required") }
        if activePermissionRequest == requirement { return String(localized: "Waiting for Access") }
        return String(localized: "Needs Setup")
    }

    func presentPermissionSetupGuide(for requirement: CapturePermissionRequirement) {
        refreshPermissions()

        guard !permissionStatus.hasAccess(to: requirement) else {
            permissionSetupGuide = nil
            if activePermissionRequest == requirement {
                activePermissionRequest = nil
            }
            return
        }

        permissionSetupGuide = PermissionSetupGuide(
            requirement: requirement,
            appName: dependencies.permissions.currentAppName,
            appPath: dependencies.permissions.currentAppPath
        )
    }

    func dismissPermissionSetupGuide() {
        screenRecordingVerificationMessage = nil
        dependencies.restartStore?.save(nil)
        permissionContinuation = nil
        permissionSetupGuide = nil
        activePermissionRequest = nil
        invalidateScreenRecordingVerification()
        permissionCheckTask?.cancel()
        permissionCheckTask = nil
        permissionCheckID = nil
        isCheckingPermission = false
        outputSink?.handle(.permissionSetupDismissed)
        refreshPermissions()
    }

    func revealAppForPermissionSetup() {
        dependencies.permissions.revealCurrentAppInFinder()
    }

    func copyAppPathForPermissionSetup() {
        dependencies.permissions.copyCurrentAppPathToPasteboard()
    }

    func openPermissionSettingsFromGuide() {
        guard let permissionSetupGuide else {
            return
        }

        openPermissionSettings(permissionSetupGuide.requirement)
    }

    func checkPermissionSetupGuideStatus() {
        guard !isCheckingPermission else { return }
        screenRecordingVerificationMessage = nil
        if permissionSetupGuide?.requirement != .accessibility {
            isCheckingPermission = true
            let checkID = UUID()
            permissionCheckID = checkID
            permissionCheckTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshPermissionsIncludingScreenRecordingProbe()
                guard self.permissionCheckID == checkID else { return }
                self.permissionCheckID = nil
                self.permissionCheckTask = nil
                self.isCheckingPermission = false
                self.clearPermissionSetupGuideIfSatisfied()
            }
            return
        }
        refreshPermissions()
        clearPermissionSetupGuideIfSatisfied()
    }

    private func clearPermissionSetupGuideIfSatisfied() {
        guard let permissionSetupGuide,
              permissionStatus.hasAccess(to: permissionSetupGuide.requirement) else {
            return
        }

        if permissionContinuation == nil { self.permissionSetupGuide = nil }
        if activePermissionRequest == permissionSetupGuide.requirement {
            activePermissionRequest = nil
        }
        if permissionSetupGuide.requirement == .screenRecording {
            clearScreenRecordingRestartRequired()
        }
        dependencies.lifecycle.clearError()
    }
}
