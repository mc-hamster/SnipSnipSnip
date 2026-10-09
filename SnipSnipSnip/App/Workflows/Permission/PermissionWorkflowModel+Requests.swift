import Foundation

@MainActor
extension PermissionWorkflowModel {
    func refreshPermissions() {
        refreshMediaPermissions()
        let currentStatus = dependencies.permissions.currentStatus()
        reconcileScreenRecordingPreflightChange(currentStatus)
        let status = effectivePermissionStatus(from: currentStatus)
        let didChangeStatus = status != permissionStatus
        if didChangeStatus {
            permissionStatus = status
            PermissionWorkflowDiagnostics.debugState(
                "refreshPermissions",
                rawStatus: currentStatus,
                effectiveStatus: status,
                activeRequest: activePermissionRequest,
                setupGuide: permissionSetupGuide?.requirement,
                screenRecordingSetupStartedThisRun: screenRecordingSetupStartedThisRun,
                screenRecordingSetupNeedsAttention: screenRecordingSetupNeedsAttention,
                hasVerifiedScreenRecordingAccess: hasVerifiedScreenRecordingAccess
            )
        }

        if screenRecordingSetupRequiresRestart(for: currentStatus) {
            markScreenRecordingRestartRequired()
        } else if status.hasScreenRecording {
            clearScreenRecordingRestartRequired()
        }

        if let activePermissionRequest,
           hasVerifiedAccess(to: activePermissionRequest, in: status) {
            self.activePermissionRequest = nil
            if permissionContinuation == nil { permissionSetupGuide = nil }
        }
        if permissionContinuation == nil, let guide = permissionSetupGuide,
           status.hasAccess(to: guide.requirement) {
            permissionSetupGuide = nil
        }
        updateContinuationGuide()

        // Status refresh never enumerates screen content. That operation can
        // show a macOS consent alert; use the explicit Check Again action.
    }

    func effectivePermissionStatus(from status: CapturePermissionStatus) -> CapturePermissionStatus {
        let hasScreenRecording: Bool
        if screenRecordingSetupRequiresRestart(for: status) {
            hasScreenRecording = false
        } else if requiresVerifiedScreenRecordingReadiness() {
            hasScreenRecording = hasVerifiedScreenRecordingAccess
        } else {
            hasScreenRecording = status.hasScreenRecording || hasVerifiedScreenRecordingAccess
        }

        return CapturePermissionStatus(
            hasScreenRecording: hasScreenRecording,
            hasAccessibility: status.hasAccessibility
        )
    }

    private func hasVerifiedAccess(
        to requirement: CapturePermissionRequirement,
        in status: CapturePermissionStatus
    ) -> Bool {
        switch requirement {
        case .screenRecording:
            return status.hasScreenRecording && hasVerifiedScreenRecordingAccess
        case .accessibility:
            return status.hasAccessibility
        }
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

        guard missingRequirements.allSatisfy(dependencies.permissions.canRequest) else { return .unavailable }
        requestPermission(firstMissingRequirement)
        permissionSetupGuide?.featureName = featureName
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
        refreshPermissions()
        guard !permissionStatus.hasAccess(to: requirement) else { return }
        guard activePermissionRequest == nil, activeMediaPermissionRequest == nil else {
            logPermissionState("requestPermissionIgnoredActiveRequest")
            return
        }

        guard dependencies.permissions.canRequest(requirement) else {
            permissionSetupGuide = nil
            activePermissionRequest = nil
            logPermissionState("requestPermissionUnavailable")
            return
        }

        if requirement == .screenRecording {
            guard !screenRecordingSetupNeedsAttention else {
                presentPermissionSetupGuide(for: requirement)
                return
            }
            noteScreenRecordingSetupStarted()
        }

        activePermissionRequest = requirement
        logPermissionState("requestPermissionStarted.\(String(describing: requirement))")
        _ = dependencies.permissions.requestAccess(for: requirement)
        refreshPermissions()

        if permissionStatus.hasAccess(to: requirement) {
            permissionSetupGuide = nil
            activePermissionRequest = nil
            logPermissionState("requestPermissionCompletedImmediately.\(String(describing: requirement))")
            return
        }

        // macOS owns its consent alert. Settings opens only at the user's request.
        presentPermissionSetupGuide(for: requirement)
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
        requestNextMissingSetupRequirement(in: dependencies.permissions.availableSetupRequirements())
    }

    func requestNextMissingSetupRequirement(in requirements: [CapturePermissionRequirement]) {
        guard activePermissionRequest == nil,
              !screenRecordingSetupNeedsAttention else {
            logPermissionState("requestNextMissingSetupRequirementIgnored")
            return
        }

        refreshPermissions()

        let uniqueRequirements = CapturePermissionRequirement.allCases.filter { requirements.contains($0) }
        let missingRequirements = uniqueRequirements.filter {
            !permissionStatus.hasAccess(to: $0)
        }

        guard let nextRequirement = missingRequirements.first else {
            logPermissionState("requestNextMissingSetupRequirementNothingMissing")
            return
        }

        logPermissionState("requestNextMissingSetupRequirementSelected.\(String(describing: nextRequirement))")
        requestPermission(nextRequirement)
    }

    func openPermissionSettings(_ requirement: CapturePermissionRequirement) {
        guard dependencies.permissions.canRequest(requirement) else { return }
        refreshPermissions()
        // Manage is navigation, not a new grant. Never invalidate existing access.
        if !permissionStatus.hasAccess(to: requirement),
           !(requirement == .screenRecording && screenRecordingSetupNeedsAttention) {
            if requirement == .screenRecording {
                noteScreenRecordingSetupStarted()
            }
            if activePermissionRequest == nil { activePermissionRequest = requirement }
            presentPermissionSetupGuide(for: requirement)
        }
        dependencies.permissions.openSystemSettings(for: requirement)
        logPermissionState("openPermissionSettings.\(String(describing: requirement))")
    }

    func updateActivePermissionPolling() {
        activePermissionPollingTask?.cancel()
        activePermissionPollingTask = nil

        guard let requirement = activePermissionRequest else {
            return
        }

        activePermissionPollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)

                guard !Task.isCancelled,
                      let self,
                      self.activePermissionRequest == requirement else {
                    return
                }

                self.refreshPermissions()
                PermissionWorkflowDiagnostics.debugState(
                    "activePermissionPoll.\(String(describing: requirement))",
                    rawStatus: self.dependencies.permissions.currentStatus(),
                    effectiveStatus: self.permissionStatus,
                    activeRequest: self.activePermissionRequest,
                    setupGuide: self.permissionSetupGuide?.requirement,
                    screenRecordingSetupStartedThisRun: self.screenRecordingSetupStartedThisRun,
                    screenRecordingSetupNeedsAttention: self.screenRecordingSetupNeedsAttention,
                    hasVerifiedScreenRecordingAccess: self.hasVerifiedScreenRecordingAccess
                )

                if self.permissionStatus.hasAccess(to: requirement) {
                    return
                }
            }
        }
    }

    // Poll only non-prompting status APIs. Shareable-content probes can display
    // system consent UI and therefore belong to an explicit Check Again action.
}
