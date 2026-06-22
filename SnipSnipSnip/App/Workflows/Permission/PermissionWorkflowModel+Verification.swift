import Foundation
import OSLog

private enum PermissionWorkflowDiagnostics {
    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "SnipSnipSnip",
        category: "CapturePermissions"
    )

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
    }

    @discardableResult
    func reconcileScreenRecordingPermissionFailureIfNeeded(after error: Error) -> Bool {
        guard dependencies.permissions.indicatesScreenRecordingPermissionFailure(error) else {
            return false
        }

        reconcileScreenRecordingPermissionDenied(after: error)
        return true
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

                self.pendingScreenRecordingPermissionVerificationTask = nil
            }
        }
    }
}
