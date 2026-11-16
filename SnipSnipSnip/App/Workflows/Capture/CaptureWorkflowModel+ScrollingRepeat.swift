import CoreGraphics
import Foundation

@MainActor
extension CaptureWorkflowModel {
    func repeatScrollingCaptureImpl(_ region: CGRect) {
        var captureContext = activeCaptureContext
        var runOptions = currentCaptureRunOptions()
        let mode = resolvedScrollingMode(runOptions.scrollingMode ?? lastCaptureRunOptions?.scrollingMode)
        runOptions.scrollingMode = mode
        var options = captureContext.oneShotOptions ?? CaptureOneShotOptions(
            captureDelay: runOptions.captureDelay, includesCursor: runOptions.includesCursor,
            privateCapture: privateCaptureEnabled, windowUIMapEnabled: runOptions.windowUIMapEnabled
        )
        options.scrollingMode = mode
        captureContext.oneShotOptions = options
        activeCaptureContext = captureContext
        guard !isWorking, !isInteractiveCaptureActive else {
            resetPreparedCaptureContext(ifMatching: captureContext)
            return
        }
        guard dependencies.capabilities.isEnabled(.scrollingCapture) else {
            resetPreparedCaptureContext(ifMatching: captureContext)
            return
        }
        // Retain the workflow until this attempt releases privacy and window
        // tokens. The optional follow-up selector below may outlive it.
        Task { [self] in
            var transfersContextToSelection = false
            defer {
                if !transfersContextToSelection {
                    resetPreparedCaptureContext(ifMatching: captureContext)
                }
            }
            guard !isWorking, !isInteractiveCaptureActive else { return }
            guard preflightPermissions(scrollingPermissionRequirements(for: mode), for: "Scrolling Capture") else { return }
            let isPrivateCapture = beginCapturePrivacyLock(
                latchedPrivateCapture:
                    captureContext.oneShotOptions?.privateCapture
                    ?? privateCaptureEnabled
            )
            defer { endCapturePrivacyLock() }
            let autosaveSuspension = suspendEditorAutosaveForInteractiveCapture()
            defer { resumeEditorAutosaveAfterInteractiveCapture(autosaveSuspension) }
            let hiddenWindow = hideAppWindowIfNeeded(for: captureContext.presentationContext)
            var completedCapture = false
            defer {
                if !completedCapture { restoreAppWindowIfNeeded(hiddenWindow) }
            }

            isWorking = true
            dependencies.lifecycle.updateWorkingMessage(runOptions.captureDelay == .immediate ? "Scrolling Capture" : runOptions.captureDelay.shortLabel)
            defer { isWorking = false }

            do {
                try await dependencies.systemServices.scheduler.sleep(nanoseconds: 200_000_000)
                try Task.checkCancellation()
                let service = dependencies.makeScrollingCaptureService(captureService)
                let target = try service.resolveTarget(
                    for: ScrollingCaptureRequest(
                        viewportRect: region,
                        isPrivateCapture: isPrivateCapture,
                        mode: mode
                    )
                )
                switch dependencies.confirmScrollingTarget(target) {
                case .start:
                    break
                case .chooseAnotherArea:
                    transfersContextToSelection = true
                    // Let this attempt release its busy/privacy/autosave and
                    // window tokens before starting the replacement selector.
                    Task { [weak self] in
                        self?.captureScrollingArea(
                            intent: captureContext.intent,
                            completionRole: captureContext.role,
                            oneShotOptions: captureContext.oneShotOptions,
                            presentationContext: captureContext.presentationContext
                        )
                    }
                    return
                case .cancel:
                    resetPreparedCaptureContext(ifMatching: captureContext)
                    return
                }

                try await runCaptureDelayIfNeeded(
                    actionName: "Scrolling Capture",
                    delay: runOptions.captureDelay
                )
                try await performScrollingCapture(
                    in: region,
                    isPrivateCapture: isPrivateCapture,
                    runOptions: runOptions,
                    completionContext: captureContext
                )
                completedCapture = true
            } catch ScrollingCaptureError.cancelled {
                resetPreparedCaptureContext(ifMatching: captureContext)
                return
            } catch let interruption as ScrollingCaptureInterruptedError {
                present(
                    interruption,
                    recovering: .scrolling(region),
                    captureContext: captureContext
                )
            } catch {
                present(
                    error,
                    recovering: .scrolling(region),
                    captureContext: captureContext
                )
            }
        }
    }
}
