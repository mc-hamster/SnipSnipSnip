import AppKit

@MainActor
extension CaptureWorkflowModel {
    func captureText() {
        guard !isWorking, !isShowingWindowPicker, !isConnectedDeviceSessionActive,
              video?.blocksNewCapture != true, guide?.isActive != true else { return }
        prepareCaptureIntent(.newDocument)
        runActionWhenPermissionsReady([.screenRecording], featureName: "Capture Text", pendingCommand: .textCapture) {
            self.beginTextCapture()
        }
    }

    func beginTextCapture() {
        guard !isWorking, !isShowingWindowPicker, !isConnectedDeviceSessionActive,
              video?.blocksNewCapture != true, guide?.isActive != true else { return }
        let context = activeCaptureContext
        isWorking = true
        Task { @MainActor in
            let isPrivate = beginCapturePrivacyLock()
            let suspension = suspendEditorAutosaveForInteractiveCapture()
            let previousApp = NSWorkspace.shared.frontmostApplication
            let hiddenWindow = hideAppWindowIfNeeded(for: context.presentationContext)
            defer {
                restoreAppWindowIfNeeded(hiddenWindow)
                if previousApp?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp?.activate() }
                resumeEditorAutosaveAfterInteractiveCapture(suspension)
                endCapturePrivacyLock()
                resetPreparedCaptureContext(ifMatching: context)
                isWorking = false
            }
            do {
                dependencies.lifecycle.updateWorkingMessage("Capture Text")
                try await dependencies.systemServices.scheduler.sleep(nanoseconds: 200_000_000)
                let snapshot = try await captureService.captureDesktopOverlaySnapshot()
                let session = RegionSelectionSession(snapshot: snapshot, preferences: regionCapturePreferences,
                    livePreviewCapturePlatform: dependencies.systemServices.screenCapturePlatform)
                guard let selection = await session.begin(), case let .region(rect, _) = selection else { return }
                // Use the selected pixels; no cursor, preset, editor installation,
                // auto-copy image, UI Map, recovery or Snip History side effects.
                let screenshot = try await captureService.captureRegionDirect(in: rect)
                dependencies.lifecycle.updateWorkingMessage("Recognizing Text")
                try await TextCaptureService().copyText(in: screenshot.image, isPrivate: isPrivate,
                    pasteboard: dependencies.systemServices.pasteboard)
                AppAccessibility.announce("Text copied to the clipboard.")
                CaptureFeedbackOverlay.showFeedback(title: "Text Copied", detail: "Ready to paste", duration: 1.5)
            } catch is CancellationError {
                return
            } catch {
                dependencies.lifecycle.presentError(error.localizedDescription)
            }
        }
    }
}
