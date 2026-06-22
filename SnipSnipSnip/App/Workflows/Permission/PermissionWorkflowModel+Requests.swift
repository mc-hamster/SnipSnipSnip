import Foundation

@MainActor
extension PermissionWorkflowModel {
    func refreshPermissions() {
        let status = dependencies.permissions.currentStatus()
        if status != permissionStatus {
            permissionStatus = status
        }

        reconcileVerifiedScreenRecordingAccess(using: status)
    }

    func preflight(_ requirements: [CapturePermissionRequirement], featureName: String) -> PermissionGateResult {
        guard !requirements.isEmpty else {
            return .granted(permissionStatus)
        }

        refreshPermissions()

        let missingRequirements = requirements.filter { !permissionStatus.hasAccess(to: $0) }

        guard let firstMissingRequirement = missingRequirements.first else {
            return .granted(permissionStatus)
        }

        requestPermission(firstMissingRequirement)
        refreshPermissions()

        let stillMissingRequirements = requirements.filter { !permissionStatus.hasAccess(to: $0) }

        guard stillMissingRequirements.isEmpty else {
            dependencies.lifecycle.clearError()
            dependencies.lifecycle.requestMainWindowPresentation()
            return .blocked(missing: stillMissingRequirements)
        }

        if requirements.contains(.screenRecording) {
            refreshPermissions()
        }

        return .granted(permissionStatus)
    }

    func requestPermission(_ requirement: CapturePermissionRequirement) {
        guard dependencies.permissions.canRequest(requirement) else {
            permissionSetupGuide = nil
            return
        }

        _ = dependencies.permissions.requestAccess(for: requirement)
        refreshPermissions()

        if permissionStatus.hasAccess(to: requirement) {
            permissionSetupGuide = nil
            return
        }

        switch requirement {
        case .accessibility:
            openAccessibilitySettingsAfterPromptOpportunity()
            presentPermissionSetupGuide(for: .accessibility)
        case .screenRecording:
            openScreenRecordingSettingsAfterPromptOpportunity()
            presentPermissionSetupGuide(for: .screenRecording)
        }
    }

    func requestScreenRecordingAccess() {
        requestPermission(.screenRecording)
    }

    func requestAccessibilityAccess() {
        guard dependencies.permissions.canRequest(.accessibility) else {
            return
        }

        requestPermission(.accessibility)
    }

    func requestNextMissingSetupRequirement() {
        refreshPermissions()

        let missingRequirements = dependencies.permissions.availableSetupRequirements().filter {
            !permissionStatus.hasAccess(to: $0)
        }

        guard let nextRequirement = missingRequirements.first else {
            return
        }

        requestPermission(nextRequirement)
    }

    func openPermissionSettings(_ requirement: CapturePermissionRequirement) {
        dependencies.permissions.openSystemSettings(for: requirement)
        refreshPermissions()
    }

    private func openScreenRecordingSettingsAfterPromptOpportunity() {
        Task { @MainActor [weak self] in
            try? await self?.dependencies.scheduler.sleep(nanoseconds: 350_000_000)
            guard let self else {
                return
            }

            self.refreshPermissions()

            guard !self.permissionStatus.hasScreenRecording else {
                self.permissionSetupGuide = nil
                return
            }

            self.dependencies.permissions.openSystemSettings(for: .screenRecording)
            self.presentPermissionSetupGuide(for: .screenRecording)
        }
    }

    private func openAccessibilitySettingsAfterPromptOpportunity() {
        guard dependencies.permissions.canRequest(.accessibility) else {
            return
        }

        Task { @MainActor [weak self] in
            try? await self?.dependencies.scheduler.sleep(nanoseconds: 350_000_000)
            guard let self else {
                return
            }

            self.refreshPermissions()

            guard !self.permissionStatus.hasAccessibility else {
                self.permissionSetupGuide = nil
                return
            }

            self.dependencies.permissions.openSystemSettings(for: .accessibility)
            self.presentPermissionSetupGuide(for: .accessibility)
        }
    }
}
