import AppKit
import Combine
import Foundation
@MainActor
struct DocumentWorkflowDependencies {
    let capabilities: AppCapabilitySnapshot
    let systemServices: AppSystemServices
    let lifecycle: any WorkflowLifecyclePresenting
    let capture: any DocumentCaptureWorkflowPort
    let clipboard: any DocumentClipboardWorkflowPort
    let video: any DocumentVideoWorkflowPort
    let archive: any DocumentArchiveWorkflowPort
    let panels: any DocumentPanelPresenting
    let windowPresenter: any DocumentWindowPresenting
    let pasteboardImporter: any DocumentPasteboardImporting
    let floatingReferenceCoordinator: FloatingReferenceCoordinator
    let historyPreviewCoordinator: HistoryPreviewCoordinator
    let textRecognitionCoordinator: CaptureTextRecognitionCoordinator
}
@MainActor
struct LibrarySwitchSnapshot {
    let controller: EditorController
    let documentURL: URL?
    let savedSession: EditorDocumentSession?
    let recoverySessionID: UUID?
}

@MainActor
final class DocumentWorkflowModel: ObservableObject, DocumentAutomationPort {
    var recoveryStore: DocumentRecoveryStore
    let incompatibleDocumentCoordinator: IncompatibleDocumentCoordinator
    let dependencies: DocumentWorkflowDependencies
    lazy var snipLibraryCoordinator = SnipLibraryCoordinator(
        files: dependencies.systemServices.files
    )
    weak var automationCoordinator: (any DocumentAutomationCoordinatorPort)?
    let preferenceStore: EditorPreferenceStore
    @Published var editorController: EditorController? {
        didSet {
            applyEditorPreferences(to: editorController)
            isEditorDocumentOutputAvailable =
                editorController?.isDocumentOutputAvailable == true
        }
    }
    @Published private(set) var isEditorDocumentOutputAvailable = false
    @Published var videoEditorController: VideoEditorController?
    @Published var guideEditorController: GuideEditorController?
    @Published var currentDocumentURL: URL?
    @Published var hasUnsavedChanges = false
    @Published var guideExportIsActive = false
    @Published var guideExportProgress: Double?
    @Published var guideExportStatus: String?
    @Published var guideExportCurrentFormat: GuideExportFormat?
    @Published var guideExportCancellationRequested = false
    @Published var lastGuideExportURLs: [URL] = []
    @Published var compositionExportProgressState:
        CompositionExportProgressState?
    @Published var captureSearchQuery = ""
    @Published var allCaptureHistoryEntries: [DocumentHistoryEntry]
    @Published var snipLibraryEntries: [DocumentHistoryEntry]
    @Published var historyEntries: [DocumentHistoryEntry] = []
    @Published var recentSnipEntries: [DocumentHistoryEntry]
    @Published var recycleBinEntries: [DocumentHistoryEntry]
    @Published var pendingRecoverySession: PendingRecoverySession?
    @Published var videoRecoveryState: VideoRecoveryWorkflowState
    @Published var pendingCompositionImportRecovery:
        CompositionImportRecoveryState?
    @Published var isShowingUnsavedChangesPrompt = false
    @Published var editorSingleKeyToolShortcutsEnabled: Bool {
        didSet {
            preferenceStore.saveSingleKeyToolShortcutsEnabled(editorSingleKeyToolShortcutsEnabled)
            editorController?.editorSingleKeyToolShortcutsEnabled = editorSingleKeyToolShortcutsEnabled
        }
    }
    @Published var editorStartupToolPreference: EditorStartupToolPreference {
        didSet {
            let sanitizedPreference = editorStartupToolPreference.sanitized
            guard sanitizedPreference == editorStartupToolPreference else {
                editorStartupToolPreference = sanitizedPreference
                return
            }
            preferenceStore.saveStartupToolPreference(editorStartupToolPreference)
            applyStartupToolPreference(to: editorController)
        }
    }
    @Published var editorCropOutsideOverlayAlpha: CGFloat {
        didSet {
            let clampedAlpha = EditorPreferenceStore.clampedCropOutsideOverlayAlpha(editorCropOutsideOverlayAlpha)
            guard clampedAlpha == editorCropOutsideOverlayAlpha else {
                editorCropOutsideOverlayAlpha = clampedAlpha
                return
            }
            preferenceStore.saveCropOutsideOverlayAlpha(editorCropOutsideOverlayAlpha)
            editorController?.updateCropOutsideOverlayAlpha(editorCropOutsideOverlayAlpha)
        }
    }
    @Published var editorOutOfCapturePatternSettings: EditorOutOfCapturePatternSettings {
        didSet {
            let sanitizedSettings = editorOutOfCapturePatternSettings.sanitized()
            guard sanitizedSettings == editorOutOfCapturePatternSettings else {
                editorOutOfCapturePatternSettings = sanitizedSettings
                return
            }
            preferenceStore.saveOutOfCapturePatternSettings(editorOutOfCapturePatternSettings)
            editorController?.updateOutOfCapturePatternSettings(editorOutOfCapturePatternSettings)
        }
    }
    @Published var presentationScenesRootURL: URL {
        didSet {
            editorController?.updatePresentationScenesRootURL(presentationScenesRootURL)
        }
    }
    @Published var uiMapPinnedOverlayDefaults: UIMapOverlayOptions {
        didSet {
            preferenceStore.saveUIMapPinnedOverlayDefaults(uiMapPinnedOverlayDefaults)
        }
    }
    var pendingAutoCopyTask: Task<Void, Never>?
    var pendingAutosaveTask: Task<Void, Never>?
    var pendingRecoveryRefreshTask: Task<Void, Never>?
    var pendingCaptureHistorySearchTask: Task<Void, Never>?
    var recoveryOperations = RecoveryOperationState()
    var pendingGuideAutosaveTask: Task<Void, Never>?
    var pendingGuideExportTask: Task<Void, Never>?
    var pendingGuideExportWorkerTask: Task<GuideExportResult, Never>?
    var activeGuideExportID: UUID?
    var pendingCompositionExportTask: Task<Void, Never>?
    var activeCompositionExportID: UUID?
    var recoveryRefreshGeneration = 0
    var captureHistorySearchGeneration = 0
    var currentRecoverySessionID: UUID?
    var savedEditorAutosaveState: AutosaveState?
    var savedDocumentSession: EditorDocumentSession?
    var previousLibrarySwitchSnapshot: LibrarySwitchSnapshot?
    var savedVideoSession: VideoEditorSession?
    var lastAutosavedState: AutosaveState?
    var editorRenderObserver: AnyCancellable?
    var editorPersistenceObserver: AnyCancellable?
    var editorCommandStateObserver: AnyCancellable?
    var videoPersistenceObserver: AnyCancellable?
    var guidePersistenceObserver: AnyCancellable?
    var savedGuideProject: GuideProject?
    var pendingEditorAction: (() -> Void)?
    var pendingEditorCancellation: (() -> Void)?
    var editableRedactionSaveConfirmationHandler: @MainActor () -> EditableRedactionSaveDecision = DocumentWorkflowModel.presentEditableRedactionSaveConfirmation
    var documentFormatMigrationDecisionHandler: @MainActor () -> DocumentFormatMigrationDecision = DocumentWorkflowModel.presentDocumentFormatMigrationConfirmation
    var compositionEditableImportChoiceHandler:
        @MainActor (Int) -> CompositionEditableImportChoice = {
            DocumentWorkflowModel.presentCompositionEditableImportChoice(
                itemCount: $0
            )
        }
    var editableRedactionSaveWarningAcknowledgedEditorIDs: Set<ObjectIdentifier> = []
    init(
        dependencies: DocumentWorkflowDependencies,
        recoveryStore: DocumentRecoveryStore,
        videoRecoveryStore: VideoRecoveryStore,
        incompatibleDocumentCoordinator: IncompatibleDocumentCoordinator,
        preferenceStore: EditorPreferenceStore,
        pendingRecoverySession: PendingRecoverySession?,
        allCaptureHistoryEntries: [DocumentHistoryEntry],
        recentSnipEntries: [DocumentHistoryEntry],
        recycleBinEntries: [DocumentHistoryEntry]
    ) {
        self.dependencies = dependencies
        self.recoveryStore = recoveryStore
        self.videoRecoveryState = VideoRecoveryWorkflowState(store: videoRecoveryStore)
        self.incompatibleDocumentCoordinator = incompatibleDocumentCoordinator
        self.preferenceStore = preferenceStore
        self.pendingRecoverySession = pendingRecoverySession
        self.allCaptureHistoryEntries = allCaptureHistoryEntries
        self.snipLibraryEntries =
            DocumentHistoryEntrySelection.latestPerSession(
                from: allCaptureHistoryEntries
            )
        self.recentSnipEntries = recentSnipEntries
        self.recycleBinEntries = recycleBinEntries
        self.editorSingleKeyToolShortcutsEnabled = preferenceStore.loadSingleKeyToolShortcutsEnabled()
        self.editorStartupToolPreference = preferenceStore.loadStartupToolPreference()
        self.editorCropOutsideOverlayAlpha = preferenceStore.loadCropOutsideOverlayAlpha()
        self.editorOutOfCapturePatternSettings = preferenceStore.loadOutOfCapturePatternSettings()
        self.presentationScenesRootURL = preferenceStore.loadPresentationScenesRootURL()
        self.uiMapPinnedOverlayDefaults = preferenceStore.loadUIMapPinnedOverlayDefaults()
    }

    var capabilities: AppCapabilitySnapshot {
        dependencies.capabilities
    }

    var systemServices: AppSystemServices {
        dependencies.systemServices
    }

    var screenshotFilenameTemplate: String {
        dependencies.capture.screenshotFilenameTemplate
    }

    var screenshotDragOutFormat: ImageExportFormat {
        dependencies.capture.screenshotDragOutFormat
    }

    var screenshotJPEGQuality: CGFloat {
        dependencies.capture.screenshotJPEGQuality
    }

    var windowUIMapEnabled: Bool {
        dependencies.capabilities.isEnabled(.uiMap) && dependencies.capture.uiMapEnabled
    }

    var autoCopyEnabled: Bool {
        dependencies.clipboard.autoCopyEnabled
    }

    var clipboardMonitor: ClipboardMonitor {
        dependencies.clipboard.monitor
    }

    var textRecognitionCoordinator: CaptureTextRecognitionCoordinator {
        dependencies.textRecognitionCoordinator
    }

    var floatingReferenceCoordinator: FloatingReferenceCoordinator {
        dependencies.floatingReferenceCoordinator
    }

    var historyPreviewCoordinator: HistoryPreviewCoordinator {
        dependencies.historyPreviewCoordinator
    }

    var isInteractiveCaptureAutosaveSuspended: Bool {
        dependencies.capture.isInteractiveCaptureAutosaveSuspended
    }

    func cancelPendingWindowThumbnailRefresh() {
        dependencies.capture.cancelPendingWindowThumbnailRefresh()
    }

    func publishEditorDocumentOutputAvailability(_ isAvailable: Bool) {
        isEditorDocumentOutputAvailable = isAvailable
    }

    var activeVideoRecording: ActiveVideoRecording? {
        dependencies.video.activeVideoRecording
    }

    func performDocumentWork<Result>(
        message: String,
        _ operation: () async throws -> Result
    ) async rethrows -> Result {
        try await dependencies.capture.performDocumentWork(message: message, operation)
    }

    func updateWorkingMessage(_ message: String) {
        dependencies.lifecycle.updateWorkingMessage(message)
    }

    func presentError(_ message: String) {
        dependencies.lifecycle.presentError(message)
    }

    func clearError() {
        dependencies.lifecycle.clearError()
    }

}
