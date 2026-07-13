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
    var pendingCapturePresetDraft: CapturePreset?
    var pendingRecoveryRequest: LastCaptureRequest?
    var pendingScrollingPartialCapture: (result: ScrollingCaptureResult, isPrivateCapture: Bool)?
    var activeWorkflowPresetID: CapturePreset.ID?
    var capturePrivacyLockDepth = 0
    var interactiveCaptureAutosaveSuspensionDepth = 0
    var connectedDevicePreviewController: ConnectedDevicePreviewWindowController?

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
        self.uiMapEnabled = dependencies.preferenceStore.loadUIMapEnabled(defaultEnabled: dependencies.capabilities.isEnabled(.uiMap))
        self.automationPreferences = dependencies.automationPreferenceStore.loadPreferences()
    }
}
