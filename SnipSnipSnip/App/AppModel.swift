import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

enum LastCaptureRequest {
    case region(CGRect)
    case scrolling(CGRect)
    case window(CaptureWindowSummary)
    case frontmostWindow
    case fullscreen
    case connectedDevice(ConnectedAppleDevice)
}

enum WindowPickerMode {
    case screenshot
    case videoRecording
}

struct PermissionSetupGuide: Identifiable {
    let id = UUID()
    let requirement: CapturePermissionRequirement
    let appName: String
    let appPath: String
}

struct InteractiveCaptureAutosaveSuspension {
    let editorControllerID: ObjectIdentifier?
}

struct PendingPermissionAction {
    let requirements: [CapturePermissionRequirement]
    let action: @MainActor () -> Void
}

enum AppModelPreferenceKey {
    static let autoCopyEnabled = "appModel.autoCopyEnabled"
    static let autoRefreshWindowsEnabled = "appModel.autoRefreshWindowsEnabled"
    static let archiveLocationBookmarkData = "appModel.archiveLocationBookmarkData"
    static let archiveLocationPath = "appModel.archiveLocationPath"
    static let archiveMaximumSizeMB = "appModel.archiveMaximumSizeMB"
    static let captureAutomationPreferences = "appModel.captureAutomationPreferences"
    static let captureDelay = "appModel.captureDelay"
    static let clipboardPreferences = "appModel.clipboardPreferences"
    static let screenshotIncludesCursor = "appModel.screenshotIncludesCursor"
    static let completedOnboardingVersion = "appModel.completedOnboardingVersion"
    static let editorCropOutsideOverlayAlpha = "appModel.editorCropOutsideOverlayAlpha"
    static let editorOutOfCapturePatternSettings = "appModel.editorOutOfCapturePatternSettings"
    static let hasDismissedWelcomeCard = "appModel.hasDismissedWelcomeCard"
    static let hasPresentedWelcomeWindow = "appModel.hasPresentedWelcomeWindow"
    static let regionCaptureOverlayMode = "appModel.regionCaptureOverlayMode"
    static let regionCaptureShowsActionControls = "appModel.regionCaptureShowsActionControls"
    static let recycleBinRetentionDays = "appModel.recycleBinRetentionDays"
    static let screenInspectorPreferences = "appModel.screenInspectorPreferences"
    static let screenRulerPreferences = "appModel.screenRulerPreferences"
    static let screenshotFilenameTemplate = "appModel.screenshotFilenameTemplate"
    static let screenshotDragOutFormat = "appModel.screenshotDragOutFormat"
    static let privateCaptureEnabled = "appModel.privateCaptureEnabled"
    static let videoExportPreferences = "appModel.videoExportPreferences"
    static let videoRecordingPreferences = "appModel.videoRecordingPreferences"
}

struct EditorOutOfCapturePatternSettings: Codable, Equatable {
    static let `default` = EditorOutOfCapturePatternSettings(
        isEnabled: true,
        spacing: 34,
        lineOpacity: 0.10,
        dotOpacity: 0.10,
        dotDiameter: 5
    )

    var isEnabled: Bool
    var spacing: CGFloat
    var lineOpacity: CGFloat
    var dotOpacity: CGFloat
    var dotDiameter: CGFloat

    var spacingDescription: String {
        "\(Int(round(spacing))) px"
    }

    var lineOpacityDescription: String {
        String(format: "%d%%", Int(round(lineOpacity * 100)))
    }

    var dotOpacityDescription: String {
        String(format: "%d%%", Int(round(dotOpacity * 100)))
    }

    var dotDiameterDescription: String {
        "\(Int(round(dotDiameter))) px"
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    static let autoCopyDebounceNanoseconds: UInt64 = 250_000_000
    static let autosaveDebounceNanoseconds: UInt64 = 1_250_000_000
    static let archiveMaintenanceNanoseconds: UInt64 = 300_000_000_000
    static let captureHistoryLimit = 36
    static let captureHistorySearchLimit = 100
    static let currentOnboardingVersion = 1
    static let defaultArchiveMaximumSizeMB = 1_024
    static let defaultEditorCropOutsideOverlayAlpha: CGFloat = 0.80
    static let defaultRecycleBinRetentionDays = 2
    static let minimumArchiveMaximumSizeMB = 100
    static let minimumRecycleBinRetentionDays = 1
    static let recentSnipLimit = 12
    static let recycleBinLimit = 48

    @Published var permissionStatus = CapturePermissionStatus.current()
    @Published var editorController: EditorController? {
        didSet {
            configureEditorObservers()
        }
    }
    @Published var videoEditorController: VideoEditorController? {
        didSet {
            configureVideoEditorObservers()
        }
    }
    @Published var availableWindows: [CaptureWindowSummary] = []
    @Published var windowThumbnailRefreshGeneration = 0
    @Published var isLoadingWindowChoices = false
    @Published var isShowingWindowPicker = false
    @Published var isWorking = false
    @Published var isCapturePrivacyLocked = false
    @Published var isConnectedDeviceSessionActive = false
    @Published var windowPickerMode: WindowPickerMode = .screenshot
    @Published var autoCopyEnabled: Bool {
        didSet {
            defaults.set(autoCopyEnabled, forKey: AppModelPreferenceKey.autoCopyEnabled)

            if autoCopyEnabled {
                copyCurrentEditorImageToClipboard()
            } else {
                pendingAutoCopyTask?.cancel()
                pendingAutoCopyTask = nil
            }
        }
    }
    @Published var autoRefreshWindowsEnabled: Bool {
        didSet {
            defaults.set(autoRefreshWindowsEnabled, forKey: AppModelPreferenceKey.autoRefreshWindowsEnabled)
        }
    }
    @Published var captureDelay: CaptureDelay {
        didSet {
            defaults.set(captureDelay.rawValue, forKey: AppModelPreferenceKey.captureDelay)
        }
    }
    @Published var clipboardPreferences: ClipboardPreferences {
        didSet {
            let sanitizedPreferences = clipboardPreferences.sanitized()
            if sanitizedPreferences != clipboardPreferences {
                clipboardPreferences = sanitizedPreferences
                return
            }

            persistClipboardPreferences()
            clipboardMonitor.update(preferences: clipboardPreferences)
            clipboardHistoryStore.prune(using: clipboardPreferences)
        }
    }
    @Published var clipboardSearchQuery = ""
    @Published var clipboardFilter: ClipboardItemFilter = .all
    @Published var screenshotIncludesCursor: Bool {
        didSet {
            defaults.set(screenshotIncludesCursor, forKey: AppModelPreferenceKey.screenshotIncludesCursor)
        }
    }
    @Published var regionCapturePreferences: RegionCapturePreferences {
        didSet {
            defaults.set(regionCapturePreferences.overlayMode.rawValue, forKey: AppModelPreferenceKey.regionCaptureOverlayMode)
            defaults.set(regionCapturePreferences.showsActionControls, forKey: AppModelPreferenceKey.regionCaptureShowsActionControls)
        }
    }
    @Published var screenshotFilenameTemplate: String {
        didSet {
            defaults.set(screenshotFilenameTemplate, forKey: AppModelPreferenceKey.screenshotFilenameTemplate)
        }
    }
    @Published var screenshotDragOutFormat: ImageExportFormat {
        didSet {
            defaults.set(screenshotDragOutFormat.rawValue, forKey: AppModelPreferenceKey.screenshotDragOutFormat)
        }
    }
    @Published var privateCaptureEnabled: Bool {
        didSet {
            defaults.set(privateCaptureEnabled, forKey: AppModelPreferenceKey.privateCaptureEnabled)
        }
    }
    @Published private(set) var editorCropOutsideOverlayAlpha: CGFloat
    @Published private(set) var editorOutOfCapturePatternSettings: EditorOutOfCapturePatternSettings
    @Published var screenRulerPreferences: ScreenRulerPreferences {
        didSet {
            let sanitizedPreferences = screenRulerPreferences.sanitized()
            if sanitizedPreferences != screenRulerPreferences {
                screenRulerPreferences = sanitizedPreferences
                return
            }

            persistScreenRulerPreferences()
            screenRulerCoordinator.updatePreferences(screenRulerPreferences)
        }
    }
    @Published var screenInspectorPreferences: ScreenInspectorPreferences {
        didSet {
            let sanitizedPreferences = screenInspectorPreferences.sanitized()
            if sanitizedPreferences != screenInspectorPreferences {
                screenInspectorPreferences = sanitizedPreferences
                return
            }

            persistScreenInspectorPreferences()
            screenInspectorCoordinator.updatePreferences(screenInspectorPreferences)
        }
    }
    @Published var automationPreferences: CaptureAutomationPreferences {
        didSet {
            persistAutomationPreferences()
            globalHotKeyCoordinator.setActionKeys(automationPreferences.actionKeys)
            globalHotKeyCoordinator.setEnabled(automationPreferences.globalHotkeysEnabled)
        }
    }
    @Published var videoRecordingPreferences: VideoRecordingPreferences {
        didSet {
            persistVideoRecordingPreferences()
        }
    }
    @Published var videoExportPreferences: VideoExportPreferences {
        didSet {
            persistVideoExportPreferences()
        }
    }
    @Published var archiveMaximumSizeMB: Int {
        didSet {
            defaults.set(archiveMaximumSizeMB, forKey: AppModelPreferenceKey.archiveMaximumSizeMB)
            triggerArchiveMaintenance()
        }
    }
    @Published var recycleBinRetentionDays: Int {
        didSet {
            let sanitizedValue = max(recycleBinRetentionDays, Self.minimumRecycleBinRetentionDays)

            guard sanitizedValue == recycleBinRetentionDays else {
                recycleBinRetentionDays = sanitizedValue
                return
            }

            defaults.set(recycleBinRetentionDays, forKey: AppModelPreferenceKey.recycleBinRetentionDays)
            triggerArchiveMaintenance()
        }
    }
    @Published var archiveSizeBytes: Int64 = 0
    @Published var archiveDirectoryURL: URL
    @Published var onboardingPresentationRequest = 0
    @Published private(set) var showsWelcomeCard: Bool
    @Published var errorMessage: String?
    @Published var mainWindowPresentationRequest = 0
    @Published var currentDocumentURL: URL?
    @Published var hasUnsavedChanges = false
    @Published var captureSearchQuery = "" {
        didSet {
            scheduleIndexedCaptureHistorySearch()
        }
    }
    @Published var allCaptureHistoryEntries: [DocumentHistoryEntry] = []
    @Published var historyEntries: [DocumentHistoryEntry] = []
    @Published var recentSnipEntries: [DocumentHistoryEntry] = []
    @Published var recycleBinEntries: [DocumentHistoryEntry] = []
    @Published var pendingRecoverySession: PendingRecoverySession?
    @Published var workingMessage = "Capturing"
    @Published var isShowingUnsavedChangesPrompt = false
    @Published var permissionSetupGuide: PermissionSetupGuide?
    @Published var connectedDevices: [ConnectedAppleDevice] = []
    @Published var isLoadingConnectedDevices = false
    @Published var connectedDeviceEmptyStateMessage = ConnectedDeviceCaptureMenu.emptyStateMessage

    var captureService: any ScreenCaptureServiceType
    let connectedDeviceCaptureService: any ConnectedDeviceCaptureServiceType
    let screenRecordingService = ScreenRecordingService()
    var recoveryStore: DocumentRecoveryStore
    let incompatibleDocumentCoordinator: IncompatibleDocumentCoordinator
    let launchAtLoginController: LaunchAtLoginController
    let floatingReferenceCoordinator = FloatingReferenceCoordinator()
    let screenRulerCoordinator: ScreenRulerCoordinator
    let screenInspectorCoordinator: ScreenInspectorCoordinator
    let clipboardHistoryStore: ClipboardHistoryStore
    let clipboardMonitor: ClipboardMonitor
    let defaults: UserDefaults
    let textRecognitionCoordinator = CaptureTextRecognitionCoordinator()
    private var shouldPresentOnboardingWindowOnLaunch: Bool
    private var shouldPresentMainWindowOnLaunch: Bool
    private var shouldOpenMainWindowAfterOnboarding = false
    private lazy var globalHotKeyCoordinator = GlobalHotKeyCoordinator { [weak self] action in
        self?.handleGlobalHotKeyAction(action)
    }
    @Published var lastCaptureRequest: LastCaptureRequest?
    var editorRenderObserver: AnyCancellable?
    var editorPersistenceObserver: AnyCancellable?
    var videoPersistenceObserver: AnyCancellable?
    var applicationActivationObserver: AnyCancellable?
    var launchAtLoginObserver: AnyCancellable?
    var pendingAutoCopyTask: Task<Void, Never>?
    var pendingAutosaveTask: Task<Void, Never>?
    var archiveMaintenanceTask: Task<Void, Never>?
    var videoStorageMonitorTask: Task<Void, Never>?
    var pendingWindowThumbnailTask: Task<Void, Never>?
    var pendingScreenRecordingPermissionVerificationTask: Task<Void, Never>?
    var pendingRecoveryRefreshTask: Task<Void, Never>?
    var clipboardManagerWindowController: ClipboardManagerWindowController?
    var clipboardHistoryObserver: AnyCancellable?
    var screenRulerObserver: AnyCancellable?
    var screenInspectorObserver: AnyCancellable?
    var pendingCaptureHistorySearchTask: Task<Void, Never>?
    var pendingRecoveryWriteTasks: [UUID: Task<Void, Never>] = [:]
    var recoveryRefreshGeneration = 0
    var captureHistorySearchGeneration = 0
    var screenRecordingPermissionVerificationGeneration = 0
    var currentRecoverySessionID: UUID?
    var configuredArchiveLocationURL: URL?
    var archiveSecurityScopedURL: URL?
    var savedEditorAutosaveState: AutosaveState?
    var savedDocumentSession: EditorDocumentSession?
    var savedVideoSession: VideoEditorSession?
    var pendingEditorAction: (() -> Void)?
    var pendingPermissionAction: PendingPermissionAction?
    var lastAutosavedState: AutosaveState?
    var capturePrivacyLockDepth = 0
    var interactiveCaptureAutosaveSuspensionDepth = 0
    @Published var activeVideoRecording: ActiveVideoRecording?
    var connectedDevicePreviewController: ConnectedDevicePreviewWindowController?
    let shouldCheckCompatibilityOnLaunch: Bool
    let shouldStartArchiveMaintenance: Bool

    init(
        defaults: UserDefaults = .standard,
        recoveryStore: DocumentRecoveryStore? = nil,
        clipboardHistoryStore: ClipboardHistoryStore? = nil,
        captureService: any ScreenCaptureServiceType = ScreenCaptureService(),
        connectedDeviceCaptureService: any ConnectedDeviceCaptureServiceType = ConnectedDeviceCaptureService(),
        incompatibleDocumentCoordinator: IncompatibleDocumentCoordinator = IncompatibleDocumentCoordinator(),
        launchAtLoginController: LaunchAtLoginController = LaunchAtLoginController(),
        shouldCheckCompatibilityOnLaunch: Bool = !AppModel.isRunningUnitTests,
        shouldStartArchiveMaintenance: Bool = true
    ) {
        self.shouldCheckCompatibilityOnLaunch = shouldCheckCompatibilityOnLaunch
        self.shouldStartArchiveMaintenance = shouldStartArchiveMaintenance
        let configuredArchiveLocationURL = Self.loadArchiveLocationURL(from: defaults)
        let recoveryStore = recoveryStore ?? DocumentRecoveryStore(baseURL: configuredArchiveLocationURL)
        self.defaults = defaults
        self.recoveryStore = recoveryStore
        self.incompatibleDocumentCoordinator = incompatibleDocumentCoordinator
        self.launchAtLoginController = launchAtLoginController
        self.configuredArchiveLocationURL = configuredArchiveLocationURL
        self.captureService = captureService
        self.connectedDeviceCaptureService = connectedDeviceCaptureService
        self.autoCopyEnabled = defaults.object(forKey: AppModelPreferenceKey.autoCopyEnabled) as? Bool ?? true
        self.autoRefreshWindowsEnabled = defaults.bool(forKey: AppModelPreferenceKey.autoRefreshWindowsEnabled)
        self.captureDelay = CaptureDelay(rawValue: defaults.integer(forKey: AppModelPreferenceKey.captureDelay)) ?? .immediate
        let clipboardHistoryStore = clipboardHistoryStore ?? ClipboardHistoryStore()
        self.clipboardHistoryStore = clipboardHistoryStore
        self.clipboardMonitor = ClipboardMonitor(store: clipboardHistoryStore)
        self.clipboardPreferences = Self.loadClipboardPreferences(from: defaults)
        self.screenshotIncludesCursor = defaults.object(forKey: AppModelPreferenceKey.screenshotIncludesCursor) as? Bool ?? false
        self.regionCapturePreferences = RegionCapturePreferences(
            overlayMode: (defaults.object(forKey: AppModelPreferenceKey.regionCaptureOverlayMode) as? Int)
                .flatMap(RegionCaptureOverlayMode.init(rawValue:)) ?? .crosshairAndMagnifyingGlass,
            showsActionControls: defaults.object(forKey: AppModelPreferenceKey.regionCaptureShowsActionControls) as? Bool ?? false
        )
        self.screenshotFilenameTemplate = defaults.string(forKey: AppModelPreferenceKey.screenshotFilenameTemplate) ?? ScreenshotFilenameTemplate.defaultPattern
        self.screenshotDragOutFormat = defaults.string(forKey: AppModelPreferenceKey.screenshotDragOutFormat)
            .flatMap(ImageExportFormat.init(rawValue:)) ?? .png
        self.privateCaptureEnabled = defaults.object(forKey: AppModelPreferenceKey.privateCaptureEnabled) as? Bool ?? false
        self.editorCropOutsideOverlayAlpha = Self.loadEditorCropOutsideOverlayAlpha(from: defaults)
        self.editorOutOfCapturePatternSettings = Self.loadEditorOutOfCapturePatternSettings(from: defaults)
        let screenRulerPreferences = Self.loadScreenRulerPreferences(from: defaults)
        self.screenRulerPreferences = screenRulerPreferences
        self.screenRulerCoordinator = ScreenRulerCoordinator(preferences: screenRulerPreferences)
        let screenInspectorPreferences = Self.loadScreenInspectorPreferences(from: defaults)
        self.screenInspectorPreferences = screenInspectorPreferences
        self.screenInspectorCoordinator = ScreenInspectorCoordinator(preferences: screenInspectorPreferences)
        self.automationPreferences = Self.loadAutomationPreferences(from: defaults)
        self.videoRecordingPreferences = Self.loadVideoRecordingPreferences(from: defaults)
        self.videoExportPreferences = Self.loadVideoExportPreferences(from: defaults)
        self.archiveMaximumSizeMB = Self.loadArchiveMaximumSizeMB(from: defaults)
        self.recycleBinRetentionDays = Self.loadRecycleBinRetentionDays(from: defaults)
        self.archiveDirectoryURL = recoveryStore.archiveURL
        self.showsWelcomeCard = false
        let pendingRecoverySession = recoveryStore.latestPendingRecovery()
        self.pendingRecoverySession = pendingRecoverySession
        self.allCaptureHistoryEntries = recoveryStore.allHistoryEntries(limit: Self.captureHistoryLimit)
        self.recentSnipEntries = recoveryStore.pendingRecoveryEntries(limit: Self.recentSnipLimit)
        self.recycleBinEntries = recoveryStore.recycledHistoryEntries(limit: Self.recycleBinLimit)
        let completedOnboardingVersion = Self.loadCompletedOnboardingVersion(from: defaults)
        self.shouldPresentOnboardingWindowOnLaunch = completedOnboardingVersion < Self.currentOnboardingVersion
        self.shouldPresentMainWindowOnLaunch = pendingRecoverySession != nil
        globalHotKeyCoordinator.setActionKeys(self.automationPreferences.actionKeys)
        globalHotKeyCoordinator.setEnabled(self.automationPreferences.globalHotkeysEnabled)
        activateArchiveDirectoryAccess(configuredArchiveLocationURL)
        try? PackageTemporaryDirectoryJanitor.cleanupStalePackageTemporaryDirectories()

        if shouldCheckCompatibilityOnLaunch {
            handleIncompatibleRecoveryEntriesOnLaunch()
        }

        applicationActivationObserver = NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )
        .sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleApplicationDidBecomeActive()
            }
        }

        launchAtLoginObserver = launchAtLoginController.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        clipboardHistoryObserver = clipboardHistoryStore.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        screenRulerObserver = screenRulerCoordinator.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        screenInspectorObserver = screenInspectorCoordinator.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        if shouldStartArchiveMaintenance {
            self.startArchiveMaintenance()
        }

        if FeatureFlags.connectedDeviceCaptureEnabled, !Self.isRunningUnitTests {
            refreshConnectedDevices()
        }
        clipboardMonitor.start(preferences: clipboardPreferences)
        screenInspectorCoordinator.setPreferencesChangeHandler { [weak self] preferences in
            guard let self, self.screenInspectorPreferences != preferences else {
                return
            }

            self.screenInspectorPreferences = preferences
        }
        screenInspectorCoordinator.setSnipHandler { [weak self] sample in
            self?.completeScreenInspectorSnip(sample)
        }
    }

    nonisolated deinit {}

    func waitForPendingRecoveryWriteTasks() async {
        let tasks = pendingRecoveryWriteTasks.values
        for task in tasks {
            await task.value
        }
    }

    var canRepeatLastCapture: Bool {
        guard let lastCaptureRequest else {
            return false
        }

        if case .scrolling = lastCaptureRequest {
            return FeatureFlags.scrollingCaptureEnabled
        }

        if case .connectedDevice = lastCaptureRequest {
            return FeatureFlags.connectedDeviceCaptureEnabled
        }

        return true
    }

    var canOpenDocument: Bool {
        !isWorking && activeVideoRecording == nil && !isConnectedDeviceSessionActive
    }

    var canChangePrivateCapture: Bool {
        !isCapturePrivacyLocked && !isWorking && !isShowingWindowPicker && activeVideoRecording == nil && !isConnectedDeviceSessionActive
    }

    var canResetPreferencesToDefaults: Bool {
        !isWorking && !isShowingWindowPicker && activeVideoRecording == nil && !isConnectedDeviceSessionActive
    }

    var isInteractiveCaptureActive: Bool {
        interactiveCaptureAutosaveSuspensionDepth > 0
    }

    var canSaveDocument: Bool {
        (editorController != nil || videoEditorController != nil) && !isWorking && activeVideoRecording == nil
    }

    var defaultVideoExportRequest: VideoExportRequest {
        VideoExportRequest(
            format: .mp4,
            target: videoExportPreferences.target
        )
    }

    var currentDocumentFilename: String {
        if let currentDocumentURL {
            return currentDocumentURL.lastPathComponent
        }

        if let controller = editorController {
            return ScreenshotFilenameTemplate(pattern: screenshotFilenameTemplate).resolvedFilename(for: controller.capture, formatExtension: "sss") + ".sss"
        }

        if let controller = videoEditorController {
            return controller.recording.defaultFilename + ".sssvideo"
        }

        return "Untitled.sss"
    }

    var editorCropOutsideOverlayDimmingDescription: String {
        String(format: "%d%% dimming", Int(round(editorCropOutsideOverlayAlpha * 100)))
    }

    var launchAtLoginStatus: LaunchAtLoginStatus {
        launchAtLoginController.status
    }

    var isRecordingVideo: Bool {
        activeVideoRecording != nil
    }

    func consumeOnboardingWindowPresentationFlag() -> Bool {
        guard shouldPresentOnboardingWindowOnLaunch else {
            return false
        }

        shouldPresentOnboardingWindowOnLaunch = false
        shouldOpenMainWindowAfterOnboarding = true
        return true
    }

    func consumeMainWindowPresentationFlag() -> Bool {
        guard shouldPresentMainWindowOnLaunch else {
            return false
        }

        shouldPresentMainWindowOnLaunch = false
        return true
    }

    func requestOnboardingPresentation() {
        shouldOpenMainWindowAfterOnboarding = false
        promoteToRegularApp()
        onboardingPresentationRequest += 1
    }

    func completeOnboarding() {
        defaults.set(Self.currentOnboardingVersion, forKey: AppModelPreferenceKey.completedOnboardingVersion)

        if shouldOpenMainWindowAfterOnboarding {
            requestMainWindowPresentation()
        }

        shouldOpenMainWindowAfterOnboarding = false
    }

    func skipOnboarding() {
        completeOnboarding()
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginController.refreshStatus()
    }

    @discardableResult
    func updateLaunchAtLoginEnabled(_ isEnabled: Bool) -> LaunchAtLoginActionResult {
        launchAtLoginController.setEnabled(isEnabled)
    }

    func openLaunchAtLoginSettings() {
        launchAtLoginController.openSystemSettings()
    }

    func dismissWelcomeCard() {
        guard showsWelcomeCard else {
            return
        }

        showsWelcomeCard = false
        defaults.set(true, forKey: AppModelPreferenceKey.hasDismissedWelcomeCard)
    }

    func resetPreferencesToDefaults() {
        guard canResetPreferencesToDefaults else {
            return
        }

        autoCopyEnabled = true
        autoRefreshWindowsEnabled = false
        captureDelay = .immediate
        clipboardPreferences = .default
        clipboardSearchQuery = ""
        clipboardFilter = .all
        screenshotIncludesCursor = false
        regionCapturePreferences = RegionCapturePreferences()
        screenshotFilenameTemplate = ScreenshotFilenameTemplate.defaultPattern
        screenshotDragOutFormat = .png
        privateCaptureEnabled = false
        updateEditorCropOutsideOverlayAlpha(Self.defaultEditorCropOutsideOverlayAlpha)
        updateEditorOutOfCapturePatternSettings(.default)
        screenRulerPreferences = .default
        screenInspectorPreferences = .default
        automationPreferences = CaptureAutomationPreferences()
        videoRecordingPreferences = VideoRecordingPreferences()
        videoExportPreferences = VideoExportPreferences()
        archiveMaximumSizeMB = Self.defaultArchiveMaximumSizeMB
        recycleBinRetentionDays = Self.defaultRecycleBinRetentionDays

        if !usesDefaultArchiveLocation {
            resetArchiveLocationToDefault()
        }
    }

    private static func loadAutomationPreferences(from defaults: UserDefaults) -> CaptureAutomationPreferences {
        guard let data = defaults.data(forKey: AppModelPreferenceKey.captureAutomationPreferences),
              let preferences = try? JSONDecoder().decode(CaptureAutomationPreferences.self, from: data) else {
            return CaptureAutomationPreferences()
        }

        return preferences
    }

    private static func loadCompletedOnboardingVersion(from defaults: UserDefaults) -> Int {
        if let storedVersion = defaults.object(forKey: AppModelPreferenceKey.completedOnboardingVersion) as? Int {
            return storedVersion
        }

        let hasLegacyWelcomeState = defaults.object(forKey: AppModelPreferenceKey.hasPresentedWelcomeWindow) != nil
            || defaults.object(forKey: AppModelPreferenceKey.hasDismissedWelcomeCard) != nil

        return hasLegacyWelcomeState ? currentOnboardingVersion : 0
    }

    private static func loadEditorCropOutsideOverlayAlpha(from defaults: UserDefaults) -> CGFloat {
        guard let configuredValue = defaults.object(forKey: AppModelPreferenceKey.editorCropOutsideOverlayAlpha) as? Double else {
            return defaultEditorCropOutsideOverlayAlpha
        }

        return clampedEditorCropOutsideOverlayAlpha(CGFloat(configuredValue))
    }

    private static func loadEditorOutOfCapturePatternSettings(from defaults: UserDefaults) -> EditorOutOfCapturePatternSettings {
        guard let data = defaults.data(forKey: AppModelPreferenceKey.editorOutOfCapturePatternSettings),
              let settings = try? JSONDecoder().decode(EditorOutOfCapturePatternSettings.self, from: data) else {
            return .default
        }

        return sanitizedEditorOutOfCapturePatternSettings(settings)
    }

    static func loadScreenRulerPreferences(from defaults: UserDefaults) -> ScreenRulerPreferences {
        guard let data = defaults.data(forKey: AppModelPreferenceKey.screenRulerPreferences),
              let preferences = try? JSONDecoder().decode(ScreenRulerPreferences.self, from: data) else {
            return .default
        }

        return preferences.sanitized()
    }

    static func loadScreenInspectorPreferences(from defaults: UserDefaults) -> ScreenInspectorPreferences {
        guard let data = defaults.data(forKey: AppModelPreferenceKey.screenInspectorPreferences),
              let preferences = try? JSONDecoder().decode(ScreenInspectorPreferences.self, from: data) else {
            return .default
        }

        return preferences.sanitized()
    }

    private static func clampedEditorCropOutsideOverlayAlpha(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 0.9)
    }

    private static func sanitizedEditorOutOfCapturePatternSettings(_ settings: EditorOutOfCapturePatternSettings) -> EditorOutOfCapturePatternSettings {
        EditorOutOfCapturePatternSettings(
            isEnabled: settings.isEnabled,
            spacing: min(max(settings.spacing, 16), 96),
            lineOpacity: min(max(settings.lineOpacity, 0.05), 0.9),
            dotOpacity: min(max(settings.dotOpacity, 0.05), 1),
            dotDiameter: min(max(settings.dotDiameter, 2), 12)
        )
    }

    func updateEditorCropOutsideOverlayAlpha(_ value: CGFloat) {
        let clampedAlpha = Self.clampedEditorCropOutsideOverlayAlpha(value)

        guard editorCropOutsideOverlayAlpha != clampedAlpha else {
            return
        }

        editorCropOutsideOverlayAlpha = clampedAlpha
        defaults.set(Double(clampedAlpha), forKey: AppModelPreferenceKey.editorCropOutsideOverlayAlpha)
        editorController?.updateCropOutsideOverlayAlpha(clampedAlpha)
    }

    func updateEditorOutOfCapturePatternSettings(_ settings: EditorOutOfCapturePatternSettings) {
        let sanitizedSettings = Self.sanitizedEditorOutOfCapturePatternSettings(settings)

        guard editorOutOfCapturePatternSettings != sanitizedSettings else {
            return
        }

        editorOutOfCapturePatternSettings = sanitizedSettings

        if let data = try? JSONEncoder().encode(sanitizedSettings) {
            defaults.set(data, forKey: AppModelPreferenceKey.editorOutOfCapturePatternSettings)
        }

        editorController?.updateOutOfCapturePatternSettings(sanitizedSettings)
    }

    func presentScreenRuler(_ kind: ScreenRulerKind) {
        screenRulerCoordinator.present(kind)
    }

    func closeAllScreenRulers() {
        screenRulerCoordinator.closeAll()
    }

    func presentScreenInspector() {
        screenInspectorCoordinator.present()
    }

    func toggleScreenInspector() {
        screenInspectorCoordinator.toggle()
    }

    func closeScreenInspector() {
        screenInspectorCoordinator.close()
    }

    private func persistScreenRulerPreferences() {
        guard let data = try? JSONEncoder().encode(screenRulerPreferences.sanitized()) else {
            return
        }

        defaults.set(data, forKey: AppModelPreferenceKey.screenRulerPreferences)
    }

    private func persistScreenInspectorPreferences() {
        guard let data = try? JSONEncoder().encode(screenInspectorPreferences.sanitized()) else {
            return
        }

        defaults.set(data, forKey: AppModelPreferenceKey.screenInspectorPreferences)
    }

    private func persistAutomationPreferences() {
        guard let data = try? JSONEncoder().encode(automationPreferences) else {
            return
        }

        defaults.set(data, forKey: AppModelPreferenceKey.captureAutomationPreferences)
    }

    private static func loadVideoRecordingPreferences(from defaults: UserDefaults) -> VideoRecordingPreferences {
        guard let data = defaults.data(forKey: AppModelPreferenceKey.videoRecordingPreferences),
              let preferences = try? JSONDecoder().decode(VideoRecordingPreferences.self, from: data) else {
            return VideoRecordingPreferences()
        }

        return preferences
    }

    private func persistVideoRecordingPreferences() {
        guard let data = try? JSONEncoder().encode(videoRecordingPreferences) else {
            return
        }

        defaults.set(data, forKey: AppModelPreferenceKey.videoRecordingPreferences)
    }

    private static func loadVideoExportPreferences(from defaults: UserDefaults) -> VideoExportPreferences {
        guard let data = defaults.data(forKey: AppModelPreferenceKey.videoExportPreferences),
              let preferences = try? JSONDecoder().decode(VideoExportPreferences.self, from: data) else {
            return VideoExportPreferences()
        }

        return preferences.target.supports(.mp4)
            ? VideoExportPreferences(format: .mp4, target: preferences.target)
            : VideoExportPreferences()
    }

    private func persistVideoExportPreferences() {
        guard let data = try? JSONEncoder().encode(videoExportPreferences) else {
            return
        }

        defaults.set(data, forKey: AppModelPreferenceKey.videoExportPreferences)
    }

    private static func loadRecycleBinRetentionDays(from defaults: UserDefaults) -> Int {
        let configuredDays = defaults.object(forKey: AppModelPreferenceKey.recycleBinRetentionDays) as? Int
            ?? defaults.integer(forKey: AppModelPreferenceKey.recycleBinRetentionDays)

        guard configuredDays > 0 else {
            return defaultRecycleBinRetentionDays
        }

        return max(configuredDays, minimumRecycleBinRetentionDays)
    }
}
