import Foundation

@MainActor
extension PermissionWorkflowModel {
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
        permissionSetupGuide = nil

        guard activePermissionRequest == .screenRecording else {
            activePermissionRequest = nil
            refreshPermissions()
            return
        }

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            await self.refreshPermissionsIncludingScreenRecordingProbe()

            guard self.activePermissionRequest == .screenRecording,
                  !self.permissionStatus.hasScreenRecording else {
                return
            }

            self.markScreenRecordingRestartRequired()
        }
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
        if activePermissionRequest == .screenRecording || permissionSetupGuide?.requirement == .screenRecording {
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                await self.refreshPermissionsIncludingScreenRecordingProbe()
                self.clearPermissionSetupGuideIfSatisfied()

                guard self.activePermissionRequest == .screenRecording,
                      !self.permissionStatus.hasScreenRecording else {
                    return
                }

                self.markScreenRecordingRestartRequired()
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

        self.permissionSetupGuide = nil
        if activePermissionRequest == permissionSetupGuide.requirement {
            activePermissionRequest = nil
        }
        if permissionSetupGuide.requirement == .screenRecording {
            clearScreenRecordingRestartRequired()
        }
        dependencies.lifecycle.clearError()
    }
}
