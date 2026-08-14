import CoreGraphics
import Foundation
import UniformTypeIdentifiers

@MainActor
protocol DocumentPanelPresenting {
    func selectDocumentToOpen() -> URL?
    func selectImageToImport() -> URL?
    func selectSingleCompositionSourceToImport() -> URL?
    func selectImagesToImport() -> [URL]
    func selectPresentationScenesRoot(initialDirectory: URL) -> URL?
    func selectSaveDestination(suggestedFilename: String, contentType: UTType) async -> URL?
    func selectExportDirectory() -> URL?
    func copyExportedFiles(_ urls: [URL])
    func shareExportedFiles(_ urls: [URL])
}

extension DocumentPanelPresenting {
    func selectSingleCompositionSourceToImport() -> URL? {
        selectImagesToImport().first
    }
    func selectImagesToImport() -> [URL] {
        selectImageToImport().map { [$0] } ?? []
    }
    func selectExportDirectory() -> URL? { nil }
    func copyExportedFiles(_ urls: [URL]) {}
    func shareExportedFiles(_ urls: [URL]) {}
}

@MainActor
enum DocumentWindowContentKind {
    case screenshot
    case video
    case guide
}

@MainActor
protocol DocumentWindowPresenting {
    func syncMainWindowDocumentState(documentURL: URL?, hasUnsavedChanges: Bool, title: String)
    func resizeMainWindowForContent(pixelSize: CGSize, kind: DocumentWindowContentKind, animated: Bool) -> Bool
    func restoreMainWindowForCaptureHome(animated: Bool)
}

@MainActor
protocol DocumentPasteboardImporting {
    func imageData(fromPasteboardNamed pasteboardName: String) -> Data?
    func clearPasteboard(named pasteboardName: String)
}

@MainActor
protocol DocumentAutomationCoordinatorPort: AnyObject {
    func openDocument(_ url: URL)
    func automationResultAfterCurrentEditorOutput(
        _ request: AutomationRequest,
        _ kind: String,
        _ sourceName: String?
    ) async -> AutomationResultEnvelope
    func saveDocument(_ controller: EditorController, to url: URL) async -> Bool
    func floatCurrentEditorReference()
}

@MainActor
protocol DocumentCaptureWorkflowPort: AnyObject {
    var screenshotFilenameTemplate: String { get }
    var screenshotDragOutFormat: ImageExportFormat { get }
    var screenshotJPEGQuality: CGFloat { get }
    var uiMapEnabled: Bool { get }
    var isInteractiveCaptureAutosaveSuspended: Bool { get }

    func cancelPendingWindowThumbnailRefresh()
    func performDocumentWork<Result>(
        message: String,
        _ operation: () async throws -> Result
    ) async rethrows -> Result
}

@MainActor
protocol DocumentClipboardWorkflowPort: AnyObject {
    var autoCopyEnabled: Bool { get }
    var monitor: ClipboardMonitor { get }
}

@MainActor
protocol DocumentVideoWorkflowPort: AnyObject {
    var activeVideoRecording: ActiveVideoRecording? { get }
}

@MainActor
protocol DocumentArchiveWorkflowPort: AnyObject {
    func triggerArchiveMaintenance()
}

@MainActor
protocol ClipboardDocumentWorkflowPort: AnyObject {
    var currentDocumentURL: URL? { get }
    var allCaptureHistoryEntries: [DocumentHistoryEntry] { get }
    var recentSnipEntries: [DocumentHistoryEntry] { get }
    var historyEntries: [DocumentHistoryEntry] { get }

    func recoverySessionTitle(for controller: EditorController, documentURL: URL?) -> String
    func refreshRecoveryPresentationState()
    func restoreHistoryEntry(_ entry: DocumentHistoryEntry)
}

@MainActor
protocol VideoDocumentWorkflowPort: AnyObject {
    var videoEditorController: VideoEditorController? { get }

    func prepareForNewVideoRecording() async -> Bool
    func installVideoController(
        _ controller: VideoEditorController,
        documentURL: URL?,
        savedSession: VideoEditorSession?
    )
    func currentProtectedTemporaryVideoURLs() -> [URL]
}

@MainActor
protocol ArchiveDocumentWorkflowPort: AnyObject {
    func refreshRecoveryPresentationState()
    func prepareForArchiveClear() async
    func rebindRecoveryStore(_ store: DocumentRecoveryStore)
    func reseedRecoverySessionAfterArchiveChange()
}

@MainActor
extension CaptureWorkflowModel: DocumentCaptureWorkflowPort {}

@MainActor
extension ClipboardWorkflowModel: DocumentClipboardWorkflowPort {}

@MainActor
extension VideoWorkflowModel: DocumentVideoWorkflowPort {}

@MainActor
extension ArchiveWorkflowModel: DocumentArchiveWorkflowPort {}

@MainActor
extension DocumentWorkflowModel: ClipboardDocumentWorkflowPort {}

@MainActor
extension DocumentWorkflowModel: VideoDocumentWorkflowPort {}

@MainActor
extension DocumentWorkflowModel: ArchiveDocumentWorkflowPort {}
