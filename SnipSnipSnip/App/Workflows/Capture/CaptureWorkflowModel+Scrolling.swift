import AppKit
import Foundation

@MainActor
extension CaptureWorkflowModel {
    func captureScrollingArea() {
        guard dependencies.capabilities.isEnabled(.scrollingCapture) else {
            return
        }

        runActionWhenPermissionsReady(
            [.screenRecording, .accessibility],
            featureName: "Scrolling Capture",
            pendingCommand: .scrollingCapture
        ) { [weak self] in
            self?.beginScrollingCapture()
        }
    }

    func beginScrollingCapture() {
        guard dependencies.capabilities.isEnabled(.scrollingCapture) else {
            return
        }

        Task {
            guard preflightPermissions([.screenRecording, .accessibility], for: "Scrolling Capture") else {
                return
            }

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
                let snapshot = try await captureService.captureDesktopOverlaySnapshot()
                let session = ScrollingSelectionSession(snapshot: snapshot)

                guard let region = await session.begin() else {
                    return
                }

                try await runCaptureDelayIfNeeded(actionName: "Scrolling Capture")
                try await dependencies.systemServices.scheduler.sleep(nanoseconds: 180_000_000)
                try await performScrollingCapture(in: region, isPrivateCapture: isPrivateCapture)
                completedCapture = true
            } catch ScrollingCaptureError.cancelled {
                return
            } catch {
                present(error)
            }
        }
    }

    func repeatScrollingCapture(_ region: CGRect) {
        guard dependencies.capabilities.isEnabled(.scrollingCapture) else {
            return
        }

        Task {
            guard preflightPermissions([.screenRecording, .accessibility], for: "Scrolling Capture") else {
                return
            }

            let isPrivateCapture = beginCapturePrivacyLock()
            defer { endCapturePrivacyLock() }

            isWorking = true
            dependencies.lifecycle.updateWorkingMessage(captureDelay == .immediate ? "Scrolling Capture" : captureDelay.shortLabel)
            defer { isWorking = false }

            do {
                try await runCaptureDelayIfNeeded(actionName: "Scrolling Capture")
                try await performScrollingCapture(in: region, isPrivateCapture: isPrivateCapture)
            } catch ScrollingCaptureError.cancelled {
                return
            } catch {
                present(error)
            }
        }
    }

    func performScrollingCapture(in region: CGRect, isPrivateCapture: Bool) async throws {
        let cancellation = ScrollingCaptureCancellation()
        let progressOverlay = ScrollingCaptureProgressOverlay(
            onCancel: {
                cancellation.cancel()
            },
            onDone: {
                cancellation.finish()
            }
        )
        var progressOverlayShown = false
        defer { progressOverlay.close() }

        let service = dependencies.makeScrollingCaptureService(captureService)
        let result = try await service.capture(
            request: ScrollingCaptureRequest(viewportRect: region),
            cancellation: cancellation,
            progressHandler: { progress in
                if !progressOverlayShown {
                    progressOverlay.show(avoiding: region)
                    progressOverlayShown = true
                }

                progressOverlay.update(segmentCount: progress.segmentCount, capacityFraction: progress.capacityFraction, warning: progress.warning)
            }
        )

        try completeCapture(result.capturedScreenshot, request: .scrolling(region), isPrivateCapture: isPrivateCapture)
        showCapturedFeedback()

        if let warning = result.warnings.last {
            dependencies.lifecycle.presentError(warning)
        }
    }
}
