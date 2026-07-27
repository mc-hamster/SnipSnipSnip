import AppKit
import Foundation

@MainActor
extension CaptureWorkflowModel {
    func presentWindowPicker() {
        presentWindowPicker(intent: .newDocument)
    }

    func presentWindowPicker(
        intent: CaptureIntent,
        completionRole: CaptureCompletionRole = .standalone,
        oneShotOptions: CaptureOneShotOptions? = nil
    ) {
        prepareCaptureIntent(
            intent,
            completionRole: completionRole,
            oneShotOptions: oneShotOptions
        )
        runWindowScreenshotCaptureWhenPermissionsReady { [weak self] in
            guard let self else {
                return
            }
            self.windowPickerMode = .screenshot
            self.windowPickerCaptureContext =
                self.activeCaptureContext
            self.beginWindowPickerPresentation()
        }
    }

    func pickWindowOnScreen() {
        let windows = availableWindows
        let captureContext =
            windowPickerCaptureContext ?? activeCaptureContext
        let runOptions = captureRunOptions(for: captureContext)
        windowPickerCaptureContext = nil
        isShowingWindowPicker = false

        Task {
            defer {
                resetPreparedCaptureContext(ifMatching: captureContext)
            }
            let isPrivateCapture = beginCapturePrivacyLock(
                latchedPrivateCapture:
                    captureContext.oneShotOptions?.privateCapture
                    ?? privateCaptureEnabled
            )
            defer { endCapturePrivacyLock() }
            let autosaveSuspension = suspendEditorAutosaveForInteractiveCapture()
            defer { resumeEditorAutosaveAfterInteractiveCapture(autosaveSuspension) }
            let hiddenWindow = hideAppWindowIfNeeded()
            defer { restoreAppWindowIfNeeded(hiddenWindow) }

            if hiddenWindow != nil {
                try? await dependencies.systemServices.scheduler.sleep(nanoseconds: 200_000_000)
            }

            guard ensureScreenshotCaptureAccess(for: .frontmostWindow, runOptions: runOptions) else {
                return
            }

            isWorking = true
            dependencies.lifecycle.updateWorkingMessage("Pick Window")
            defer { isWorking = false }

            do {
                let windowOptions = windows.isEmpty ? try await captureService.listWindows(includeThumbnails: false) : windows
                let snapshot = try await captureService.captureDesktopOverlaySnapshot()
                let session = WindowSelectionSession(
                    snapshot: snapshot,
                    windows: windowOptions,
                    capabilities: dependencies.capabilities,
                    accessibility: dependencies.systemServices.accessibility,
                    screens: dependencies.systemServices.screens
                )

                guard let selectedWindow = await session.begin() else {
                    resetPreparedCaptureContext(ifMatching: captureContext)
                    return
                }

                try await runCaptureDelayIfNeeded(actionName: "Capturing Window", delay: runOptions.captureDelay)
                let resolvedWindow = try await captureService.resolveWindowTarget(selectedWindow)
                let capture = try await captureService.captureWindow(resolvedWindow)
                showCapturedFeedback()
                try completeCapture(
                    capture,
                    request: .window(resolvedWindow),
                    isPrivateCapture: isPrivateCapture,
                    runOptions: runOptions,
                    completionContext: captureContext
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

    func captureWindow(_ window: CaptureWindowSummary) {
        let captureContext =
            windowPickerCaptureContext ?? activeCaptureContext
        let runOptions = captureRunOptions(for: captureContext)
        windowPickerCaptureContext = nil
        isShowingWindowPicker = false

        Task {
            await performCapture(
                request: .window(window),
                minimizeAppWindow: true,
                runOptions: runOptions,
                completionContext: captureContext
            ) {
                let resolvedWindow = try await captureService.resolveWindowTarget(window)
                return try await captureService.captureWindow(resolvedWindow)
            }
        }
    }

    func beginWindowPickerPresentation() {
        if case .screenshot = windowPickerMode,
           windowPickerCaptureContext == nil {
            windowPickerCaptureContext = activeCaptureContext
        }
        dependencies.lifecycle.requestMainWindowPresentation()

        Task {
            await loadAvailableWindows(requestAccessIfNeeded: true, presentPicker: true, showErrors: true, includeThumbnails: true)
        }
    }

    /// Cancels a screenshot window choice without substituting a standalone
    /// destination for the abandoned operation. This is important for
    /// intent-created Before/Step/Collection captures because cancellation
    /// must not leave their role available to a later direct capture.
    func cancelScreenshotWindowPicker() {
        let captureContext =
            windowPickerCaptureContext ?? activeCaptureContext
        windowPickerCaptureContext = nil
        isShowingWindowPicker = false
        windowPickerMode = .screenshot
        resetPreparedCaptureContext(ifMatching: captureContext)
        dependencies.lifecycle.requestMainWindowPresentation()
    }

    func repeatWindowCapture(_ window: CaptureWindowSummary) {
        let captureContext = activeCaptureContext
        let runOptions = captureRunOptions(for: captureContext)
        Task {
            var transfersContextToPicker = false
            defer {
                if !transfersContextToPicker {
                    resetPreparedCaptureContext(ifMatching: captureContext)
                }
            }
            guard ensureScreenshotCaptureAccess(
                for: .window(window),
                runOptions: runOptions
            ) else {
                return
            }

            let isPrivateCapture = beginCapturePrivacyLock(
                latchedPrivateCapture:
                    captureContext.oneShotOptions?.privateCapture
                    ?? privateCaptureEnabled
            )
            defer { endCapturePrivacyLock() }

            let hiddenWindow = hideAppWindowIfNeeded()
            defer { restoreAppWindowIfNeeded(hiddenWindow) }

            if hiddenWindow != nil {
                try? await dependencies.systemServices.scheduler.sleep(nanoseconds: 200_000_000)
            }

            isWorking = true
            dependencies.lifecycle.updateWorkingMessage(
                runOptions.captureDelay == .immediate
                    ? "Capturing Window"
                    : runOptions.captureDelay.shortLabel
            )
            defer { isWorking = false }

            do {
                try await runCaptureDelayIfNeeded(
                    actionName: "Capturing Window",
                    delay: runOptions.captureDelay
                )
                let resolvedWindow = try await captureService.resolveWindowTarget(window)
                let capture = try await captureService.captureWindow(resolvedWindow)
                showCapturedFeedback()
                try completeCapture(
                    capture,
                    request: .window(resolvedWindow),
                    isPrivateCapture: isPrivateCapture,
                    runOptions: runOptions,
                    completionContext: captureContext
                )
            } catch let error as ScreenCaptureError where error == .windowImageUnavailable || error == .noWindowsAvailable {
                transfersContextToPicker = true
                windowPickerCaptureContext = captureContext
                dependencies.lifecycle.requestMainWindowPresentation()
                await loadAvailableWindows(requestAccessIfNeeded: false, presentPicker: true, showErrors: true, includeThumbnails: true)
            } catch {
                present(
                    error,
                    recovering: .window(window),
                    captureContext: captureContext
                )
            }
        }
    }

}
