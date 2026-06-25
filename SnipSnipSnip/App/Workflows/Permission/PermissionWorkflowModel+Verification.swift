import Foundation
import OSLog

enum PermissionWorkflowDiagnostics {
    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "SnipSnipSnip",
        category: "CapturePermissions"
    )

    nonisolated static func state(
        _ event: String,
        rawStatus: CapturePermissionStatus? = nil,
        effectiveStatus: CapturePermissionStatus? = nil,
        activeRequest: CapturePermissionRequirement? = nil,
        setupGuide: CapturePermissionRequirement? = nil,
        screenRecordingSetupStartedThisRun: Bool,
        screenRecordingSetupNeedsAttention: Bool,
        hasVerifiedScreenRecordingAccess: Bool,
        verifiedScreenRecordingAccess: Bool? = nil
    ) {
        let rawStatusDescription = rawStatus.map { String(describing: $0) } ?? "nil"
        let effectiveStatusDescription = effectiveStatus.map { String(describing: $0) } ?? "nil"
        let activeRequestDescription = activeRequest.map { String(describing: $0) } ?? "nil"
        let setupGuideDescription = setupGuide.map { String(describing: $0) } ?? "nil"
        let verifiedDescription = verifiedScreenRecordingAccess.map { String(describing: $0) } ?? "nil"

        logger.info(
            "Permission workflow event=\(event, privacy: .public) raw=\(rawStatusDescription, privacy: .public) effective=\(effectiveStatusDescription, privacy: .public) active=\(activeRequestDescription, privacy: .public) guide=\(setupGuideDescription, privacy: .public) screenSetupStarted=\(screenRecordingSetupStartedThisRun, privacy: .public) restartRequired=\(screenRecordingSetupNeedsAttention, privacy: .public) cachedVerifiedScreen=\(hasVerifiedScreenRecordingAccess, privacy: .public) probeVerifiedScreen=\(verifiedDescription, privacy: .public)"
        )
    }

    nonisolated static func debugState(
        _ event: String,
        rawStatus: CapturePermissionStatus? = nil,
        effectiveStatus: CapturePermissionStatus? = nil,
        activeRequest: CapturePermissionRequirement? = nil,
        setupGuide: CapturePermissionRequirement? = nil,
        screenRecordingSetupStartedThisRun: Bool,
        screenRecordingSetupNeedsAttention: Bool,
        hasVerifiedScreenRecordingAccess: Bool,
        verifiedScreenRecordingAccess: Bool? = nil
    ) {
        let rawStatusDescription = rawStatus.map { String(describing: $0) } ?? "nil"
        let effectiveStatusDescription = effectiveStatus.map { String(describing: $0) } ?? "nil"
        let activeRequestDescription = activeRequest.map { String(describing: $0) } ?? "nil"
        let setupGuideDescription = setupGuide.map { String(describing: $0) } ?? "nil"
        let verifiedDescription = verifiedScreenRecordingAccess.map { String(describing: $0) } ?? "nil"

        logger.debug(
            "Permission workflow event=\(event, privacy: .public) raw=\(rawStatusDescription, privacy: .public) effective=\(effectiveStatusDescription, privacy: .public) active=\(activeRequestDescription, privacy: .public) guide=\(setupGuideDescription, privacy: .public) screenSetupStarted=\(screenRecordingSetupStartedThisRun, privacy: .public) restartRequired=\(screenRecordingSetupNeedsAttention, privacy: .public) cachedVerifiedScreen=\(hasVerifiedScreenRecordingAccess, privacy: .public) probeVerifiedScreen=\(verifiedDescription, privacy: .public)"
        )
    }

    nonisolated static func staleReadyStateReconciled(
        cachedStatus: CapturePermissionStatus,
        preflightStatus: CapturePermissionStatus,
        verifiedScreenRecordingAccess: Bool
    ) {
        logger.error(
            "Screen Recording cached ready state reconciled cached=\(String(describing: cachedStatus), privacy: .public) preflight=\(String(describing: preflightStatus), privacy: .public) verified=\(verifiedScreenRecordingAccess, privacy: .public)"
        )
    }

    nonisolated static func permissionDeniedDuringCapture(
        error: Error,
        cachedStatus: CapturePermissionStatus,
        preflightStatus: CapturePermissionStatus
    ) {
        let nsError = error as NSError
        logger.error(
            "Screen Recording denied during capture domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) cached=\(String(describing: cachedStatus), privacy: .public) preflight=\(String(describing: preflightStatus), privacy: .public)"
        )
    }
}

@MainActor
extension PermissionWorkflowModel {
    func reconcileScreenRecordingPermissionDenied(after error: Error? = nil) {
        pendingScreenRecordingPermissionVerificationTask?.cancel()
        pendingScreenRecordingPermissionVerificationTask = nil
        screenRecordingPermissionVerificationGeneration += 1
        hasVerifiedScreenRecordingAccess = false

        let status = dependencies.permissions.currentStatus()
        let cachedStatus = permissionStatus
        let reconciledStatus = CapturePermissionStatus(
            hasScreenRecording: false,
            hasAccessibility: status.hasAccessibility
        )

        if let error,
           cachedStatus.hasScreenRecording || status.hasScreenRecording {
            PermissionWorkflowDiagnostics.permissionDeniedDuringCapture(
                error: error,
                cachedStatus: cachedStatus,
                preflightStatus: status
            )
        }

        if reconciledStatus != permissionStatus {
            permissionStatus = reconciledStatus
        }

        if status.hasScreenRecording || screenRecordingSetupStartedThisRun {
            markScreenRecordingRestartRequired()
            PermissionWorkflowDiagnostics.state(
                "screenRecordingDeniedMarkedRestartRequired",
                rawStatus: status,
                effectiveStatus: permissionStatus,
                activeRequest: activePermissionRequest,
                setupGuide: permissionSetupGuide?.requirement,
                screenRecordingSetupStartedThisRun: screenRecordingSetupStartedThisRun,
                screenRecordingSetupNeedsAttention: screenRecordingSetupNeedsAttention,
                hasVerifiedScreenRecordingAccess: hasVerifiedScreenRecordingAccess
            )
        }
    }

    @discardableResult
    func reconcileScreenRecordingPermissionFailureIfNeeded(after error: Error) -> Bool {
        guard dependencies.permissions.indicatesScreenRecordingPermissionFailure(error) else {
            return false
        }

        reconcileScreenRecordingPermissionDenied(after: error)
        return true
    }

    func refreshPermissionsIncludingScreenRecordingProbe() async {
        let currentStatus = dependencies.permissions.currentStatus()
        PermissionWorkflowDiagnostics.state(
            "probeRefreshStarted",
            rawStatus: currentStatus,
            effectiveStatus: permissionStatus,
            activeRequest: activePermissionRequest,
            setupGuide: permissionSetupGuide?.requirement,
            screenRecordingSetupStartedThisRun: screenRecordingSetupStartedThisRun,
            screenRecordingSetupNeedsAttention: screenRecordingSetupNeedsAttention,
            hasVerifiedScreenRecordingAccess: hasVerifiedScreenRecordingAccess
        )

        if screenRecordingSetupRequiresRestart(for: currentStatus) {
            hasVerifiedScreenRecordingAccess = false
            let reconciledStatus = CapturePermissionStatus(
                hasScreenRecording: false,
                hasAccessibility: currentStatus.hasAccessibility
            )
            if reconciledStatus != permissionStatus {
                permissionStatus = reconciledStatus
            }
            markScreenRecordingRestartRequired()
            PermissionWorkflowDiagnostics.state(
                "probeRefreshRestartRequiredBeforeVerifier",
                rawStatus: currentStatus,
                effectiveStatus: permissionStatus,
                activeRequest: activePermissionRequest,
                setupGuide: permissionSetupGuide?.requirement,
                screenRecordingSetupStartedThisRun: screenRecordingSetupStartedThisRun,
                screenRecordingSetupNeedsAttention: screenRecordingSetupNeedsAttention,
                hasVerifiedScreenRecordingAccess: hasVerifiedScreenRecordingAccess
            )
            return
        }

        let requiresVerifiedReadiness = requiresVerifiedScreenRecordingReadiness()
        let hasVerifiedAccess: Bool
        if currentStatus.hasScreenRecording && !requiresVerifiedReadiness {
            hasVerifiedAccess = true
        } else {
            hasVerifiedAccess = await dependencies.permissions.verifyScreenRecordingAccess()
        }

        if screenRecordingSetupRequiresRestart(for: currentStatus, verifiedAccess: hasVerifiedAccess) {
            hasVerifiedScreenRecordingAccess = false
            let reconciledStatus = CapturePermissionStatus(
                hasScreenRecording: false,
                hasAccessibility: currentStatus.hasAccessibility
            )
            if reconciledStatus != permissionStatus {
                permissionStatus = reconciledStatus
            }
            markScreenRecordingRestartRequired()
            PermissionWorkflowDiagnostics.state(
                "probeRefreshRestartRequiredAfterVerifier",
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

        hasVerifiedScreenRecordingAccess = hasVerifiedAccess

        let reconciledStatus = CapturePermissionStatus(
            hasScreenRecording: hasVerifiedAccess,
            hasAccessibility: currentStatus.hasAccessibility
        )

        if reconciledStatus != permissionStatus {
            permissionStatus = reconciledStatus
        }

        if reconciledStatus.hasScreenRecording {
            clearScreenRecordingRestartRequired()
        } else if requiresVerifiedReadiness || currentStatus.hasScreenRecording {
            markScreenRecordingRestartRequired()
        }

        if let activePermissionRequest,
           reconciledStatus.hasAccess(to: activePermissionRequest) {
            self.activePermissionRequest = nil
        }

        if let requirement = permissionSetupGuide?.requirement,
           reconciledStatus.hasAccess(to: requirement) {
            permissionSetupGuide = nil
        }

        PermissionWorkflowDiagnostics.state(
            "probeRefreshCompleted",
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

    func reconcileVerifiedScreenRecordingAccess(using status: CapturePermissionStatus) {
        pendingScreenRecordingPermissionVerificationTask?.cancel()

        guard status.hasScreenRecording else {
            pendingScreenRecordingPermissionVerificationTask = nil
            screenRecordingPermissionVerificationGeneration += 1
            return
        }

        screenRecordingPermissionVerificationGeneration += 1
        let verificationGeneration = screenRecordingPermissionVerificationGeneration

        pendingScreenRecordingPermissionVerificationTask = Task { [weak self] in
            let hasVerifiedAccess = await self?.dependencies.permissions.verifyScreenRecordingAccess() ?? false

            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                guard let self,
                      self.screenRecordingPermissionVerificationGeneration == verificationGeneration else {
                    return
                }

                let currentStatus = self.dependencies.permissions.currentStatus()
                if self.screenRecordingSetupRequiresRestart(for: currentStatus, verifiedAccess: hasVerifiedAccess) {
                    self.hasVerifiedScreenRecordingAccess = false
                    let reconciledStatus = CapturePermissionStatus(
                        hasScreenRecording: false,
                        hasAccessibility: currentStatus.hasAccessibility
                    )
                    if reconciledStatus != self.permissionStatus {
                        self.permissionStatus = reconciledStatus
                    }
                    self.markScreenRecordingRestartRequired()
                    self.pendingScreenRecordingPermissionVerificationTask = nil
                    PermissionWorkflowDiagnostics.state(
                        "backgroundVerificationRestartRequired",
                        rawStatus: currentStatus,
                        effectiveStatus: self.permissionStatus,
                        activeRequest: self.activePermissionRequest,
                        setupGuide: self.permissionSetupGuide?.requirement,
                        screenRecordingSetupStartedThisRun: self.screenRecordingSetupStartedThisRun,
                        screenRecordingSetupNeedsAttention: self.screenRecordingSetupNeedsAttention,
                        hasVerifiedScreenRecordingAccess: self.hasVerifiedScreenRecordingAccess,
                        verifiedScreenRecordingAccess: hasVerifiedAccess
                    )
                    return
                }

                let requiresVerifiedReadiness = self.requiresVerifiedScreenRecordingReadiness()
                self.hasVerifiedScreenRecordingAccess = currentStatus.hasScreenRecording && hasVerifiedAccess
                let reconciledStatus = CapturePermissionStatus(
                    hasScreenRecording: currentStatus.hasScreenRecording && hasVerifiedAccess,
                    hasAccessibility: currentStatus.hasAccessibility
                )

                if currentStatus.hasScreenRecording && !hasVerifiedAccess {
                    PermissionWorkflowDiagnostics.staleReadyStateReconciled(
                        cachedStatus: self.permissionStatus,
                        preflightStatus: currentStatus,
                        verifiedScreenRecordingAccess: hasVerifiedAccess
                    )
                }

                if reconciledStatus != self.permissionStatus {
                    self.permissionStatus = reconciledStatus
                }

                if reconciledStatus.hasScreenRecording {
                    self.clearScreenRecordingRestartRequired()
                } else if currentStatus.hasScreenRecording && requiresVerifiedReadiness {
                    self.markScreenRecordingRestartRequired()
                }

                self.pendingScreenRecordingPermissionVerificationTask = nil
            }
        }
    }

    func requiresVerifiedScreenRecordingReadiness() -> Bool {
        activePermissionRequest == .screenRecording
            || permissionSetupGuide?.requirement == .screenRecording
            || screenRecordingSetupNeedsAttention
            || screenRecordingSetupStartedThisRun
    }

    func screenRecordingSetupRequiresRestart(for status: CapturePermissionStatus) -> Bool {
        screenRecordingSetupRequiresRestart(for: status, verifiedAccess: nil)
    }

    func screenRecordingSetupRequiresRestart(
        for status: CapturePermissionStatus,
        verifiedAccess: Bool?
    ) -> Bool {
        guard screenRecordingSetupStartedThisRun else {
            return false
        }

        return status.hasScreenRecording
            || hasVerifiedScreenRecordingAccess
            || verifiedAccess == true
    }

    func noteScreenRecordingSetupStarted() {
        screenRecordingSetupStartedThisRun = true
        screenRecordingSetupNeedsAttention = false
        PermissionWorkflowDiagnostics.state(
            "screenRecordingSetupStarted",
            rawStatus: dependencies.permissions.currentStatus(),
            effectiveStatus: permissionStatus,
            activeRequest: activePermissionRequest,
            setupGuide: permissionSetupGuide?.requirement,
            screenRecordingSetupStartedThisRun: screenRecordingSetupStartedThisRun,
            screenRecordingSetupNeedsAttention: screenRecordingSetupNeedsAttention,
            hasVerifiedScreenRecordingAccess: hasVerifiedScreenRecordingAccess
        )
    }

    func markScreenRecordingRestartRequired() {
        hasVerifiedScreenRecordingAccess = false
        screenRecordingSetupNeedsAttention = true

        if activePermissionRequest == .screenRecording {
            activePermissionRequest = nil
        }

        if permissionSetupGuide?.requirement == .screenRecording {
            permissionSetupGuide = nil
        }

        PermissionWorkflowDiagnostics.state(
            "screenRecordingRestartRequired",
            rawStatus: dependencies.permissions.currentStatus(),
            effectiveStatus: permissionStatus,
            activeRequest: activePermissionRequest,
            setupGuide: permissionSetupGuide?.requirement,
            screenRecordingSetupStartedThisRun: screenRecordingSetupStartedThisRun,
            screenRecordingSetupNeedsAttention: screenRecordingSetupNeedsAttention,
            hasVerifiedScreenRecordingAccess: hasVerifiedScreenRecordingAccess
        )
    }

    func clearScreenRecordingRestartRequired() {
        guard screenRecordingSetupNeedsAttention else {
            return
        }

        screenRecordingSetupNeedsAttention = false
        PermissionWorkflowDiagnostics.state(
            "screenRecordingRestartRequiredCleared",
            rawStatus: dependencies.permissions.currentStatus(),
            effectiveStatus: permissionStatus,
            activeRequest: activePermissionRequest,
            setupGuide: permissionSetupGuide?.requirement,
            screenRecordingSetupStartedThisRun: screenRecordingSetupStartedThisRun,
            screenRecordingSetupNeedsAttention: screenRecordingSetupNeedsAttention,
            hasVerifiedScreenRecordingAccess: hasVerifiedScreenRecordingAccess
        )
    }
}
