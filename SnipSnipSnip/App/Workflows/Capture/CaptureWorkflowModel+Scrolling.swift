import AppKit
import Foundation

@MainActor
extension CaptureWorkflowModel {
    func captureScrollingArea() {
        guard dependencies.capabilities.isEnabled(.scrollingCapture) else { return }
        runActionWhenPermissionsReady(
            [.screenRecording, .accessibility],
            featureName: "Scrolling Capture",
            pendingCommand: .scrollingCapture
        ) { [weak self] in
            self?.beginScrollingCapture()
        }
    }

    func beginScrollingCapture() {
        guard dependencies.capabilities.isEnabled(.scrollingCapture) else { return }
        Task {
            guard preflightPermissions([.screenRecording, .accessibility], for: "Scrolling Capture") else { return }
            let isPrivateCapture = beginCapturePrivacyLock()
            defer { endCapturePrivacyLock() }
            let autosaveSuspension = suspendEditorAutosaveForInteractiveCapture()
            defer { resumeEditorAutosaveAfterInteractiveCapture(autosaveSuspension) }

            let hiddenWindow = hideAppWindowIfNeeded()
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
                        preferences: regionCapturePreferences,
                        livePreviewCapturePlatform: dependencies.systemServices.screenCapturePlatform
                    )

                    guard let selection = await session.begin() else { return }
                    guard case let .region(region, _) = selection else { continue }
                    let target = try service.resolveTarget(for: ScrollingCaptureRequest(viewportRect: region))
                    switch ScrollingCaptureTargetConfirmation.present(target: target) {
                    case .start:
                        selectedRegion = region
                    case .chooseAnotherArea:
                        continue
                    case .cancel:
                        return
                    }
                }

                guard let region = selectedRegion else { return }

                try await runCaptureDelayIfNeeded(actionName: "Scrolling Capture")
                try await dependencies.systemServices.scheduler.sleep(nanoseconds: 180_000_000)
                try await performScrollingCapture(in: region, isPrivateCapture: isPrivateCapture)
                completedCapture = true
            } catch ScrollingCaptureError.cancelled {
                return
            } catch let interruption as ScrollingCaptureInterruptedError {
                present(interruption, recovering: .scrolling(interruption.partialResult.sourceViewportRect))
            } catch {
                present(error)
            }
        }
    }

    func repeatScrollingCapture(_ region: CGRect) {
        guard dependencies.capabilities.isEnabled(.scrollingCapture) else { return }
        Task {
            guard preflightPermissions([.screenRecording, .accessibility], for: "Scrolling Capture") else { return }
            let isPrivateCapture = beginCapturePrivacyLock()
            defer { endCapturePrivacyLock() }

            isWorking = true
            dependencies.lifecycle.updateWorkingMessage(captureDelay == .immediate ? "Scrolling Capture" : captureDelay.shortLabel)
            defer { isWorking = false }

            do {
                let service = dependencies.makeScrollingCaptureService(captureService)
                let target = try service.resolveTarget(for: ScrollingCaptureRequest(viewportRect: region))
                switch ScrollingCaptureTargetConfirmation.present(target: target) {
                case .start:
                    break
                case .chooseAnotherArea:
                    captureScrollingArea()
                    return
                case .cancel:
                    return
                }

                try await runCaptureDelayIfNeeded(actionName: "Scrolling Capture")
                try await performScrollingCapture(in: region, isPrivateCapture: isPrivateCapture)
            } catch ScrollingCaptureError.cancelled {
                return
            } catch let interruption as ScrollingCaptureInterruptedError {
                present(interruption, recovering: .scrolling(region))
            } catch {
                present(error, recovering: .scrolling(region))
            }
        }
    }

    func performScrollingCapture(in region: CGRect, isPrivateCapture: Bool) async throws {
        let cancellation = ScrollingCaptureCancellation()
        let progressOverlay = ScrollingCaptureProgressOverlay(
            onCancel: { cancellation.cancel() },
            onDone: { cancellation.finish() }
        )
        var progressOverlayShown = false
        defer { progressOverlay.close() }

        let service = dependencies.makeScrollingCaptureService(captureService)
        let result: ScrollingCaptureResult
        do {
            result = try await service.capture(
                request: ScrollingCaptureRequest(viewportRect: region),
                cancellation: cancellation,
                progressHandler: { progress in
                    if !progressOverlayShown {
                        progressOverlay.show(avoiding: region)
                        progressOverlayShown = true
                    }

                    progressOverlay.update(
                        segmentCount: progress.segmentCount,
                        outputHeight: progress.outputHeight,
                        capacityFraction: progress.capacityFraction,
                        warning: progress.warning,
                        previewImage: progress.previewImage
                    )
                }
            )
        } catch let interruption as ScrollingCaptureInterruptedError {
            pendingScrollingPartialCapture = (interruption.partialResult, isPrivateCapture)
            throw interruption
        }

        try completeCapture(result.capturedScreenshot, request: .scrolling(region), isPrivateCapture: isPrivateCapture)
        showCapturedFeedback()

        if let warning = result.warnings.last {
            dependencies.lifecycle.presentError(warning)
        }
    }
}
