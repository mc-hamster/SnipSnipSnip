import AppKit
import Foundation

@MainActor
extension CaptureWorkflowModel {
    var canRepeatLastCapture: Bool {
        guard let lastCaptureRequest else {
            return false
        }

        if case .scrolling = lastCaptureRequest {
            return dependencies.capabilities.isEnabled(.scrollingCapture)
        }

        if case .connectedDevice = lastCaptureRequest {
            return dependencies.capabilities.isEnabled(.connectedDeviceCapture)
        }

        return true
    }

    var canChangePrivateCapture: Bool {
        !isCapturePrivacyLocked && !isWorking && !isShowingWindowPicker && video?.isRecording != true && !isConnectedDeviceSessionActive
    }

    var isInteractiveCaptureActive: Bool {
        interactiveCaptureAutosaveSuspensionDepth > 0
    }

    var windowScreenshotCapturePermissionRequirements: [CapturePermissionRequirement] {
        windowUIMapEnabled ? [.screenRecording, .accessibility] : [.screenRecording]
    }

    var windowScreenshotCaptureFeatureName: String {
        windowUIMapEnabled ? "Window Capture with UI Map" : "Window Capture"
    }

    func captureCurrentDisplay() {
        runScreenshotCaptureWhenPermissionsReady(for: .fullscreen, pendingCommand: .currentDisplay) { [weak self] in
            self?.beginFullscreenCapture()
        }
    }

    func captureRegion() {
        runScreenshotCaptureWhenPermissionsReady(for: .region(.zero), pendingCommand: .region) { [weak self] in
            self?.beginRegionCapture()
        }
    }

    func captureFrontmostWindow() {
        runScreenshotCaptureWhenPermissionsReady(for: .frontmostWindow, pendingCommand: .frontmostWindow) { [weak self] in
            self?.beginFrontmostWindowCapture()
        }
    }

    func repeatLastCapture() {
        beginRepeatLastCapture()
    }

    func updatePrivateCaptureEnabled(_ enabled: Bool) {
        guard canChangePrivateCapture else {
            dependencies.lifecycle.presentError("Private Capture cannot be changed while a capture or recording is active. The in-progress capture will use the privacy setting it started with.")
            return
        }

        privateCaptureEnabled = enabled
    }

    func beginFullscreenCapture() {
        let runOptions = currentCaptureRunOptions()
        Task {
            await performCapture(request: .fullscreen, minimizeAppWindow: true, runOptions: runOptions) {
                try await captureService.captureFullscreen(
                    mode: runOptions.fullscreenDisplayMode,
                    selectedDisplayID: runOptions.selectedFullscreenDisplayID
                )
            }
        }
    }

    func beginFrontmostWindowCapture() {
        let runOptions = currentCaptureRunOptions()
        Task {
            await performCapture(request: .frontmostWindow, minimizeAppWindow: true, runOptions: runOptions) {
                let window = try await captureService.frontmostWindow()
                return try await captureService.captureWindow(window)
            }
        }
    }

    func beginRegionCapture() {
        let runOptions = currentCaptureRunOptions()
        Task {
            guard ensureScreenshotCaptureAccess(for: .region(.zero), runOptions: runOptions) else {
                return
            }

            let isPrivateCapture = beginCapturePrivacyLock()
            defer { endCapturePrivacyLock() }
            let autosaveSuspension = suspendEditorAutosaveForInteractiveCapture()
            defer { resumeEditorAutosaveAfterInteractiveCapture(autosaveSuspension) }

            let hiddenWindow = hideAppWindowIfNeeded()
            defer { restoreAppWindowIfNeeded(hiddenWindow) }

            try? await dependencies.systemServices.scheduler.sleep(nanoseconds: 200_000_000)

            isWorking = true
            dependencies.lifecycle.updateWorkingMessage("Capture Region")
            defer { isWorking = false }

            do {
                let windowOptions = try await captureService.listWindows(includeThumbnails: false)
                let snapshot = try await captureService.captureDesktopOverlaySnapshot()
                let session = RegionSelectionSession(
                    snapshot: snapshot,
                    windows: windowOptions,
                    preferences: runOptions.regionPreferences
                )

                guard let selection = await session.begin() else {
                    return
                }

                switch selection {
                case let .region(region, cursorCaptureGlobalLocation):
                    try await runCaptureDelayIfNeeded(actionName: "Capture Region", delay: runOptions.captureDelay)
                    let capture: CapturedScreenshot
                    do {
                        capture = try await captureService.captureRegionDirect(in: region)
                    } catch {
                        let fallbackSnapshot = try await captureService.captureDesktopOverlaySnapshot()
                        capture = try await captureService.captureRegion(from: fallbackSnapshot, selection: region)
                    }
                    showCapturedFeedback()
                    try completeCapture(
                        capture,
                        request: .region(capture.sourceRect),
                        isPrivateCapture: isPrivateCapture,
                        cursorCaptureGlobalLocation: cursorCaptureGlobalLocation,
                        shouldAttemptUIMapCapture: true,
                        runOptions: runOptions
                    )
                case .window(let window):
                    try await runCaptureDelayIfNeeded(actionName: "Capturing Window", delay: runOptions.captureDelay)
                    let resolvedWindow = try await captureService.resolveWindowTarget(window)
                    let capture = try await captureService.captureWindow(resolvedWindow)
                    showCapturedFeedback()
                    try completeCapture(
                        capture,
                        request: .window(resolvedWindow),
                        isPrivateCapture: isPrivateCapture,
                        runOptions: runOptions
                    )
                }
            } catch {
                present(error)
            }
        }
    }

    func beginRepeatLastCapture() {
        guard let lastCaptureRequest else {
            return
        }

        switch lastCaptureRequest {
        case .region(let region):
            repeatRegionCapture(region)
        case .scrolling(let region):
            guard dependencies.capabilities.isEnabled(.scrollingCapture) else {
                return
            }
            repeatScrollingCapture(region)
        case .window(let window):
            repeatWindowCapture(window)
        case .frontmostWindow:
            captureFrontmostWindow()
        case .fullscreen:
            captureCurrentDisplay()
        case .connectedDevice(let device):
            captureConnectedDevice(device)
        }
    }

    func capturePreset(_ preset: CapturePreset) {
        guard !isWorking, video?.isRecording != true, !isConnectedDeviceSessionActive else {
            return
        }

        switch preset.target {
        case .region(let region):
            capturePresetRegion(presetID: preset.id, savedRegion: region, options: preset.options)
        case .window(let window):
            capturePresetWindow(presetID: preset.id, savedWindow: window, options: preset.options)
        case .frontmostWindow:
            Task {
                await performCapture(request: .frontmostWindow, minimizeAppWindow: true, runOptions: preset.options) {
                    let window = try await captureService.frontmostWindow()
                    return try await captureService.captureWindow(window)
                }
            }
        case .fullscreen:
            Task {
                await performCapture(request: .fullscreen, minimizeAppWindow: true, runOptions: preset.options) {
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

    func repeatRegionCapture(_ region: CGRect) {
        Task {
            await performCapture(request: .region(region)) {
                try await captureService.captureRegion(in: region)
            }
        }
    }

    func ensureWindowScreenshotCaptureAccess() -> Bool {
        preflightPermissions(
            windowScreenshotCapturePermissionRequirements,
            for: windowScreenshotCaptureFeatureName
        )
    }

    func ensureAccessibilityAccess() -> Bool {
        guard dependencies.capabilities.isEnabled(.accessibilityAutomation) || dependencies.capabilities.isEnabled(.uiMap) else {
            return false
        }

        return preflightPermissions([.accessibility], for: "Scrolling Capture")
    }

    func runScreenshotCaptureWhenPermissionsReady(action: @escaping @MainActor () -> Void) {
        runScreenshotCaptureWhenPermissionsReady(for: .fullscreen, pendingCommand: .currentDisplay, action: action)
    }

    func runScreenshotCaptureWhenPermissionsReady(
        for request: LastCaptureRequest,
        pendingCommand: PendingCapturePermissionCommand,
        action: @escaping @MainActor () -> Void
    ) {
        runScreenshotCaptureWhenPermissionsReady(for: request, runOptions: currentCaptureRunOptions(), pendingCommand: pendingCommand, action: action)
    }

    func runScreenshotCaptureWhenPermissionsReady(
        for request: LastCaptureRequest,
        runOptions: CaptureRunOptions,
        pendingCommand: PendingCapturePermissionCommand,
        action: @escaping @MainActor () -> Void
    ) {
        runActionWhenPermissionsReady(
            screenshotCapturePermissionRequirements(for: request, runOptions: runOptions),
            featureName: screenshotCaptureFeatureName(for: request, runOptions: runOptions),
            pendingCommand: pendingCommand,
            action: action
        )
    }

    func runWindowScreenshotCaptureWhenPermissionsReady(action: @escaping @MainActor () -> Void) {
        runActionWhenPermissionsReady(
            windowScreenshotCapturePermissionRequirements,
            featureName: windowScreenshotCaptureFeatureName,
            pendingCommand: .windowPicker,
            action: action
        )
    }

    func permissionGuidanceMessage(
        for requirements: [CapturePermissionRequirement],
        featureName: String
    ) -> String {
        let uniqueRequirements = CapturePermissionRequirement.allCases.filter { requirements.contains($0) }

        if uniqueRequirements == [.accessibility] {
            if featureName == "Window Capture with UI Map" {
                return "Window UI Map needs Accessibility access so \(AppBranding.displayName) can read visible interface element names, roles, identifiers, and locations from the selected window. If \(AppBranding.displayName) is not listed yet, click Set Up once to trigger the macOS prompt, then use the setup guide to reveal and add this exact app."
            }

            return "Scrolling Capture needs Accessibility access so \(AppBranding.displayName) can scroll the selected app while capturing. If \(AppBranding.displayName) is not listed yet, click Set Up once to trigger the macOS prompt, then use the setup guide to reveal and add this exact app."
        }

        if uniqueRequirements == [.screenRecording] {
            return "\(featureName) needs Screen Recording access so \(AppBranding.displayName) can read pixels from the screen. Click Set Up in the main window, then enable \(AppBranding.displayName) in System Settings > Privacy & Security > Screen Recording."
        }

        return "\(featureName) needs Screen Recording access to capture pixels and Accessibility access to save visible interface element names, roles, identifiers, and locations from the selected window. Click Set Up in the main window, then enable \(AppBranding.displayName) in System Settings > Privacy & Security."
    }

    private func capturePresetRegion(
        presetID: CapturePreset.ID,
        savedRegion: SavedCaptureRegion,
        options: CaptureRunOptions
    ) {
        Task {
            guard ensureScreenshotCaptureAccess(for: .region(savedRegion.rect), runOptions: options) else {
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
            dependencies.lifecycle.updateWorkingMessage("Capture Preset")
            defer { isWorking = false }

            do {
                let snapshot = try await captureService.captureDesktopOverlaySnapshot()
                guard isSavedRegionAvailable(savedRegion.rect, in: snapshot) else {
                    isWorking = false
                    beginPresetRegionFallback(
                        presetID: presetID,
                        savedRegion: savedRegion,
                        options: options
                    )
                    return
                }

                try await runCaptureDelayIfNeeded(actionName: "Capture Preset", delay: options.captureDelay)
                let capture: CapturedScreenshot
                do {
                    capture = try await captureService.captureRegionDirect(in: savedRegion.rect)
                } catch {
                    let fallbackSnapshot = try await captureService.captureDesktopOverlaySnapshot()
                    capture = try await captureService.captureRegion(from: fallbackSnapshot, selection: savedRegion.rect)
                }

                showCapturedFeedback()
                try completeCapture(
                    capture,
                    request: .region(capture.sourceRect),
                    isPrivateCapture: isPrivateCapture,
                    runOptions: options
                )
            } catch {
                present(error)
            }
        }
    }

    private func beginPresetRegionFallback(
        presetID: CapturePreset.ID,
        savedRegion: SavedCaptureRegion,
        options: CaptureRunOptions
    ) {
        Task {
            guard ensureScreenshotCaptureAccess(for: .region(savedRegion.rect), runOptions: options) else {
                return
            }

            let isPrivateCapture = beginCapturePrivacyLock()
            defer { endCapturePrivacyLock() }
            let autosaveSuspension = suspendEditorAutosaveForInteractiveCapture()
            defer { resumeEditorAutosaveAfterInteractiveCapture(autosaveSuspension) }
            let hiddenWindow = hideAppWindowIfNeeded()
            defer { restoreAppWindowIfNeeded(hiddenWindow) }

            if hiddenWindow != nil {
                try? await dependencies.systemServices.scheduler.sleep(nanoseconds: 200_000_000)
            }

            isWorking = true
            dependencies.lifecycle.updateWorkingMessage("Reposition Preset")
            defer { isWorking = false }

            do {
                let snapshot = try await captureService.captureDesktopOverlaySnapshot()
                let initialRect = fallbackRegionRect(for: savedRegion, in: snapshot)
                var fallbackPreferences = options.regionPreferences
                fallbackPreferences.showsActionControls = true
                fallbackPreferences.advancedControlsEnabled = true
                let session = RegionSelectionSession(
                    snapshot: snapshot,
                    preferences: fallbackPreferences,
                    initialSelectionRect: initialRect
                )

                guard let selection = await session.begin() else {
                    return
                }

                guard case let .region(region, cursorCaptureGlobalLocation) = selection else {
                    return
                }

                try await runCaptureDelayIfNeeded(actionName: "Capture Preset", delay: options.captureDelay)
                let capture: CapturedScreenshot
                do {
                    capture = try await captureService.captureRegionDirect(in: region)
                } catch {
                    let fallbackSnapshot = try await captureService.captureDesktopOverlaySnapshot()
                    capture = try await captureService.captureRegion(from: fallbackSnapshot, selection: region)
                }

                updateRegionTarget(forPresetID: presetID, rect: capture.sourceRect)
                showCapturedFeedback()
                try completeCapture(
                    capture,
                    request: .region(capture.sourceRect),
                    isPrivateCapture: isPrivateCapture,
                    cursorCaptureGlobalLocation: cursorCaptureGlobalLocation,
                    runOptions: options
                )
            } catch {
                present(error)
            }
        }
    }

    private func updateRegionTarget(forPresetID presetID: CapturePreset.ID, rect: CGRect) {
        guard let index = capturePresets.firstIndex(where: { $0.id == presetID }) else {
            return
        }

        var preset = capturePresets[index]
        preset.target = .region(savedCaptureRegion(for: rect))
        preset.updatedAt = dependencies.systemServices.clock.now()
        capturePresets[index] = preset
    }

    private func isSavedRegionAvailable(_ rect: CGRect, in snapshot: DesktopCompositeSnapshot) -> Bool {
        let region = rect.gscIntegralStandardized
        guard region.width > 2,
              region.height > 2,
              snapshot.globalFrame.contains(region) else {
            return false
        }

        let coveredArea = snapshot.displays.reduce(CGFloat.zero) { partial, display in
            partial + rectArea(display.frame.intersection(region))
        }

        return coveredArea >= max(rectArea(region) - 0.5, 0)
    }

    private func rectArea(_ rect: CGRect) -> CGFloat {
        let standardized = rect.gscIntegralStandardized
        guard !standardized.isNull else {
            return 0
        }

        return max(standardized.width, 0) * max(standardized.height, 0)
    }

    private func fallbackRegionRect(
        for savedRegion: SavedCaptureRegion,
        in snapshot: DesktopCompositeSnapshot
    ) -> CGRect {
        let display = currentPresetFallbackDisplay(in: snapshot, preferredID: savedRegion.displayID)
        let size = CGSize(
            width: min(max(savedRegion.rect.width, RegionPrecisionGeometry.minimumDimension), display.frame.width),
            height: min(max(savedRegion.rect.height, RegionPrecisionGeometry.minimumDimension), display.frame.height)
        )
        let origin = CGPoint(
            x: display.frame.midX - size.width / 2,
            y: display.frame.midY - size.height / 2
        )

        return CGRect(origin: origin, size: size)
            .gscIntegralStandardized
            .gscClamped(to: display.frame)
    }

    private func currentPresetFallbackDisplay(
        in snapshot: DesktopCompositeSnapshot,
        preferredID: CGDirectDisplayID?
    ) -> DisplaySnapshot {
        let currentCapturePoint = CursorCaptureGeometry.captureGlobalPoint(
            fromAppKitGlobalPoint: dependencies.systemServices.mouse.appKitGlobalLocation
        )
        if let currentCapturePoint,
           let display = snapshot.displays.first(where: { $0.frame.contains(currentCapturePoint) }) {
            return display
        }

        if let preferredID,
           let display = snapshot.displays.first(where: { $0.displayID == preferredID }) {
            return display
        }

        return snapshot.displays.first ?? DisplaySnapshot(
            displayID: 0,
            name: "Display",
            frame: CGRect(origin: .zero, size: savedFallbackDisplaySize),
            scale: 1
        )
    }

    private var savedFallbackDisplaySize: CGSize {
        CGSize(width: 800, height: 600)
    }
}
