import AppKit
import Foundation

@MainActor
extension CaptureWorkflowModel {
    func captureScrollingArea() {
        captureScrollingArea(intent: .newDocument)
    }

    func captureScrollingArea(
        presentationContext: WorkflowPresentationContext
    ) {
        captureScrollingArea(
            intent: .newDocument,
            presentationContext: presentationContext
        )
    }

    func captureScrollingArea(
        intent: CaptureIntent,
        completionRole: CaptureCompletionRole = .standalone,
        oneShotOptions: CaptureOneShotOptions? = nil
    ) {
        captureScrollingArea(
            intent: intent,
            completionRole: completionRole,
            oneShotOptions: oneShotOptions,
            presentationContext: .application
        )
    }

    func captureScrollingArea(
        intent: CaptureIntent,
        completionRole: CaptureCompletionRole = .standalone,
        oneShotOptions: CaptureOneShotOptions? = nil,
        presentationContext: WorkflowPresentationContext
    ) {
        guard dependencies.capabilities.isEnabled(.scrollingCapture) else { return }
        prepareCaptureIntent(
            intent,
            completionRole: completionRole,
            oneShotOptions: oneShotOptions,
            presentationContext: presentationContext
        )
        runActionWhenPermissionsReady(
            [.screenRecording, .accessibility],
            featureName: "Scrolling Capture",
            pendingCommand: .scrollingCapture
        ) { [weak self] in
            self?.beginScrollingCapture()
        }
    }

    func beginScrollingCapture() {
        let captureContext = activeCaptureContext
        let runOptions = currentCaptureRunOptions()
        guard dependencies.capabilities.isEnabled(.scrollingCapture) else {
            resetPreparedCaptureContext(ifMatching: captureContext)
            return
        }
        Task {
            defer {
                resetPreparedCaptureContext(ifMatching: captureContext)
            }
            guard preflightPermissions([.screenRecording, .accessibility], for: "Scrolling Capture") else {
                return
            }
            let isPrivateCapture = beginCapturePrivacyLock(
                latchedPrivateCapture:
                    captureContext.oneShotOptions?.privateCapture
                    ?? privateCaptureEnabled
            )
            defer { endCapturePrivacyLock() }
            let autosaveSuspension = suspendEditorAutosaveForInteractiveCapture()
            defer { resumeEditorAutosaveAfterInteractiveCapture(autosaveSuspension) }

            let hiddenWindow = hideAppWindowIfNeeded(
                for: captureContext.presentationContext
            )
            var completedCapture = false
            defer {
                if !completedCapture {
                    restoreAppWindowIfNeeded(hiddenWindow)
                }
            }

            try? await dependencies.systemServices.scheduler.sleep(nanoseconds: 200_000_000)

            isWorking = true
            dependencies.lifecycle.updateWorkingMessage("Scrolling Capture")
            defer { isWorking = false }

            do {
                let service = dependencies.makeScrollingCaptureService(captureService)
                var selectedRegion: CGRect?
                while selectedRegion == nil {
                    let snapshot = try await captureService.captureDesktopOverlaySnapshot()
                    let session = RegionSelectionSession(
                        snapshot: snapshot,
                        preferences: runOptions.regionPreferences,
                        livePreviewCapturePlatform: dependencies.systemServices.screenCapturePlatform
                    )

                    guard let selection = await session.begin() else {
                        resetPreparedCaptureContext(
                            ifMatching: captureContext
                        )
                        return
                    }
                    guard case let .region(region, _) = selection else { continue }
                    let target = try service.resolveTarget(
                        for: ScrollingCaptureRequest(
                            viewportRect: region,
                            isPrivateCapture: isPrivateCapture
                        )
                    )
                    switch ScrollingCaptureTargetConfirmation.present(target: target) {
                    case .start:
                        selectedRegion = region
                    case .chooseAnotherArea:
                        continue
                    case .cancel:
                        resetPreparedCaptureContext(
                            ifMatching: captureContext
                        )
                        return
                    }
                }

                guard let region = selectedRegion else { return }

                try await runCaptureDelayIfNeeded(
                    actionName: "Scrolling Capture",
                    delay: runOptions.captureDelay
                )
                try await dependencies.systemServices.scheduler.sleep(nanoseconds: 180_000_000)
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
                    recovering:
                        .scrolling(
                            interruption.partialResult.sourceViewportRect
                        ),
                    captureContext: captureContext
                )
            } catch {
                present(
                    error,
                    recovering: nil,
                    captureContext: captureContext
                )
            }
        }
    }

    func repeatScrollingCapture(_ region: CGRect) {
        repeatScrollingCaptureImpl(region)
    }

}
