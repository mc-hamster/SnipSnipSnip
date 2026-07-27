import Foundation

@MainActor
protocol CreationCaptureWorkflowPort: AnyObject {
    func captureRegion(
        intent: CaptureIntent,
        completionRole: CaptureCompletionRole,
        oneShotOptions: CaptureOneShotOptions?
    )
    func presentWindowPicker(
        intent: CaptureIntent,
        completionRole: CaptureCompletionRole,
        oneShotOptions: CaptureOneShotOptions?
    )
    func captureCurrentDisplay(
        intent: CaptureIntent,
        completionRole: CaptureCompletionRole,
        oneShotOptions: CaptureOneShotOptions?
    )
    func captureScrollingArea(
        intent: CaptureIntent,
        completionRole: CaptureCompletionRole,
        oneShotOptions: CaptureOneShotOptions?
    )
    func prepareCaptureIntent(
        _ intent: CaptureIntent,
        completionRole: CaptureCompletionRole,
        oneShotOptions: CaptureOneShotOptions?
    )
    @discardableResult
    func preparePersistentCaptureSurfaceIntent(
        _ intent: CaptureIntent,
        completionRole: CaptureCompletionRole,
        oneShotOptions: CaptureOneShotOptions?
    ) -> CaptureCompletionContext
    @discardableResult
    func prepareScreenInspectorCaptureIntent(
        _ intent: CaptureIntent,
        completionRole: CaptureCompletionRole,
        oneShotOptions: CaptureOneShotOptions?
    ) -> CaptureCompletionContext
    func resetPreparedCaptureContext(
        ifMatching context: CaptureCompletionContext
    )
    func resetPersistentCaptureSurfaceSession(_ sessionID: UUID)
}

@MainActor
protocol CreationDocumentWorkflowPort: AnyObject {
    func createDocumentFromFiles(
        completionRole: CaptureCompletionRole,
        options: CaptureOneShotOptions
    ) -> Bool
    func createDocumentFromClipboard(
        completionRole: CaptureCompletionRole,
        options: CaptureOneShotOptions
    ) -> Bool
}

@MainActor
protocol CreationGuideWorkflowPort: AnyObject {
    func presentQuickStart()
}

@MainActor
protocol CreationToolWorkflowPort: AnyObject {
    func presentScreenInspector(onClose: (() -> Void)?)
}

@MainActor
extension CaptureWorkflowModel: CreationCaptureWorkflowPort {}

@MainActor
extension DocumentWorkflowModel: CreationDocumentWorkflowPort {}

@MainActor
extension GuideWorkflowModel: CreationGuideWorkflowPort {}

@MainActor
extension ToolWorkflowModel: CreationToolWorkflowPort {}
