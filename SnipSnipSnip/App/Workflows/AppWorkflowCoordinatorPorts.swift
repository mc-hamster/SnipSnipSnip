import Combine
import Foundation

@MainActor
protocol CoordinatorLifecyclePort: AnyObject {
    func presentError(_ message: String)
    func requestMainWindowPresentation()
    func requestOnboardingPresentation()
    func refreshLaunchAtLoginStatus()
    func presentBusyHotKeyFeedback(message: String)
}

@MainActor
protocol CoordinatorPermissionPort: AnyObject {
    var permissionStatus: CapturePermissionStatus { get }

    func refreshPermissions()
    func checkPermissionSetupGuideStatus()
}

@MainActor
protocol CoordinatorCapturePort: AnyObject {
    var isConnectedDeviceSessionActive: Bool { get }
    var autoRefreshWindowsEnabled: Bool { get }
    var isInteractiveCaptureActive: Bool { get }
    var isWorking: Bool { get }
    var isShowingWindowPicker: Bool { get }
    var canRepeatLastCapture: Bool { get }

    func resetCapturePreferencesToDefaults()
    func notifyPermissionsChanged()
    func cancelPendingPermissionCommand()
    func retryPendingPermissionCommandIfSatisfied(_ status: CapturePermissionStatus)
    func recordCompletedCapture(request: LastCaptureRequest, runOptions: CaptureRunOptions)
    func scheduleUIMapCapture(
        for controller: EditorController,
        capture: CapturedScreenshot,
        compositionAssetID: UUID?,
        isPrivateCapture: Bool
    )
    func noticeSkippedUIMapCapture(
        reason: String?,
        isPrivateCapture: Bool
    )
    func promoteToRegularApp()
    func demoteToAccessoryIfPossible()
    func refreshAvailableWindows(
        includeThumbnails: Bool,
        allowsCancellingPendingThumbnailRefresh: Bool
    )
    func captureRegion()
    func captureCurrentDisplay()
    func captureFrontmostWindow()
    func capturePreset(_ preset: CapturePreset)
    func capturePreset(id: CapturePreset.ID)
    func refreshConnectedDevices()
    func completeScreenInspectorSnip(_ sample: ScreenInspectorSample)
    func setConnectedDeviceSessionActive(_ isActive: Bool)
    func beginRegionCapture()
    func presentWindowPicker()
    func repeatLastCapture()
}

@MainActor
protocol CoordinatorDocumentPort: AnyObject {
    var editorController: EditorController? { get }
    var videoEditorController: VideoEditorController? { get }
    var guideEditorController: GuideEditorController? { get }
    var currentRecoverySessionID: UUID? { get }

    func resetDocumentPreferencesToDefaults()
    func installCapturedScreenshot(_ result: CaptureWorkflowResult) -> CaptureInstallationResult
    func scheduleAutoCopy(for controller: EditorController)
    func copyCurrentEditorImageToClipboard()
    func exportWorkflowCapture(
        from controller: EditorController,
        to destination: CapturePresetExportDestination
    ) async throws -> URL
    func cancelPendingAutoCopy()
    func installCapturedRecording(_ recording: CapturedVideoRecording)
    func installCapturedGuide(_ document: EditableGuideDocument)
    func exportCurrentGuide()
    func refreshHistoryEntries()
    func syncMainWindowDocumentState()
    func resizeMainWindowForEditorContentIfNeeded(animated: Bool)
    func openDocument(at url: URL)
    func saveDocument(_ controller: EditorController, to url: URL) async -> Bool
    func floatCurrentEditorReference()
    func handleIncompatibleRecoveryEntriesOnLaunch()
    func cleanupStalePackageTemporaryDirectories()
}

@MainActor
protocol CoordinatorClipboardPort: AnyObject {
    var autoCopyEnabled: Bool { get }

    func resetClipboardPreferencesToDefaults()
    func scheduleClipboardSnipRecording(
        from controller: EditorController,
        searchableText: String,
        sessionID: UUID?,
        willBeCopied: Bool
    )
    func notifyDocumentChanged()
    func startMonitoring()
}

@MainActor
protocol CoordinatorAutomationPort: AnyObject {
    func resultAfterCurrentEditorOutput(
        request: AutomationRequest,
        kind: String,
        sourceName: String?
    ) async -> AutomationResultEnvelope
}

@MainActor
protocol CoordinatorVideoPort: AnyObject {
    var isRecording: Bool { get }

    func resetVideoPreferencesToDefaults()
}

@MainActor
protocol CoordinatorArchivePort: AnyObject {
    func resetArchivePreferencesToDefaults()
    func activateArchiveDirectoryAccess(_ url: URL?)
    func startArchiveMaintenance()
}

@MainActor
protocol CoordinatorToolPort: AnyObject {
    func resetToolPreferencesToDefaults()
    func toggleScreenInspector()
    func closeScreenInspector()
}

@MainActor
extension AppLifecycleModel: CoordinatorLifecyclePort {}

@MainActor
extension AppLifecycleModel: WorkflowLifecyclePresenting {}

@MainActor
extension PermissionWorkflowModel: CoordinatorPermissionPort {}

@MainActor
extension CaptureWorkflowModel: CoordinatorCapturePort {
    func resetCapturePreferencesToDefaults() {
        autoRefreshWindowsEnabled = false
        captureDelay = .immediate
        capturePresets = []
        screenshotIncludesCursor = false
        screenshotFullscreenDisplayMode = .currentDisplay
        selectedScreenshotFullscreenDisplayID = nil
        screenshotJPEGQuality = ImageExportOptions.default.jpegQuality
        regionCapturePreferences = RegionCapturePreferences()
        screenshotFilenameTemplate = ScreenshotFilenameTemplate.defaultPattern
        screenshotDragOutFormat = .png
        privateCaptureEnabled = false
        uiMapEnabled = dependencies.capabilities.isEnabled(.uiMap)
        automationPreferences = CaptureAutomationPreferences()
    }

    func notifyPermissionsChanged() {
        objectWillChange.send()
    }

    func setConnectedDeviceSessionActive(_ isActive: Bool) {
        isConnectedDeviceSessionActive = isActive
    }
}

@MainActor
extension DocumentWorkflowModel: CoordinatorDocumentPort {
    func resetDocumentPreferencesToDefaults() {
        editorSingleKeyToolShortcutsEnabled = true
        editorStartupToolPreference = .default
        updateEditorCropOutsideOverlayAlpha(AppPreferenceDefaults.editorCropOutsideOverlayAlpha)
        updateEditorOutOfCapturePatternSettings(.default)
        resetPresentationScenesRootToDefault()
        uiMapPinnedOverlayDefaults = UIMapOverlayOptions()
    }

    func cleanupStalePackageTemporaryDirectories() {
        try? PackageTemporaryDirectoryJanitor.cleanupStalePackageTemporaryDirectories()
    }
}

@MainActor
extension ClipboardWorkflowModel: CoordinatorClipboardPort {
    func resetClipboardPreferencesToDefaults() {
        autoCopyEnabled = true
        preferences = .default
        historyStore.deactivateStorage()
        searchQuery = ""
        filter = .all
    }

    func startMonitoring() {
        monitor.start(preferences: preferences)
    }

    func notifyDocumentChanged() {
        objectWillChange.send()
    }
}

@MainActor
extension AutomationWorkflowModel: CoordinatorAutomationPort {}

@MainActor
extension AppWorkflowCoordinator: CaptureAutomationCoordinatorPort {}

@MainActor
extension AppWorkflowCoordinator: DocumentAutomationCoordinatorPort {}

@MainActor
extension VideoWorkflowModel: CoordinatorVideoPort {
    func resetVideoPreferencesToDefaults() {
        recordingPreferences = VideoRecordingPreferences()
        exportPreferences = VideoExportPreferences()
    }
}

@MainActor
extension ArchiveWorkflowModel: CoordinatorArchivePort {
    func resetArchivePreferencesToDefaults() {
        maximumSizeMB = ArchiveWorkflowConstants.defaultMaximumSizeMB
        recycleBinRetentionDays = ArchiveWorkflowConstants.defaultRecycleBinRetentionDays

        if !usesDefaultArchiveLocation {
            resetArchiveLocationToDefault()
        }
    }
}

@MainActor
extension ToolWorkflowModel: CoordinatorToolPort {
    func resetToolPreferencesToDefaults() {
        screenRulerPreferences = .default
        screenInspectorPreferences = .default
    }
}
