import Foundation

@MainActor
protocol CaptureAutomationCoordinatorPort: AnyObject {
    func capturePreset(_ preset: CapturePreset)
    func automationResultAfterCurrentEditorOutput(
        _ request: AutomationRequest,
        _ kind: String,
        _ sourceName: String?
    ) async -> AutomationResultEnvelope
    func beginRegionCapture()
    func presentWindowPicker()
    func canRepeatLastCapture() -> Bool
    func repeatLastCapture()
}

@MainActor
protocol CaptureDocumentWorkflowPort: AnyObject {
    var activeCaptureEditorController: EditorController? { get }

    func suspendAutosaveForInteractiveCapture() -> InteractiveCaptureAutosaveSuspension
    func resumeAutosaveAfterInteractiveCapture(_ suspension: InteractiveCaptureAutosaveSuspension)
    func performAfterHandlingUnsavedChanges(_ action: @escaping () -> Void)
    func currentProtectedTemporaryVideoURLs() -> [URL]
}

@MainActor
protocol CaptureVideoWorkflowPort: AnyObject {
    var blocksNewCapture: Bool { get }
    var connectedDeviceRecordingPreferences: VideoRecordingPreferences { get }
}

@MainActor
protocol CaptureGuideWorkflowPort: AnyObject {
    var isActive: Bool { get }
}

extension GuideWorkflowModel: CaptureGuideWorkflowPort {}

@MainActor
extension DocumentWorkflowModel: CaptureDocumentWorkflowPort {
    var activeCaptureEditorController: EditorController? {
        editorController
    }
}

@MainActor
extension VideoWorkflowModel: CaptureVideoWorkflowPort {
    var connectedDeviceRecordingPreferences: VideoRecordingPreferences {
        recordingPreferences
    }
}
