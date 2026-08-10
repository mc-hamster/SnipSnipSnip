import AppKit
import Foundation

@MainActor
extension CaptureWorkflowModel {
    func capturePreset(_ preset: CapturePreset) {
        capturePreset(
            preset,
            captureContext: activeCaptureContext
        )
    }

    private func capturePreset(
        _ preset: CapturePreset,
        captureContext: CaptureCompletionContext
    ) {
        guard !isWorking, video?.blocksNewCapture != true, guide?.isActive != true, !isConnectedDeviceSessionActive else {
            return
        }

        activeWorkflowPresetID = preset.id
        markCapturePresetRan(id: preset.id)

        switch preset.target {
        case .region(let region):
            capturePresetRegion(
                presetID: preset.id,
                savedRegion: region,
                options: preset.options,
                captureContext: captureContext
            )
        case .window(let window):
            capturePresetWindow(
                presetID: preset.id,
                savedWindow: window,
                options: preset.options,
                captureContext: captureContext
            )
        case .frontmostWindow:
            Task {
                await performCapture(
                    request: .frontmostWindow,
                    minimizeAppWindow: true,
                    runOptions: preset.options,
                    completionContext: captureContext
                ) {
                    let window = try await captureService.frontmostWindow()
                    return try await captureService.captureWindow(window)
                }
            }
        case .fullscreen:
            Task {
                await performCapture(
                    request: .fullscreen,
                    minimizeAppWindow: true,
                    runOptions: preset.options,
                    completionContext: captureContext
                ) {
                    try await captureService.captureFullscreen(
                        mode: preset.options.fullscreenDisplayMode,
                        selectedDisplayID: preset.options.selectedFullscreenDisplayID
                    )
                }
            }
        }
    }

    func capturePreset(id: CapturePreset.ID) {
        guard let preset = capturePresets.first(where: { $0.id == id }) else {
            return
        }

        capturePreset(preset)
    }

    func capturePreset(
        id: CapturePreset.ID,
        captureContext: CaptureCompletionContext
    ) {
        guard let preset = capturePresets.first(where: { $0.id == id }) else {
            return
        }
        capturePreset(preset, captureContext: captureContext)
    }

    func replaceWindowTargetAndCapturePreset(id: CapturePreset.ID, with window: CaptureWindowSummary) {
        let captureContext =
            windowPickerCaptureContext ?? activeCaptureContext
        windowPickerCaptureContext = nil
        updateWindowTarget(forPresetID: id, window: window)
        capturePreset(id: id, captureContext: captureContext)
    }

    func pickWindowOnScreenForPresetReplacement(id presetID: CapturePreset.ID) {
        let windows = availableWindows
        let captureContext =
            windowPickerCaptureContext ?? activeCaptureContext
        windowPickerCaptureContext = nil
        isShowingWindowPicker = false

        Task {
            let autosaveSuspension = suspendEditorAutosaveForInteractiveCapture()
            defer { resumeEditorAutosaveAfterInteractiveCapture(autosaveSuspension) }
            let hiddenWindow = hideAppWindowIfNeeded()
            defer { restoreAppWindowIfNeeded(hiddenWindow) }

            if hiddenWindow != nil {
                try? await dependencies.systemServices.scheduler.sleep(nanoseconds: 200_000_000)
            }

            guard ensureScreenshotCaptureAccess(
                for: .frontmostWindow,
                runOptions:
                    capturePresets.first(where: { $0.id == presetID })?.options
                    ?? currentCaptureRunOptions()
            ) else {
                return
            }

            isWorking = true
            dependencies.lifecycle.updateWorkingMessage("Pick Window")
            defer { isWorking = false }

            do {
                let windowOptions = windows.isEmpty
                    ? try await captureService.listWindows(includeThumbnails: false)
                    : windows
                let snapshot = try await captureService.captureDesktopOverlaySnapshot()
                let session = WindowSelectionSession(
                    snapshot: snapshot,
                    windows: windowOptions,
                    capabilities: dependencies.capabilities,
                    accessibility: dependencies.systemServices.accessibility,
                    screens: dependencies.systemServices.screens
                )

                guard let selectedWindow = await session.begin() else {
                    resetPreparedCaptureContext(
                        ifMatching: captureContext
                    )
                    return
                }

                isWorking = false
                updateWindowTarget(forPresetID: presetID, window: selectedWindow)
                capturePreset(
                    id: presetID,
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

    func capturePresetWindow(
        presetID: CapturePreset.ID,
        savedWindow: SavedWindowTarget,
        options: CaptureRunOptions,
        captureContext: CaptureCompletionContext
    ) {
        Task {
            guard ensureScreenshotCaptureAccess(for: .frontmostWindow, runOptions: options) else {
                return
            }

            isWorking = true
            dependencies.lifecycle.updateWorkingMessage("Finding Window")
            defer { isWorking = false }

            do {
                let windows = try await captureService.listWindows(includeThumbnails: false)
                guard let resolvedWindow = gscStrictSavedWindowMatch(for: savedWindow, in: windows) else {
                    isWorking = false
                    presentWindowReplacementPicker(
                        forPresetID: presetID,
                        captureContext: captureContext
                    )
                    return
                }

                isWorking = false
                await performCapture(
                    request: .window(resolvedWindow),
                    minimizeAppWindow: true,
                    runOptions: options,
                    completionContext: captureContext
                ) {
                    let currentWindow = try await captureService.resolveWindowTarget(resolvedWindow)
                    return try await captureService.captureWindow(currentWindow)
                }
            } catch {
                present(
                    error,
                    recovering: nil,
                    captureContext: captureContext
                )
            }
        }
    }

    private func presentWindowReplacementPicker(
        forPresetID presetID: CapturePreset.ID,
        captureContext: CaptureCompletionContext
    ) {
        windowPickerCaptureContext = captureContext
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
