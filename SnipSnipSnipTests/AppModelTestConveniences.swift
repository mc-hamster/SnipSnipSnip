import AppKit
import Foundation
@testable import SnipSnipSnip

@MainActor
extension AppModel {
    @_disfavoredOverload
    convenience init(
        defaults: UserDefaults = .standard,
        environment: AppEnvironment? = nil,
        recoveryStore: DocumentRecoveryStore? = nil,
        videoRecoveryStore: VideoRecoveryStore? = nil,
        clipboardHistoryStore: ClipboardHistoryStore? = nil,
        captureService: (any ScreenCaptureServiceType)? = nil,
        screenRecordingService: ScreenRecordingService? = nil,
        uiMapCaptureService: (any UIMapCaptureServiceType)? = nil,
        connectedDeviceCaptureService: (any ConnectedDeviceCaptureServiceType)? = nil,
        incompatibleDocumentCoordinator: IncompatibleDocumentCoordinator = IncompatibleDocumentCoordinator(),
        launchAtLoginController: LaunchAtLoginController = LaunchAtLoginController(),
        shouldCheckCompatibilityOnLaunch: Bool = !AppModel.isRunningUnitTests,
        shouldStartArchiveMaintenance: Bool = true
    ) {
        self.init(
            defaults: defaults,
            environment: environment,
            compositionOverrides: AppModelCompositionOverrides(
                recoveryStore: recoveryStore,
                videoRecoveryStore: videoRecoveryStore ?? VideoRecoveryStore(
                    rootURL: FileManager.default.temporaryDirectory
                        .appendingPathComponent("SnipSnipSnipVideoRecoveryTests-\(UUID().uuidString)", isDirectory: true)
                ),
                clipboardHistoryStore: clipboardHistoryStore,
                captureService: captureService,
                screenRecordingService: screenRecordingService,
                uiMapCaptureService: uiMapCaptureService,
                connectedDeviceCaptureService: connectedDeviceCaptureService,
                incompatibleDocumentCoordinator: incompatibleDocumentCoordinator,
                launchAtLoginController: launchAtLoginController
            ),
            shouldCheckCompatibilityOnLaunch: shouldCheckCompatibilityOnLaunch,
            shouldStartArchiveMaintenance: shouldStartArchiveMaintenance
        )
    }

    var editableRedactionSaveConfirmationHandler: @MainActor () -> EditableRedactionSaveDecision {
        get { documents.editableRedactionSaveConfirmationHandler }
        set { documents.editableRedactionSaveConfirmationHandler = newValue }
    }

    var editorController: EditorController? {
        get { documents.editorController }
        set {
            documents.editorController = newValue
            documents.configureEditorObservers()
        }
    }

    var videoEditorController: VideoEditorController? {
        get { documents.videoEditorController }
        set {
            documents.videoEditorController = newValue
            documents.configureVideoEditorObservers()
        }
    }

    var selectedSettingsTab: AppSettingsTab {
        get { lifecycle.selectedSettingsTab }
        set { lifecycle.selectedSettingsTab = newValue }
    }

    var confirmsBeforeQuitting: Bool {
        get { lifecycle.confirmsBeforeQuitting }
        set { lifecycle.confirmsBeforeQuitting = newValue }
    }

    var onboardingPresentationRequest: Int {
        get { lifecycle.onboardingPresentationRequest }
        set { lifecycle.onboardingPresentationRequest = newValue }
    }

    var mainWindowPresentationRequest: Int {
        get { lifecycle.mainWindowPresentationRequest }
        set { lifecycle.mainWindowPresentationRequest = newValue }
    }

    var errorMessage: String? {
        get { lifecycle.errorMessage }
        set { lifecycle.errorMessage = newValue }
    }

    var workingMessage: String {
        get { lifecycle.workingMessage }
        set { lifecycle.workingMessage = newValue }
    }

    var isCheckingProUpdates: Bool {
        get { lifecycle.isCheckingProUpdates }
        set { lifecycle.isCheckingProUpdates = newValue }
    }

    func consumeOnboardingWindowPresentationFlag() -> Bool {
        lifecycle.consumeOnboardingWindowPresentationFlag()
    }

    func consumeMainWindowPresentationFlag() -> Bool {
        lifecycle.consumeMainWindowPresentationFlag()
    }

    func completeOnboarding() {
        lifecycle.completeOnboarding(
            requestMainWindowPresentation: workflowCoordinator.requestMainWindowPresentation
        )
    }

    func skipOnboarding() {
        lifecycle.skipOnboarding(
            requestMainWindowPresentation: workflowCoordinator.requestMainWindowPresentation
        )
    }

    func handleGlobalHotKeyAction(_ action: GlobalHotKeyAction) {
        workflowCoordinator.handleGlobalHotKeyAction(action)
    }

    var canResetPreferencesToDefaults: Bool {
        workflowCoordinator.canResetPreferencesToDefaults
    }

    func resetPreferencesToDefaults() {
        workflowCoordinator.resetPreferencesToDefaults()
    }

    var isShowingWindowPicker: Bool {
        get { capture.isShowingWindowPicker }
        set { capture.isShowingWindowPicker = newValue }
    }

    var autoCopyEnabled: Bool {
        get { clipboard.autoCopyEnabled }
        set { clipboard.autoCopyEnabled = newValue }
    }

    var autoRefreshWindowsEnabled: Bool {
        get { capture.autoRefreshWindowsEnabled }
        set { capture.autoRefreshWindowsEnabled = newValue }
    }

    var captureDelay: CaptureDelay {
        get { capture.captureDelay }
        set { capture.captureDelay = newValue }
    }

    var capturePresets: [CapturePreset] {
        get { capture.capturePresets }
        set { capture.capturePresets = newValue }
    }

    var screenshotIncludesCursor: Bool {
        get { capture.screenshotIncludesCursor }
        set { capture.screenshotIncludesCursor = newValue }
    }

    var screenshotFullscreenDisplayMode: ScreenshotFullscreenDisplayMode {
        get { capture.screenshotFullscreenDisplayMode }
        set { capture.screenshotFullscreenDisplayMode = newValue }
    }

    var selectedScreenshotFullscreenDisplayID: CGDirectDisplayID? {
        get { capture.selectedScreenshotFullscreenDisplayID }
        set { capture.selectedScreenshotFullscreenDisplayID = newValue }
    }

    var screenshotJPEGQuality: CGFloat {
        get { capture.screenshotJPEGQuality }
        set { capture.screenshotJPEGQuality = newValue }
    }

    var regionCapturePreferences: RegionCapturePreferences {
        get { capture.regionCapturePreferences }
        set { capture.regionCapturePreferences = newValue }
    }

    var screenshotFilenameTemplate: String {
        get { capture.screenshotFilenameTemplate }
        set { capture.screenshotFilenameTemplate = newValue }
    }

    var screenshotDragOutFormat: ImageExportFormat {
        get { capture.screenshotDragOutFormat }
        set { capture.screenshotDragOutFormat = newValue }
    }

    var privateCaptureEnabled: Bool {
        get { capture.privateCaptureEnabled }
        set { capture.privateCaptureEnabled = newValue }
    }

    var uiMapEnabled: Bool {
        get { capture.uiMapEnabled }
        set { capture.uiMapEnabled = newValue }
    }

    var automationPreferences: CaptureAutomationPreferences {
        get { capture.automationPreferences }
        set { capture.automationPreferences = newValue }
    }

    var isShowingCapturePresetNamingSheet: Bool {
        get { capture.isShowingCapturePresetNamingSheet }
        set { capture.isShowingCapturePresetNamingSheet = newValue }
    }

    var capturePresetNameDraft: String {
        get { capture.capturePresetNameDraft }
        set { capture.capturePresetNameDraft = newValue }
    }

    var availableWindows: [CaptureWindowSummary] {
        get { capture.availableWindows }
        set { capture.availableWindows = newValue }
    }

    var windowThumbnailRefreshGeneration: Int {
        get { capture.windowThumbnailRefreshGeneration }
        set { capture.windowThumbnailRefreshGeneration = newValue }
    }

    var isLoadingWindowChoices: Bool {
        get { capture.isLoadingWindowChoices }
        set { capture.isLoadingWindowChoices = newValue }
    }

    var isWorking: Bool {
        get { capture.isWorking }
        set { capture.isWorking = newValue }
    }

    var isCapturePrivacyLocked: Bool {
        get { capture.isCapturePrivacyLocked }
        set { capture.isCapturePrivacyLocked = newValue }
    }

    var isConnectedDeviceSessionActive: Bool {
        get { capture.isConnectedDeviceSessionActive }
        set { capture.isConnectedDeviceSessionActive = newValue }
    }

    var windowPickerMode: WindowPickerMode {
        get { capture.windowPickerMode }
        set { capture.windowPickerMode = newValue }
    }

    var connectedDevices: [ConnectedAppleDevice] {
        get { capture.connectedDevices }
        set { capture.connectedDevices = newValue }
    }

    var isLoadingConnectedDevices: Bool {
        get { capture.isLoadingConnectedDevices }
        set { capture.isLoadingConnectedDevices = newValue }
    }

    var connectedDeviceEmptyStateMessage: String {
        get { capture.connectedDeviceEmptyStateMessage }
        set { capture.connectedDeviceEmptyStateMessage = newValue }
    }

    var permissionStatus: CapturePermissionStatus {
        get { permissions.permissionStatus }
        set { permissions.permissionStatus = newValue }
    }

    var permissionSetupGuide: PermissionSetupGuide? {
        get { permissions.permissionSetupGuide }
        set { permissions.permissionSetupGuide = newValue }
    }

    var currentDocumentURL: URL? {
        get { documents.currentDocumentURL }
        set { documents.currentDocumentURL = newValue }
    }

    var hasUnsavedChanges: Bool {
        get { documents.hasUnsavedChanges }
        set { documents.hasUnsavedChanges = newValue }
    }

    var captureSearchQuery: String {
        get { documents.captureSearchQuery }
        set {
            documents.captureSearchQuery = newValue
            documents.scheduleIndexedCaptureHistorySearch()
        }
    }

    var allCaptureHistoryEntries: [DocumentHistoryEntry] {
        get { documents.allCaptureHistoryEntries }
        set { documents.allCaptureHistoryEntries = newValue }
    }

    var historyEntries: [DocumentHistoryEntry] {
        get { documents.historyEntries }
        set { documents.historyEntries = newValue }
    }

    var recentSnipEntries: [DocumentHistoryEntry] {
        get { documents.recentSnipEntries }
        set { documents.recentSnipEntries = newValue }
    }

    var recycleBinEntries: [DocumentHistoryEntry] {
        get { documents.recycleBinEntries }
        set { documents.recycleBinEntries = newValue }
    }

    var pendingRecoverySession: PendingRecoverySession? {
        get { documents.pendingRecoverySession }
        set { documents.pendingRecoverySession = newValue }
    }

    var isShowingUnsavedChangesPrompt: Bool {
        get { documents.isShowingUnsavedChangesPrompt }
        set { documents.isShowingUnsavedChangesPrompt = newValue }
    }

    var editorSingleKeyToolShortcutsEnabled: Bool {
        get { documents.editorSingleKeyToolShortcutsEnabled }
        set { documents.editorSingleKeyToolShortcutsEnabled = newValue }
    }

    var editorStartupToolPreference: EditorStartupToolPreference {
        get { documents.editorStartupToolPreference }
        set { documents.editorStartupToolPreference = newValue }
    }

    var editorCropOutsideOverlayAlpha: CGFloat {
        documents.editorCropOutsideOverlayAlpha
    }

    var editorOutOfCapturePatternSettings: EditorOutOfCapturePatternSettings {
        documents.editorOutOfCapturePatternSettings
    }

    var presentationScenesRootURL: URL {
        documents.presentationScenesRootURL
    }

    var uiMapPinnedOverlayDefaults: UIMapOverlayOptions {
        get { documents.uiMapPinnedOverlayDefaults }
        set { documents.uiMapPinnedOverlayDefaults = newValue }
    }

    var recycleBinRetentionDays: Int {
        get { archive.recycleBinRetentionDays }
        set { archive.recycleBinRetentionDays = newValue }
    }

    var archiveSizeBytes: Int64 {
        get { archive.sizeBytes }
        set { archive.sizeBytes = newValue }
    }

    var screenRulerPreferences: ScreenRulerPreferences {
        get { tools.screenRulerPreferences }
        set { tools.screenRulerPreferences = newValue }
    }

    var screenInspectorPreferences: ScreenInspectorPreferences {
        get { tools.screenInspectorPreferences }
        set { tools.screenInspectorPreferences = newValue }
    }

    var captureService: any ScreenCaptureServiceType {
        get { capture.captureService }
        set { capture.captureService = newValue }
    }

    var uiMapCaptureService: any UIMapCaptureServiceType {
        capture.uiMapCaptureService
    }

    var connectedDeviceCaptureService: any ConnectedDeviceCaptureServiceType {
        capture.connectedDeviceCaptureService
    }

    var screenRecordingService: ScreenRecordingService {
        video.recordingService
    }

    var recoveryStore: DocumentRecoveryStore {
        get { documents.recoveryStore }
        set {
            documents.recoveryStore = newValue
            archive.recoveryStore = newValue
        }
    }

    var clipboardHistoryStore: ClipboardHistoryStore {
        clipboard.historyStore
    }

    var clipboardMonitor: ClipboardMonitor {
        clipboard.monitor
    }

    var lastCaptureRequest: LastCaptureRequest? {
        get { capture.lastCaptureRequest }
        set { capture.lastCaptureRequest = newValue }
    }

    var lastCaptureRunOptions: CaptureRunOptions? {
        get { capture.lastCaptureRunOptions }
        set { capture.lastCaptureRunOptions = newValue }
    }

    var pendingWindowThumbnailTask: Task<Void, Never>? {
        get { capture.pendingWindowThumbnailTask }
        set { capture.pendingWindowThumbnailTask = newValue }
    }

    var pendingScreenRecordingPermissionVerificationTask: Task<Void, Never>? {
        get { permissions.pendingScreenRecordingPermissionVerificationTask }
        set { permissions.pendingScreenRecordingPermissionVerificationTask = newValue }
    }

    var screenRecordingPermissionVerificationGeneration: Int {
        get { permissions.screenRecordingPermissionVerificationGeneration }
        set { permissions.screenRecordingPermissionVerificationGeneration = newValue }
    }

    var pendingCapturePresetDraft: CapturePreset? {
        get { capture.pendingCapturePresetDraft }
        set { capture.pendingCapturePresetDraft = newValue }
    }

    var capturePrivacyLockDepth: Int {
        get { capture.capturePrivacyLockDepth }
        set { capture.capturePrivacyLockDepth = newValue }
    }

    var interactiveCaptureAutosaveSuspensionDepth: Int {
        get { capture.interactiveCaptureAutosaveSuspensionDepth }
        set { capture.interactiveCaptureAutosaveSuspensionDepth = newValue }
    }

    var connectedDevicePreviewController: ConnectedDevicePreviewWindowController? {
        get { capture.connectedDevicePreviewController }
        set { capture.connectedDevicePreviewController = newValue }
    }

    var pendingAutoCopyTask: Task<Void, Never>? {
        get { documents.pendingAutoCopyTask }
        set { documents.pendingAutoCopyTask = newValue }
    }

    var pendingAutosaveTask: Task<Void, Never>? {
        get { documents.pendingAutosaveTask }
        set { documents.pendingAutosaveTask = newValue }
    }

    var pendingRecoveryRefreshTask: Task<Void, Never>? {
        get { documents.pendingRecoveryRefreshTask }
        set { documents.pendingRecoveryRefreshTask = newValue }
    }

    var pendingCaptureHistorySearchTask: Task<Void, Never>? {
        get { documents.pendingCaptureHistorySearchTask }
        set { documents.pendingCaptureHistorySearchTask = newValue }
    }

    var pendingRecoveryWriteTasks: [UUID: Task<Bool, Never>] {
        get { documents.pendingRecoveryWriteTasks }
        set { documents.pendingRecoveryWriteTasks = newValue }
    }

    var recoveryRefreshGeneration: Int {
        get { documents.recoveryRefreshGeneration }
        set { documents.recoveryRefreshGeneration = newValue }
    }

    var captureHistorySearchGeneration: Int {
        get { documents.captureHistorySearchGeneration }
        set { documents.captureHistorySearchGeneration = newValue }
    }

    var currentRecoverySessionID: UUID? {
        get { documents.currentRecoverySessionID }
        set { documents.currentRecoverySessionID = newValue }
    }

    var savedEditorAutosaveState: AutosaveState? {
        get { documents.savedEditorAutosaveState }
        set { documents.savedEditorAutosaveState = newValue }
    }

    var savedDocumentSession: EditorDocumentSession? {
        get { documents.savedDocumentSession }
        set { documents.savedDocumentSession = newValue }
    }

    var savedVideoSession: VideoEditorSession? {
        get { documents.savedVideoSession }
        set { documents.savedVideoSession = newValue }
    }

    var lastAutosavedState: AutosaveState? {
        get { documents.lastAutosavedState }
        set { documents.lastAutosavedState = newValue }
    }

    var activeVideoRecording: ActiveVideoRecording? {
        get { video.activeVideoRecording }
        set { video.activeVideoRecording = newValue }
    }

    var videoStorageMonitorTask: Task<Void, Never>? {
        get { video.videoStorageMonitorTask }
        set { video.videoStorageMonitorTask = newValue }
    }

    var archiveMaintenanceTask: Task<Void, Never>? {
        get { archive.archiveMaintenanceTask }
        set { archive.archiveMaintenanceTask = newValue }
    }

    var configuredArchiveLocationURL: URL? {
        get { archive.configuredArchiveLocationURL }
        set { archive.configuredArchiveLocationURL = newValue }
    }

    var archiveSecurityScopedURL: URL? {
        get { archive.archiveSecurityScopedURL }
        set { archive.archiveSecurityScopedURL = newValue }
    }

    func waitForPendingRecoveryWriteTasks() async {
        let tasks = documents.pendingRecoveryWriteTasks.values
        for task in tasks {
            _ = await task.value
        }
    }
}
