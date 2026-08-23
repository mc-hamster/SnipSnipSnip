import CoreGraphics
import Foundation

@MainActor
extension DocumentWorkflowModel {
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
