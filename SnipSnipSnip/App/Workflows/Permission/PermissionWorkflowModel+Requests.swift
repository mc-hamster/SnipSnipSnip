import Foundation

@MainActor
extension PermissionWorkflowModel {
    func refreshPermissions() {
        let currentStatus = dependencies.permissions.currentStatus()
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
            permissionSetupGuide = nil
        }

        reconcileVerifiedScreenRecordingAccess(using: currentStatus)
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
        guard activePermissionRequest == nil else {
            PermissionWorkflowDiagnostics.state(
                "requestPermissionIgnoredActiveRequest",
                rawStatus: dependencies.permissions.currentStatus(),
                effectiveStatus: permissionStatus,
                activeRequest: activePermissionRequest,
                setupGuide: permissionSetupGuide?.requirement,
                screenRecordingSetupStartedThisRun: screenRecordingSetupStartedThisRun,
                screenRecordingSetupNeedsAttention: screenRecordingSetupNeedsAttention,
                hasVerifiedScreenRecordingAccess: hasVerifiedScreenRecordingAccess
            )
            return
        }

        guard dependencies.permissions.canRequest(requirement) else {
            permissionSetupGuide = nil
            activePermissionRequest = nil
            PermissionWorkflowDiagnostics.state(
                "requestPermissionUnavailable",
                rawStatus: dependencies.permissions.currentStatus(),
                effectiveStatus: permissionStatus,
                activeRequest: activePermissionRequest,
                setupGuide: permissionSetupGuide?.requirement,
                screenRecordingSetupStartedThisRun: screenRecordingSetupStartedThisRun,
                screenRecordingSetupNeedsAttention: screenRecordingSetupNeedsAttention,
                hasVerifiedScreenRecordingAccess: hasVerifiedScreenRecordingAccess
            )
            return
        }

        if requirement == .screenRecording {
            noteScreenRecordingSetupStarted()
        }

        activePermissionRequest = requirement
        PermissionWorkflowDiagnostics.state(
            "requestPermissionStarted.\(String(describing: requirement))",
            rawStatus: dependencies.permissions.currentStatus(),
            effectiveStatus: permissionStatus,
            activeRequest: activePermissionRequest,
            setupGuide: permissionSetupGuide?.requirement,
            screenRecordingSetupStartedThisRun: screenRecordingSetupStartedThisRun,
            screenRecordingSetupNeedsAttention: screenRecordingSetupNeedsAttention,
            hasVerifiedScreenRecordingAccess: hasVerifiedScreenRecordingAccess
        )
        _ = dependencies.permissions.requestAccess(for: requirement)
        refreshPermissions()

        if permissionStatus.hasAccess(to: requirement) {
            permissionSetupGuide = nil
            activePermissionRequest = nil
            PermissionWorkflowDiagnostics.state(
                "requestPermissionCompletedImmediately.\(String(describing: requirement))",
                rawStatus: dependencies.permissions.currentStatus(),
                effectiveStatus: permissionStatus,
                activeRequest: activePermissionRequest,
                setupGuide: permissionSetupGuide?.requirement,
                screenRecordingSetupStartedThisRun: screenRecordingSetupStartedThisRun,
                screenRecordingSetupNeedsAttention: screenRecordingSetupNeedsAttention,
                hasVerifiedScreenRecordingAccess: hasVerifiedScreenRecordingAccess
            )
            return
        }

        switch requirement {
        case .accessibility:
            openAccessibilitySettingsAfterPromptOpportunity()
            presentPermissionSetupGuide(for: .accessibility)
        case .screenRecording:
            presentPermissionSetupGuide(for: .screenRecording)
            openScreenRecordingSettingsAfterPromptOpportunity()
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
        requestNextMissingSetupRequirement(in: dependencies.permissions.availableSetupRequirements())
    }

    func requestNextMissingSetupRequirement(in requirements: [CapturePermissionRequirement]) {
        guard activePermissionRequest == nil,
              !screenRecordingSetupNeedsAttention else {
            PermissionWorkflowDiagnostics.state(
                "requestNextMissingSetupRequirementIgnored",
                rawStatus: dependencies.permissions.currentStatus(),
                effectiveStatus: permissionStatus,
                activeRequest: activePermissionRequest,
                setupGuide: permissionSetupGuide?.requirement,
                screenRecordingSetupStartedThisRun: screenRecordingSetupStartedThisRun,
                screenRecordingSetupNeedsAttention: screenRecordingSetupNeedsAttention,
                hasVerifiedScreenRecordingAccess: hasVerifiedScreenRecordingAccess
            )
            return
        }

        refreshPermissions()

        let uniqueRequirements = CapturePermissionRequirement.allCases.filter { requirements.contains($0) }
        let missingRequirements = uniqueRequirements.filter {
            !permissionStatus.hasAccess(to: $0)
        }

        guard let nextRequirement = missingRequirements.first else {
            PermissionWorkflowDiagnostics.state(
                "requestNextMissingSetupRequirementNothingMissing",
                rawStatus: dependencies.permissions.currentStatus(),
                effectiveStatus: permissionStatus,
                activeRequest: activePermissionRequest,
                setupGuide: permissionSetupGuide?.requirement,
                screenRecordingSetupStartedThisRun: screenRecordingSetupStartedThisRun,
                screenRecordingSetupNeedsAttention: screenRecordingSetupNeedsAttention,
                hasVerifiedScreenRecordingAccess: hasVerifiedScreenRecordingAccess
            )
            return
        }

        PermissionWorkflowDiagnostics.state(
            "requestNextMissingSetupRequirementSelected.\(String(describing: nextRequirement))",
            rawStatus: dependencies.permissions.currentStatus(),
            effectiveStatus: permissionStatus,
            activeRequest: activePermissionRequest,
            setupGuide: permissionSetupGuide?.requirement,
            screenRecordingSetupStartedThisRun: screenRecordingSetupStartedThisRun,
            screenRecordingSetupNeedsAttention: screenRecordingSetupNeedsAttention,
            hasVerifiedScreenRecordingAccess: hasVerifiedScreenRecordingAccess
        )
        requestPermission(nextRequirement)
    }

    func openPermissionSettings(_ requirement: CapturePermissionRequirement) {
        if requirement == .screenRecording {
            noteScreenRecordingSetupStarted()
        }

        if requirement == .screenRecording,
           !permissionStatus.hasScreenRecording {
            if activePermissionRequest == nil {
                activePermissionRequest = .screenRecording
            }
        }

        dependencies.permissions.openSystemSettings(for: requirement)
        PermissionWorkflowDiagnostics.state(
            "openPermissionSettings.\(String(describing: requirement))",
            rawStatus: dependencies.permissions.currentStatus(),
            effectiveStatus: permissionStatus,
            activeRequest: activePermissionRequest,
            setupGuide: permissionSetupGuide?.requirement,
            screenRecordingSetupStartedThisRun: screenRecordingSetupStartedThisRun,
            screenRecordingSetupNeedsAttention: screenRecordingSetupNeedsAttention,
            hasVerifiedScreenRecordingAccess: hasVerifiedScreenRecordingAccess
        )
        refreshPermissions()
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
                await self.reconcileVerifiedActivePermissionRequest(requirement)
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

    private func reconcileVerifiedActivePermissionRequest(_ requirement: CapturePermissionRequirement) async {
        guard requirement == .screenRecording,
              activePermissionRequest == .screenRecording,
              !permissionStatus.hasScreenRecording else {
            return
        }

        let hasVerifiedAccess = await dependencies.permissions.verifyScreenRecordingAccess()

        guard activePermissionRequest == .screenRecording,
              hasVerifiedAccess else {
            return
        }

        let currentStatus = dependencies.permissions.currentStatus()
        if screenRecordingSetupRequiresRestart(for: currentStatus, verifiedAccess: hasVerifiedAccess) {
            markScreenRecordingRestartRequired()
            PermissionWorkflowDiagnostics.state(
                "activePermissionPollRestartRequired.\(String(describing: requirement))",
                rawStatus: currentStatus,
                effectiveStatus: permissionStatus,
                activeRequest: activePermissionRequest,
                setupGuide: permissionSetupGuide?.requirement,
                screenRecordingSetupStartedThisRun: screenRecordingSetupStartedThisRun,
                screenRecordingSetupNeedsAttention: screenRecordingSetupNeedsAttention,
                hasVerifiedScreenRecordingAccess: hasVerifiedScreenRecordingAccess,
                verifiedScreenRecordingAccess: hasVerifiedAccess
            )
            return
        }

        hasVerifiedScreenRecordingAccess = true
        permissionStatus = CapturePermissionStatus(
            hasScreenRecording: true,
            hasAccessibility: currentStatus.hasAccessibility
        )
        clearScreenRecordingRestartRequired()
        permissionSetupGuide = nil
        activePermissionRequest = nil
        PermissionWorkflowDiagnostics.state(
            "activePermissionPollVerified.\(String(describing: requirement))",
            rawStatus: currentStatus,
            effectiveStatus: permissionStatus,
            activeRequest: activePermissionRequest,
            setupGuide: permissionSetupGuide?.requirement,
            screenRecordingSetupStartedThisRun: screenRecordingSetupStartedThisRun,
            screenRecordingSetupNeedsAttention: screenRecordingSetupNeedsAttention,
            hasVerifiedScreenRecordingAccess: hasVerifiedScreenRecordingAccess,
            verifiedScreenRecordingAccess: hasVerifiedAccess
        )
    }

    private func openScreenRecordingSettingsAfterPromptOpportunity() {
        Task { @MainActor [weak self] in
            try? await self?.dependencies.scheduler.sleep(nanoseconds: 350_000_000)
            guard let self else {
                return
            }

            self.refreshPermissions()

            guard self.activePermissionRequest == .screenRecording,
                  !self.permissionStatus.hasScreenRecording else {
                if self.permissionStatus.hasScreenRecording {
                    self.permissionSetupGuide = nil
                    if self.activePermissionRequest == .screenRecording {
                        self.activePermissionRequest = nil
                    }
                }
                return
            }

            self.dependencies.permissions.openSystemSettings(for: .screenRecording)
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

            guard self.activePermissionRequest == .accessibility,
                  !self.permissionStatus.hasAccessibility else {
                self.permissionSetupGuide = nil
                return
            }

            self.presentPermissionSetupGuide(for: .accessibility)
        }
    }
}
