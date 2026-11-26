import AppKit
import Foundation

@MainActor
extension CaptureWorkflowModel {
    func beginScrollingCapture() {
        var captureContext = activeCaptureContext
        var runOptions = currentCaptureRunOptions()
        let mode = resolvedScrollingMode(runOptions.scrollingMode)
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
        Task {
            defer {
                resetPreparedCaptureContext(ifMatching: captureContext)
            }
            guard !isWorking, !isInteractiveCaptureActive else { return }
            guard preflightPermissions(scrollingPermissionRequirements(for: mode), for: "Scrolling Capture") else {
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

            isWorking = true
            dependencies.lifecycle.updateWorkingMessage("Scrolling Capture")
            defer { isWorking = false }

            do {
                try await dependencies.systemServices.scheduler.sleep(nanoseconds: 200_000_000)
                try Task.checkCancellation()
                let service = dependencies.makeScrollingCaptureService(captureService)
                var selectedRegion: CGRect?
                while selectedRegion == nil {
                    try Task.checkCancellation()
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
                            isPrivateCapture: isPrivateCapture,
                            mode: mode
                        )
                    )
                    switch await dependencies.confirmScrollingTarget(target) {
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
}
