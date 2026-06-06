import AppKit
import Foundation
import OSLog

private enum CapturePermissionDiagnostics {
    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.oontz.SnipSnipSnip",
        category: "CapturePermissions"
    )

    nonisolated static func staleReadyStateReconciled(
        cachedStatus: CapturePermissionStatus,
        preflightStatus: CapturePermissionStatus,
        verifiedScreenRecordingAccess: Bool
    ) {
        logger.error(
            "Reconciled stale capture permission state cachedHasScreenRecording=\(cachedStatus.hasScreenRecording) preflightHasScreenRecording=\(preflightStatus.hasScreenRecording) verifiedHasScreenRecording=\(verifiedScreenRecordingAccess) cachedHasAccessibility=\(cachedStatus.hasAccessibility) preflightHasAccessibility=\(preflightStatus.hasAccessibility)"
        )
    }

    nonisolated static func permissionDeniedDuringCapture(
        error: Error,
        cachedStatus: CapturePermissionStatus,
        preflightStatus: CapturePermissionStatus
    ) {
        let nsError = error as NSError
        logger.error(
            "Screen recording permission denied during capture cachedHasScreenRecording=\(cachedStatus.hasScreenRecording) preflightHasScreenRecording=\(preflightStatus.hasScreenRecording) cachedHasAccessibility=\(cachedStatus.hasAccessibility) preflightHasAccessibility=\(preflightStatus.hasAccessibility) errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code) errorDescription=\(nsError.localizedDescription, privacy: .public)"
        )
    }
}

extension AppModel {
    func suspendEditorAutosaveForInteractiveCapture() -> InteractiveCaptureAutosaveSuspension {
        interactiveCaptureAutosaveSuspensionDepth += 1

        let suspension = InteractiveCaptureAutosaveSuspension(
            editorControllerID: editorController.map(ObjectIdentifier.init)
        )

        pendingAutosaveTask?.cancel()
        pendingAutosaveTask = nil
        return suspension
    }

    func resumeEditorAutosaveAfterInteractiveCapture(_ suspension: InteractiveCaptureAutosaveSuspension) {
        interactiveCaptureAutosaveSuspensionDepth = max(0, interactiveCaptureAutosaveSuspensionDepth - 1)

        guard interactiveCaptureAutosaveSuspensionDepth == 0,
              let controller = editorController,
              suspension.editorControllerID == ObjectIdentifier(controller),
              shouldAutosave(for: controller) else {
            return
        }

        scheduleAutosave(for: controller)
    }

    func refreshPermissions() {
        let status = CapturePermissionStatus.current()
        if status != permissionStatus {
            permissionStatus = status
        }

        reconcileVerifiedScreenRecordingAccess(using: status)
    }

    func reconcileScreenRecordingPermissionDenied(after error: Error? = nil) {
        pendingScreenRecordingPermissionVerificationTask?.cancel()
        pendingScreenRecordingPermissionVerificationTask = nil
        screenRecordingPermissionVerificationGeneration += 1

        let status = CapturePermissionStatus.current()
        let cachedStatus = permissionStatus
        let reconciledStatus = CapturePermissionStatus(
            hasScreenRecording: false,
            hasAccessibility: status.hasAccessibility
        )

        if let error,
           cachedStatus.hasScreenRecording || status.hasScreenRecording {
            CapturePermissionDiagnostics.permissionDeniedDuringCapture(
                error: error,
                cachedStatus: cachedStatus,
                preflightStatus: status
            )
        }

        if reconciledStatus != permissionStatus {
            permissionStatus = reconciledStatus
        }
    }

    private func reconcileVerifiedScreenRecordingAccess(using status: CapturePermissionStatus) {
        pendingScreenRecordingPermissionVerificationTask?.cancel()

        guard status.hasScreenRecording else {
            pendingScreenRecordingPermissionVerificationTask = nil
            screenRecordingPermissionVerificationGeneration += 1
            return
        }

        screenRecordingPermissionVerificationGeneration += 1
        let verificationGeneration = screenRecordingPermissionVerificationGeneration

        pendingScreenRecordingPermissionVerificationTask = Task { [weak self] in
            let hasVerifiedAccess = await ScreenCapturePermissions.verifyScreenRecordingAccess()

            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                guard let self,
                      self.screenRecordingPermissionVerificationGeneration == verificationGeneration else {
                    return
                }

                let currentStatus = CapturePermissionStatus.current()
                let reconciledStatus = CapturePermissionStatus(
                    hasScreenRecording: currentStatus.hasScreenRecording && hasVerifiedAccess,
                    hasAccessibility: currentStatus.hasAccessibility
                )

                if currentStatus.hasScreenRecording && !hasVerifiedAccess {
                    CapturePermissionDiagnostics.staleReadyStateReconciled(
                        cachedStatus: self.permissionStatus,
                        preflightStatus: currentStatus,
                        verifiedScreenRecordingAccess: hasVerifiedAccess
                    )
                }

                if reconciledStatus != self.permissionStatus {
                    self.permissionStatus = reconciledStatus
                }

                self.pendingScreenRecordingPermissionVerificationTask = nil
            }
        }
    }

    func requestScreenRecordingAccess() {
        requestPermission(.screenRecording)
    }

    func requestAccessibilityAccess() {
        guard FeatureFlags.accessibilityAutomationEnabled else {
            return
        }

        requestPermission(.accessibility)
    }

    func requestMissingCapturePermissions() {
        refreshPermissions()

        guard let nextRequirement = permissionStatus.missingRequirements.first else {
            return
        }

        requestPermission(nextRequirement)
    }

    func requestPermission(_ requirement: CapturePermissionRequirement) {
        guard CapturePermissionRequirement.availableCases.contains(requirement) else {
            permissionSetupGuide = nil
            return
        }

        _ = ScreenCapturePermissions.requestAccess(for: requirement)
        refreshPermissions()

        if requirement == .screenRecording, permissionStatus.hasScreenRecording {
            refreshAvailableWindows()
        }

        if permissionStatus.hasAccess(to: requirement) {
            permissionSetupGuide = nil
            return
        }

        if requirement == .accessibility {
            openAccessibilitySettingsAfterPromptOpportunity()
            presentPermissionSetupGuide(for: .accessibility)
            return
        }

        permissionSetupGuide = nil
    }

    func openAccessibilitySettingsAfterPromptOpportunity() {
        guard FeatureFlags.accessibilityAutomationEnabled else {
            return
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self else {
                return
            }

            self.refreshPermissions()

            guard !self.permissionStatus.hasAccessibility else {
                self.permissionSetupGuide = nil
                return
            }

            ScreenCapturePermissions.openSystemSettings(for: .accessibility)
            self.presentPermissionSetupGuide(for: .accessibility)
        }
    }

    func openPermissionSettings(_ requirement: CapturePermissionRequirement) {
        ScreenCapturePermissions.openSystemSettings(for: requirement)
        refreshPermissions()
    }

    func captureCurrentDisplay() {
        runActionWhenPermissionsReady([.screenRecording], featureName: "Capture") { [weak self] in
            self?.beginFullscreenCapture()
        }
    }

    func captureRegion() {
        runActionWhenPermissionsReady([.screenRecording], featureName: "Capture") { [weak self] in
            self?.beginRegionCapture()
        }
    }

    func captureScrollingArea() {
        guard FeatureFlags.scrollingCaptureEnabled else {
            return
        }

        runActionWhenPermissionsReady([.screenRecording, .accessibility], featureName: "Scrolling Capture") { [weak self] in
            self?.beginScrollingCapture()
        }
    }

    func captureFrontmostWindow() {
        runActionWhenPermissionsReady([.screenRecording], featureName: "Capture") { [weak self] in
            self?.beginFrontmostWindowCapture()
        }
    }

    func presentWindowPicker() {
        runActionWhenPermissionsReady([.screenRecording], featureName: "Capture") { [weak self] in
            self?.windowPickerMode = .screenshot
            self?.beginWindowPickerPresentation()
        }
    }

    func repeatLastCapture() {
        beginRepeatLastCapture()
    }

    func refreshAvailableWindows(
        includeThumbnails: Bool = true,
        allowsCancellingPendingThumbnailRefresh: Bool = true
    ) {
        Task {
            guard !isLoadingWindowChoices else {
                return
            }

            if !allowsCancellingPendingThumbnailRefresh, pendingWindowThumbnailTask != nil {
                return
            }

            await loadAvailableWindows(
                requestAccessIfNeeded: false,
                presentPicker: false,
                showErrors: false,
                includeThumbnails: includeThumbnails,
                allowsCancellingPendingThumbnailRefresh: allowsCancellingPendingThumbnailRefresh
            )
        }
    }

    func pickWindowOnScreen() {
        let windows = availableWindows
        isShowingWindowPicker = false

        Task {
            let isPrivateCapture = beginCapturePrivacyLock()
            defer { endCapturePrivacyLock() }
            let autosaveSuspension = suspendEditorAutosaveForInteractiveCapture()
            defer { resumeEditorAutosaveAfterInteractiveCapture(autosaveSuspension) }
            let hiddenWindow = hideAppWindowIfNeeded()
            defer { restoreAppWindowIfNeeded(hiddenWindow) }

            if hiddenWindow != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }

            guard ensureScreenRecordingAccess() else {
                return
            }

            isWorking = true
            workingMessage = captureDelay == .immediate ? "Pick Window" : captureDelay.shortLabel
            defer { isWorking = false }

            do {
                try await runCaptureDelayIfNeeded(actionName: "Pick Window")
                let windowOptions = windows.isEmpty ? try await captureService.listWindows(includeThumbnails: false) : windows
                let snapshot = try await captureService.captureDesktopOverlaySnapshot()
                let session = WindowSelectionSession(snapshot: snapshot, windows: windowOptions)

                guard let selectedWindow = await session.begin() else {
                    return
                }

                let capture = try await captureService.captureWindow(selectedWindow)
                try completeCapture(capture, request: .window(selectedWindow), isPrivateCapture: isPrivateCapture)
            } catch {
                present(error)
            }
        }
    }

    func captureWindow(_ window: CaptureWindowSummary) {
        isShowingWindowPicker = false

        Task {
            await performCapture(request: .window(window)) {
                try await captureService.captureWindow(window)
            }
        }
    }

    func updatePrivateCaptureEnabled(_ enabled: Bool) {
        guard canChangePrivateCapture else {
            errorMessage = "Private Capture cannot be changed while a capture or recording is active. The in-progress capture will use the privacy setting it started with."
            return
        }

        privateCaptureEnabled = enabled
    }

    func beginCapturePrivacyLock() -> Bool {
        let latchedPrivateCapture = privateCaptureEnabled
        capturePrivacyLockDepth += 1
        isCapturePrivacyLocked = true
        return latchedPrivateCapture
    }

    func endCapturePrivacyLock() {
        capturePrivacyLockDepth = max(0, capturePrivacyLockDepth - 1)
        isCapturePrivacyLocked = capturePrivacyLockDepth > 0
    }

    func dismissError() {
        errorMessage = nil
    }

    func dismissPermissionSetupGuide() {
        permissionSetupGuide = nil
        refreshPermissions()
    }

    func revealAppForPermissionSetup() {
        ScreenCapturePermissions.revealCurrentAppInFinder()
    }

    func copyAppPathForPermissionSetup() {
        ScreenCapturePermissions.copyCurrentAppPathToPasteboard()
    }

    func openPermissionSettingsFromGuide() {
        guard let permissionSetupGuide else {
            return
        }

        openPermissionSettings(permissionSetupGuide.requirement)
    }

    func checkPermissionSetupGuideStatus() {
        refreshPermissions()

        guard let permissionSetupGuide,
              permissionStatus.hasAccess(to: permissionSetupGuide.requirement) else {
            return
        }

        self.permissionSetupGuide = nil
        errorMessage = nil
    }

    func requestMainWindowPresentation() {
        promoteToRegularApp()
        mainWindowPresentationRequest += 1
    }

    func handleApplicationDidBecomeActive() {
        refreshPermissions()
        refreshLaunchAtLoginStatus()
        checkPermissionSetupGuideStatus()

        if !autoRefreshWindowsEnabled {
            refreshAvailableWindowsOnApplicationForegroundIfNeeded()
        }

        guard let pendingPermissionAction else {
            return
        }

        let stillMissingRequirements = pendingPermissionAction.requirements.filter {
            !permissionStatus.hasAccess(to: $0)
        }

        guard stillMissingRequirements.isEmpty else {
            return
        }

        self.pendingPermissionAction = nil
        pendingPermissionAction.action()
    }

    func refreshAvailableWindowsOnApplicationForegroundIfNeeded() {
        guard !isInteractiveCaptureActive,
              editorController == nil,
              videoEditorController == nil,
              !isWorking,
              !isShowingWindowPicker,
              permissionStatus.hasScreenRecording else {
            return
        }

        refreshAvailableWindows(
            includeThumbnails: true,
            allowsCancellingPendingThumbnailRefresh: false
        )
    }

    func prepareForMainWindowPresentation() {
        promoteToRegularApp()
    }

    func mainWindowDidAppear() {
        promoteToRegularApp()
        syncMainWindowDocumentState()
        resizeMainWindowForEditorContentIfNeeded()
    }

    func mainWindowDidDisappear() {
        Task { @MainActor [weak self] in
            self?.demoteToAccessoryIfPossible()
        }
    }

    func beginFullscreenCapture() {
        Task {
            await performCapture(request: .fullscreen, minimizeAppWindow: true) {
                try await captureService.captureCurrentDisplay()
            }
        }
    }

    func beginFrontmostWindowCapture() {
        Task {
            await performCapture(request: .frontmostWindow) {
                let window = try await captureService.frontmostWindow()
                return try await captureService.captureWindow(window)
            }
        }
    }

    func beginRegionCapture() {
        Task {
            guard ensureScreenRecordingAccess() else {
                return
            }

            let isPrivateCapture = beginCapturePrivacyLock()
            defer { endCapturePrivacyLock() }
            let autosaveSuspension = suspendEditorAutosaveForInteractiveCapture()
            defer { resumeEditorAutosaveAfterInteractiveCapture(autosaveSuspension) }

            let hiddenWindow = hideAppWindowIfNeeded()
            defer { restoreAppWindowIfNeeded(hiddenWindow) }

            try? await Task.sleep(nanoseconds: 200_000_000)

            isWorking = true
            workingMessage = captureDelay == .immediate ? "Capture Region" : captureDelay.shortLabel
            defer { isWorking = false }

            do {
                try await runCaptureDelayIfNeeded(actionName: "Capture Region")
                let snapshot = try await captureService.captureDesktopOverlaySnapshot()
                let session = RegionSelectionSession(snapshot: snapshot, preferences: regionCapturePreferences)

                guard case let .region(region, cursorCaptureGlobalLocation) = await session.begin() else {
                    return
                }

                let capture: CapturedScreenshot
                do {
                    capture = try await captureService.captureRegionDirect(in: region)
                } catch {
                    capture = try await captureService.captureRegion(from: snapshot, selection: region)
                }
                try completeCapture(
                    capture,
                    request: .region(capture.sourceRect),
                    isPrivateCapture: isPrivateCapture,
                    cursorCaptureGlobalLocation: cursorCaptureGlobalLocation
                )
            } catch {
                present(error)
            }
        }
    }

    func beginScrollingCapture() {
        guard FeatureFlags.scrollingCaptureEnabled else {
            return
        }

        Task {
            guard ensurePermissions([.screenRecording, .accessibility], for: "Scrolling Capture") else {
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

            try? await Task.sleep(nanoseconds: 200_000_000)

            isWorking = true
            workingMessage = captureDelay == .immediate ? "Scrolling Capture" : captureDelay.shortLabel
            defer { isWorking = false }

            do {
                try await runCaptureDelayIfNeeded(actionName: "Scrolling Capture")
                let snapshot = try await captureService.captureDesktopOverlaySnapshot()
                let session = ScrollingSelectionSession(snapshot: snapshot)

                guard let region = await session.begin() else {
                    return
                }

                try await Task.sleep(nanoseconds: 180_000_000)
                try await performScrollingCapture(in: region, isPrivateCapture: isPrivateCapture)
                completedCapture = true
            } catch ScrollingCaptureError.cancelled {
                return
            } catch {
                present(error)
            }
        }
    }

    func beginWindowPickerPresentation() {
        requestMainWindowPresentation()

        Task {
            await loadAvailableWindows(requestAccessIfNeeded: true, presentPicker: true, showErrors: true, includeThumbnails: true)
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
            guard FeatureFlags.scrollingCaptureEnabled else {
                return
            }
            repeatScrollingCapture(region)
        case .window(let window):
            repeatWindowCapture(window)
        case .frontmostWindow:
            captureFrontmostWindow()
        case .fullscreen:
            captureCurrentDisplay()
        }
    }

    func performCapture(request: LastCaptureRequest, minimizeAppWindow: Bool = false, _ action: () async throws -> CapturedScreenshot) async {
        guard ensureScreenRecordingAccess() else {
            return
        }

        let isPrivateCapture = beginCapturePrivacyLock()
        defer { endCapturePrivacyLock() }

        let hiddenWindow = minimizeAppWindow ? hideAppWindowIfNeeded() : nil
        defer { restoreAppWindowIfNeeded(hiddenWindow) }

        if hiddenWindow != nil {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        isWorking = true
        workingMessage = captureDelay == .immediate ? "Capturing" : captureDelay.shortLabel
        defer { isWorking = false }

        do {
            try await runCaptureDelayIfNeeded(actionName: "Capturing")
            let capture = try await action()
            try completeCapture(capture, request: request, isPrivateCapture: isPrivateCapture)
        } catch {
            present(error)
        }
    }

    func repeatRegionCapture(_ region: CGRect) {
        Task {
            await performCapture(request: .region(region)) {
                try await captureService.captureRegion(in: region)
            }
        }
    }

    func repeatScrollingCapture(_ region: CGRect) {
        guard FeatureFlags.scrollingCaptureEnabled else {
            return
        }

        Task {
            guard ensurePermissions([.screenRecording, .accessibility], for: "Scrolling Capture") else {
                return
            }

            let isPrivateCapture = beginCapturePrivacyLock()
            defer { endCapturePrivacyLock() }

            isWorking = true
            workingMessage = captureDelay == .immediate ? "Scrolling Capture" : captureDelay.shortLabel
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

    func repeatWindowCapture(_ window: CaptureWindowSummary) {
        Task {
            guard ensureScreenRecordingAccess() else {
                return
            }

            let isPrivateCapture = beginCapturePrivacyLock()
            defer { endCapturePrivacyLock() }

            isWorking = true
            workingMessage = captureDelay == .immediate ? "Capturing Window" : captureDelay.shortLabel
            defer { isWorking = false }

            do {
                try await runCaptureDelayIfNeeded(actionName: "Capturing Window")
                let resolvedWindow = try await captureService.resolveWindowTarget(window)
                let capture = try await captureService.captureWindow(resolvedWindow)
                try completeCapture(capture, request: .window(resolvedWindow), isPrivateCapture: isPrivateCapture)
            } catch let error as ScreenCaptureError where error == .windowImageUnavailable || error == .noWindowsAvailable {
                requestMainWindowPresentation()
                await loadAvailableWindows(requestAccessIfNeeded: false, presentPicker: true, showErrors: true, includeThumbnails: true)
            } catch {
                present(error)
            }
        }
    }

    func loadAvailableWindows(
        requestAccessIfNeeded: Bool,
        presentPicker: Bool,
        showErrors: Bool,
        includeThumbnails: Bool,
        allowsCancellingPendingThumbnailRefresh: Bool = true
    ) async {
        if isLoadingWindowChoices {
            if presentPicker {
                isShowingWindowPicker = true
            }

            return
        }

        refreshPermissions()

        guard permissionStatus.hasScreenRecording else {
            availableWindows = []

            if requestAccessIfNeeded {
                requestPermission(.screenRecording)
                refreshPermissions()

                if !permissionStatus.hasScreenRecording {
                    errorMessage = nil
                    requestMainWindowPresentation()
                }
            }

            return
        }

        if allowsCancellingPendingThumbnailRefresh {
            pendingWindowThumbnailTask?.cancel()
            pendingWindowThumbnailTask = nil
        }

        isLoadingWindowChoices = true

        if presentPicker {
            isWorking = true
        }

        defer {
            isLoadingWindowChoices = false

            if presentPicker {
                isWorking = false
            }
        }

        do {
            let shouldStageThumbnails = includeThumbnails && (presentPicker || !availableWindows.isEmpty)
            let windows = try await captureService.listWindows(includeThumbnails: shouldStageThumbnails ? false : includeThumbnails)
            availableWindows = mergedWindowSummaries(windows)
            if includeThumbnails && !shouldStageThumbnails {
                windowThumbnailRefreshGeneration += 1
            }

            if presentPicker {
                isShowingWindowPicker = true
            }

            if shouldStageThumbnails {
                scheduleWindowThumbnailRefresh(showErrors: showErrors)
            }
        } catch {
            if presentPicker {
                availableWindows = []
            }

            if showErrors {
                present(error)
            }
        }
    }

    func scheduleWindowThumbnailRefresh(showErrors: Bool) {
        pendingWindowThumbnailTask?.cancel()

        pendingWindowThumbnailTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                let windows = try await self.captureService.listWindows(includeThumbnails: true)

                guard !Task.isCancelled else {
                    return
                }

                self.availableWindows = self.mergedWindowSummaries(windows)
                self.windowThumbnailRefreshGeneration += 1
                self.pendingWindowThumbnailTask = nil
            } catch {
                guard !Task.isCancelled else {
                    return
                }

                self.pendingWindowThumbnailTask = nil

                if showErrors {
                    self.present(error)
                }
            }
        }
    }

    func completeCapture(
        _ capture: CapturedScreenshot,
        request: LastCaptureRequest,
        isPrivateCapture: Bool,
        cursorCaptureGlobalLocation: CGPoint? = nil
    ) throws {
        shelveCurrentDocumentForRecents()
        let cursorAwareCapture = capture.attachingCursorOverlay(currentCursorOverlay(
            for: capture,
            cursorCaptureGlobalLocation: cursorCaptureGlobalLocation
        ))
        let controller = EditorController(capture: cursorAwareCapture)
        installEditorController(
            controller,
            documentURL: nil,
            savedSession: nil,
            shouldCreateRecoverySession: !isPrivateCapture,
            initialCheckpointLabel: isPrivateCapture ? nil : "Capture"
        )
        lastCaptureRequest = request

        if !isPrivateCapture {
            scheduleClipboardSnipRecording(
                from: controller,
                searchableText: cursorAwareCapture.sourceName,
                sessionID: currentRecoverySessionID
            )
        }

        if autoCopyEnabled {
            copyCurrentEditorImageToClipboard()
        }
        requestMainWindowPresentation()
    }

    private func currentCursorOverlay(
        for capture: CapturedScreenshot,
        cursorCaptureGlobalLocation: CGPoint? = nil
    ) -> CapturedCursorOverlay? {
        guard screenshotIncludesCursor, capture.kind != .scrolling else {
            return nil
        }

        let cursor = NSCursor.current
        let resolvedCaptureCursorLocation = cursorCaptureGlobalLocation
            ?? CursorCaptureGeometry.captureGlobalPoint(fromAppKitGlobalPoint: NSEvent.mouseLocation)
        let cursorImage = cursor.image
        var proposedRect = CGRect(origin: .zero, size: cursorImage.size)
        guard let image = cursorImage.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil),
              let captureCursorLocation = resolvedCaptureCursorLocation,
              let rect = CursorCaptureGeometry.overlayRect(
                cursorCaptureGlobalLocation: captureCursorLocation,
                cursorHotSpot: cursor.hotSpot,
                cursorSize: cursorImage.size,
                captureSourceRect: capture.sourceRect,
                capturePixelSize: capture.pixelSize
              ) else {
            return nil
        }

        return CapturedCursorOverlay(image: image, rect: rect)
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

        let service = ScrollingCaptureService(captureService: captureService)
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

        if let warning = result.warnings.last {
            errorMessage = warning
        }
    }

    func ensureScreenRecordingAccess() -> Bool {
        ensurePermissions([.screenRecording], for: "Capture")
    }

    func ensureAccessibilityAccess() -> Bool {
        guard FeatureFlags.accessibilityAutomationEnabled else {
            return false
        }

        return ensurePermissions([.accessibility], for: "Scrolling Capture")
    }

    func ensurePermissions(_ requirements: [CapturePermissionRequirement], for featureName: String) -> Bool {
        refreshPermissions()

        let missingRequirements = requirements.filter { !permissionStatus.hasAccess(to: $0) }

        guard let firstMissingRequirement = missingRequirements.first else {
            return true
        }

        requestPermission(firstMissingRequirement)
        refreshPermissions()

        let stillMissingRequirements = requirements.filter { !permissionStatus.hasAccess(to: $0) }

        guard stillMissingRequirements.isEmpty else {
            errorMessage = nil
            requestMainWindowPresentation()
            return false
        }

        if requirements.contains(.screenRecording) {
            refreshPermissions()
        }

        return true
    }

    func runActionWhenPermissionsReady(
        _ requirements: [CapturePermissionRequirement],
        featureName: String,
        action: @escaping @MainActor () -> Void
    ) {
        guard ensurePermissions(requirements, for: featureName) else {
            pendingPermissionAction = PendingPermissionAction(requirements: requirements, action: action)
            return
        }

        pendingPermissionAction = nil
        action()
    }

    func presentPermissionSetupGuide(for requirement: CapturePermissionRequirement) {
        refreshPermissions()

        guard !permissionStatus.hasAccess(to: requirement) else {
            permissionSetupGuide = nil
            return
        }

        permissionSetupGuide = PermissionSetupGuide(
            requirement: requirement,
            appName: ScreenCapturePermissions.currentAppName,
            appPath: ScreenCapturePermissions.currentAppPath
        )
    }

    func permissionGuidanceMessage(
        for requirements: [CapturePermissionRequirement],
        featureName: String
    ) -> String {
        let uniqueRequirements = CapturePermissionRequirement.availableCases.filter { requirements.contains($0) }

        if uniqueRequirements == [.accessibility] {
            return "Scrolling Capture needs Accessibility access so SnipSnipSnip can scroll the selected app while capturing. If SnipSnipSnip is not listed yet, click Grant once to trigger the macOS prompt, then use the setup guide to reveal and add this exact app."
        }

        if uniqueRequirements == [.screenRecording] {
            return "\(featureName) needs Screen Recording access so SnipSnipSnip can read pixels from the screen. Click Grant Access in the main window, then enable SnipSnipSnip in System Settings > Privacy & Security > Screen Recording."
        }

        return "\(featureName) needs Screen Recording access to capture pixels. Click Grant Access in the main window, then enable SnipSnipSnip in System Settings > Privacy & Security > Screen Recording."
    }

    func present(_ error: Error) {
        guard !(error is CancellationError) else {
            return
        }

        if ScreenCapturePermissions.indicatesScreenRecordingPermissionFailure(error) {
            reconcileScreenRecordingPermissionDenied(after: error)
        }

        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        requestMainWindowPresentation()
    }

    func mergedWindowSummaries(_ windows: [CaptureWindowSummary]) -> [CaptureWindowSummary] {
        let existingWindows = Dictionary(uniqueKeysWithValues: availableWindows.map { ($0.id, $0) })

        return windows.map { window in
            CaptureWindowSummary(
                id: window.id,
                ownerName: window.ownerName,
                ownerPID: window.ownerPID,
                title: window.title,
                frame: window.frame,
                layer: window.layer,
                focusRank: window.focusRank,
                thumbnail: window.thumbnail ?? existingWindows[window.id]?.thumbnail
            )
        }
    }

    func runCaptureDelayIfNeeded(actionName: String) async throws {
        guard captureDelay.countdownSeconds > 0 else {
            workingMessage = actionName
            return
        }

        for remainingSeconds in stride(from: captureDelay.countdownSeconds, through: 1, by: -1) {
            workingMessage = "\(actionName) in \(remainingSeconds)…"
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        workingMessage = actionName
    }

    func hideAppWindowIfNeeded(in windows: [NSWindow] = NSApp.windows) -> NSWindow? {
        let window = windows.first(where: {
            $0.identifier?.rawValue == AppSceneID.mainWindow && $0.isVisible && !$0.isMiniaturized
        }) ?? nonRulerWindow(NSApp.keyWindow) ?? nonRulerWindow(NSApp.mainWindow) ?? windows.first(where: {
            $0.isVisible && !$0.isMiniaturized && !ScreenRulerWindowID.isScreenRulerWindow($0)
        })

        guard let window, window.isVisible, !window.isMiniaturized else {
            return nil
        }

        window.orderOut(nil)
        return window
    }

    private func nonRulerWindow(_ window: NSWindow?) -> NSWindow? {
        guard let window, !ScreenRulerWindowID.isScreenRulerWindow(window) else {
            return nil
        }

        return window
    }

    func restoreAppWindowIfNeeded(_ window: NSWindow?) {
        guard let window else {
            return
        }

        promoteToRegularApp()
        NSApp.activate(ignoringOtherApps: true)

        if NSApp.windows.contains(where: { $0 === window }) {
            window.makeKeyAndOrderFront(nil)
            return
        }

        requestMainWindowPresentation()
    }

    func promoteToRegularApp() {
        guard NSApp.activationPolicy() != .regular else {
            return
        }

        NSApp.setActivationPolicy(.regular)
    }

    func demoteToAccessoryIfPossible() {
        let hasOpenMainWindow = NSApp.windows.contains { window in
            window.identifier?.rawValue == AppSceneID.mainWindow && (window.isVisible || window.isMiniaturized)
        }

        guard !hasOpenMainWindow, NSApp.activationPolicy() != .accessory else {
            return
        }

        NSApp.setActivationPolicy(.accessory)
    }
}
