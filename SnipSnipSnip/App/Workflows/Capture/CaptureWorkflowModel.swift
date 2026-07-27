import AppKit
import Combine
import Foundation

@MainActor
struct CaptureWorkflowDependencies {
    let capabilities: AppCapabilitySnapshot
    let systemServices: AppSystemServices
    let appWindowPresenter: any AppWindowPresenting
    let permissions: any PermissionGatekeeping
    let lifecycle: any WorkflowLifecyclePresenting
    let makeScrollingCaptureService: (any ScreenCaptureServiceType) -> ScrollingCaptureService
    let preferenceStore: CapturePreferenceStore
    let automationPreferenceStore: AutomationPreferenceStore
}

@MainActor
final class CaptureWorkflowModel: ObservableObject, AutomationStatusPort, CaptureAutomationPort {
    let dependencies: CaptureWorkflowDependencies
    var captureService: any ScreenCaptureServiceType
    let uiMapCaptureService: any UIMapCaptureServiceType
    let connectedDeviceCaptureService: any ConnectedDeviceCaptureServiceType
    weak var outputSink: (any WorkflowOutputSink)?
    weak var automationCoordinator: (any CaptureAutomationCoordinatorPort)?
    weak var documents: (any CaptureDocumentWorkflowPort)?
    weak var video: (any CaptureVideoWorkflowPort)?
    weak var guide: (any CaptureGuideWorkflowPort)?
    @Published var availableWindows: [CaptureWindowSummary] = []
    @Published var windowThumbnailRefreshGeneration = 0
    @Published var isLoadingWindowChoices = false
    @Published var isWorking = false
    @Published var isCapturePrivacyLocked = false
    @Published var isShowingWindowPicker = false
    @Published var windowPickerMode: WindowPickerMode = .screenshot
    @Published var connectedDevices: [ConnectedAppleDevice] = []
    @Published var isLoadingConnectedDevices = false
    @Published var connectedDeviceEmptyStateMessage = ConnectedDeviceCaptureMenu.emptyStateMessage
    @Published var lastCaptureRequest: LastCaptureRequest?
    @Published var lastCaptureRunOptions: CaptureRunOptions?
    @Published var isConnectedDeviceSessionActive = false
    @Published var autoRefreshWindowsEnabled: Bool {
        didSet {
            dependencies.preferenceStore.saveAutoRefreshWindowsEnabled(autoRefreshWindowsEnabled)
        }
    }
    @Published var captureDelay: CaptureDelay {
        didSet {
            dependencies.preferenceStore.saveCaptureDelay(captureDelay)
        }
    }
    @Published var capturePresets: [CapturePreset] {
        didSet {
            dependencies.preferenceStore.saveCapturePresets(capturePresets)
        }
    }
    @Published var screenshotIncludesCursor: Bool {
        didSet {
            dependencies.preferenceStore.saveScreenshotIncludesCursor(screenshotIncludesCursor)
        }
    }
    @Published var screenshotFullscreenDisplayMode: ScreenshotFullscreenDisplayMode {
        didSet {
            dependencies.preferenceStore.saveFullscreenDisplayMode(screenshotFullscreenDisplayMode)
        }
    }
    @Published var selectedScreenshotFullscreenDisplayID: CGDirectDisplayID? {
        didSet {
            dependencies.preferenceStore.saveSelectedFullscreenDisplayID(selectedScreenshotFullscreenDisplayID)
        }
    }
    @Published var screenshotJPEGQuality: CGFloat {
        didSet {
            let sanitizedQuality = ImageExportOptions.sanitizedJPEGQuality(screenshotJPEGQuality)
            guard sanitizedQuality == screenshotJPEGQuality else {
                screenshotJPEGQuality = sanitizedQuality
                return
            }

            dependencies.preferenceStore.saveScreenshotJPEGQuality(screenshotJPEGQuality)
        }
    }
    @Published var regionCapturePreferences: RegionCapturePreferences {
        didSet {
            dependencies.preferenceStore.saveRegionCapturePreferences(regionCapturePreferences)
        }
    }
    @Published var screenshotFilenameTemplate: String {
        didSet {
            dependencies.preferenceStore.saveScreenshotFilenameTemplate(screenshotFilenameTemplate)
        }
    }
    @Published var screenshotDragOutFormat: ImageExportFormat {
        didSet {
            dependencies.preferenceStore.saveScreenshotDragOutFormat(screenshotDragOutFormat)
        }
    }
    @Published var privateCaptureEnabled: Bool {
        didSet {
            dependencies.preferenceStore.savePrivateCaptureEnabled(privateCaptureEnabled)
        }
    }
    @Published var uiMapEnabled: Bool {
        didSet {
            dependencies.preferenceStore.saveUIMapEnabled(uiMapEnabled)
        }
    }
    @Published var automationPreferences: CaptureAutomationPreferences {
        didSet {
            dependencies.automationPreferenceStore.savePreferences(automationPreferences)
        }
    }
    @Published var isShowingCapturePresetNamingSheet = false
    @Published var capturePresetNameDraft = ""
    @Published var captureRecovery: CaptureRecovery?
    var pendingWindowThumbnailTask: Task<Void, Never>?
    var pendingPermissionCommand: PendingCapturePermissionRequest?
    /// Captured when an operation starts and consumed only by a successful
    /// completion. Permission deferral and recovery deliberately preserve the
    /// destination and its user-facing workflow role as one value.
    var activeCaptureContext = CaptureCompletionContext.standalone
    var pendingCapturePresetDraft: CapturePreset?
    var pendingRecoveryRequest: LastCaptureRequest?
    /// Recovery owns a failed operation's destination independently from the
    /// active slot. This prevents a failed Create capture from leaking its
    /// role/options into an unrelated direct capture while still allowing an
    /// explicit retry to resume the exact operation.
    var pendingRecoveryCaptureContext: CaptureCompletionContext?
    var pendingScrollingPartialCapture: (result: ScrollingCaptureResult, isPrivateCapture: Bool)?
    var activeWorkflowPresetID: CapturePreset.ID?
    var capturePrivacyLockDepth = 0
    var interactiveCaptureAutosaveSuspensionDepth = 0
    var connectedDevicePreviewController: ConnectedDevicePreviewWindowController?
    /// Modal window selection owns its destination independently from the
    /// global capture slot so another asynchronous capture cannot retarget it.
    var windowPickerCaptureContext: CaptureCompletionContext?
    /// Screen Inspector is persistent and may coexist with another capture.
    /// Its exact goal/destination therefore lives with the surface session.
    var screenInspectorCaptureContext: CaptureCompletionContext?

    init(
        dependencies: CaptureWorkflowDependencies,
        captureService: any ScreenCaptureServiceType,
        uiMapCaptureService: any UIMapCaptureServiceType,
        connectedDeviceCaptureService: any ConnectedDeviceCaptureServiceType
    ) {
        self.dependencies = dependencies
        self.captureService = captureService
        self.uiMapCaptureService = uiMapCaptureService
        self.connectedDeviceCaptureService = connectedDeviceCaptureService
        self.autoRefreshWindowsEnabled = dependencies.preferenceStore.loadAutoRefreshWindowsEnabled()
        self.captureDelay = dependencies.preferenceStore.loadCaptureDelay()
        self.capturePresets = dependencies.preferenceStore.loadCapturePresets()
        self.screenshotIncludesCursor = dependencies.preferenceStore.loadScreenshotIncludesCursor()
        self.screenshotFullscreenDisplayMode = dependencies.preferenceStore.loadFullscreenDisplayMode()
        self.selectedScreenshotFullscreenDisplayID = dependencies.preferenceStore.loadSelectedFullscreenDisplayID()
        self.screenshotJPEGQuality = dependencies.preferenceStore.loadScreenshotJPEGQuality()
        self.regionCapturePreferences = dependencies.preferenceStore.loadRegionCapturePreferences()
        self.screenshotFilenameTemplate = dependencies.preferenceStore.loadScreenshotFilenameTemplate()
        self.screenshotDragOutFormat = dependencies.preferenceStore.loadScreenshotDragOutFormat()
        self.privateCaptureEnabled = dependencies.preferenceStore.loadPrivateCaptureEnabled()
        self.uiMapEnabled = dependencies.preferenceStore.loadUIMapEnabled(defaultEnabled: false)
        self.automationPreferences = dependencies.automationPreferenceStore.loadPreferences()
    }
}
