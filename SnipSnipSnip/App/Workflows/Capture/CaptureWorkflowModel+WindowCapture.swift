import AppKit
import Foundation

@MainActor
extension CaptureWorkflowModel {
    func presentWindowPicker() {
        runWindowScreenshotCaptureWhenPermissionsReady { [weak self] in
            self?.windowPickerMode = .screenshot
            self?.beginWindowPickerPresentation()
        }
    }

    func pickWindowOnScreen() {
        let windows = availableWindows
        let runOptions = currentCaptureRunOptions()
        isShowingWindowPicker = false

        Task {
            let isPrivateCapture = beginCapturePrivacyLock()
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
                    return
                }

                try await runCaptureDelayIfNeeded(actionName: "Capturing Window", delay: runOptions.captureDelay)
                let resolvedWindow = try await captureService.resolveWindowTarget(selectedWindow)
                let capture = try await captureService.captureWindow(resolvedWindow)
                showCapturedFeedback()
                try completeCapture(capture, request: .window(resolvedWindow), isPrivateCapture: isPrivateCapture, runOptions: runOptions)
            } catch {
                present(error)
            }
        }
    }

    func captureWindow(_ window: CaptureWindowSummary) {
        isShowingWindowPicker = false

        Task {
            await performCapture(request: .window(window), minimizeAppWindow: true) {
                try await captureService.captureWindow(window)
            }
        }
    }

    func beginWindowPickerPresentation() {
        dependencies.lifecycle.requestMainWindowPresentation()

        Task {
            await loadAvailableWindows(requestAccessIfNeeded: true, presentPicker: true, showErrors: true, includeThumbnails: true)
        }
    }

    func replaceWindowTargetAndCapturePreset(id: CapturePreset.ID, with window: CaptureWindowSummary) {
        updateWindowTarget(forPresetID: id, window: window)
        capturePreset(id: id)
    }

    func pickWindowOnScreenForPresetReplacement(id presetID: CapturePreset.ID) {
        let windows = availableWindows
        isShowingWindowPicker = false

        Task {
            let autosaveSuspension = suspendEditorAutosaveForInteractiveCapture()
            defer { resumeEditorAutosaveAfterInteractiveCapture(autosaveSuspension) }
            let hiddenWindow = hideAppWindowIfNeeded()
            defer { restoreAppWindowIfNeeded(hiddenWindow) }

            if hiddenWindow != nil {
                try? await dependencies.systemServices.scheduler.sleep(nanoseconds: 200_000_000)
            }

            guard ensureScreenshotCaptureAccess(for: .frontmostWindow, runOptions: capturePresets.first(where: { $0.id == presetID })?.options ?? currentCaptureRunOptions()) else {
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
                    return
                }

                isWorking = false
                updateWindowTarget(forPresetID: presetID, window: selectedWindow)
                capturePreset(id: presetID)
            } catch {
                present(error)
            }
        }
    }

    func repeatWindowCapture(_ window: CaptureWindowSummary) {
        Task {
            guard ensureScreenshotCaptureAccess(for: .window(window)) else {
                return
            }

            let isPrivateCapture = beginCapturePrivacyLock()
            defer { endCapturePrivacyLock() }

            let hiddenWindow = hideAppWindowIfNeeded()
            defer { restoreAppWindowIfNeeded(hiddenWindow) }

            if hiddenWindow != nil {
                try? await dependencies.systemServices.scheduler.sleep(nanoseconds: 200_000_000)
            }

            isWorking = true
            dependencies.lifecycle.updateWorkingMessage(captureDelay == .immediate ? "Capturing Window" : captureDelay.shortLabel)
            defer { isWorking = false }

            do {
                try await runCaptureDelayIfNeeded(actionName: "Capturing Window")
                let resolvedWindow = try await captureService.resolveWindowTarget(window)
                let capture = try await captureService.captureWindow(resolvedWindow)
                showCapturedFeedback()
                try completeCapture(capture, request: .window(resolvedWindow), isPrivateCapture: isPrivateCapture)
            } catch let error as ScreenCaptureError where error == .windowImageUnavailable || error == .noWindowsAvailable {
                dependencies.lifecycle.requestMainWindowPresentation()
                await loadAvailableWindows(requestAccessIfNeeded: false, presentPicker: true, showErrors: true, includeThumbnails: true)
            } catch {
                present(error)
            }
        }
    }

    func capturePresetWindow(
        presetID: CapturePreset.ID,
        savedWindow: SavedWindowTarget,
        options: CaptureRunOptions
    ) {
        Task {
            guard ensureScreenshotCaptureAccess(for: .frontmostWindow, runOptions: options) else {
                return
            }

            isWorking = true
            dependencies.lifecycle.updateWorkingMessage("Finding Window")
            defer { isWorking = false }

            do {
                let windows = try await captureService.listWindows(includeThumbnails: true)
                guard let resolvedWindow = gscStrictSavedWindowMatch(for: savedWindow, in: windows) else {
                    isWorking = false
                    presentWindowReplacementPicker(forPresetID: presetID)
                    return
                }

                isWorking = false
                await performCapture(request: .window(resolvedWindow), minimizeAppWindow: true, runOptions: options) {
                    try await captureService.captureWindow(resolvedWindow)
                }
            } catch {
                present(error)
            }
        }
    }

    private func presentWindowReplacementPicker(forPresetID presetID: CapturePreset.ID) {
        dependencies.lifecycle.presentError("That preset's saved window is not available. Choose a replacement window to update and run the preset.")
        windowPickerMode = .capturePresetReplacement(presetID)
        beginWindowPickerPresentation()
    }

    private func updateWindowTarget(forPresetID presetID: CapturePreset.ID, window: CaptureWindowSummary) {
        guard let index = capturePresets.firstIndex(where: { $0.id == presetID }) else {
            return
        }

        var preset = capturePresets[index]
        preset.target = .window(SavedWindowTarget(window: window))
        preset.updatedAt = dependencies.systemServices.clock.now()
        capturePresets[index] = preset
    }
}
