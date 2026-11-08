import Foundation

@MainActor
protocol VideoCaptureWorkflowPort: AnyObject {
    var privateCaptureEnabled: Bool { get }
    var availableWindows: [CaptureWindowSummary] { get }
    var regionCapturePreferences: RegionCapturePreferences { get }

    func beginVideoWindowSelection() async throws
    func dismissWindowPicker()
    func beginWindowPickerPresentation()
    func beginCapturePrivacyLock() -> Bool
    func endCapturePrivacyLock()
    func desktopSnapshotForVideoSelection() async throws -> DesktopCompositeSnapshot
    func videoWindowSelectionSnapshot() async throws -> (windows: [CaptureWindowSummary], snapshot: DesktopCompositeSnapshot)
    func performVideoWork<Result>(
        message: String,
        _ operation: () async throws -> Result
    ) async rethrows -> Result
    func present(_ error: Error)
}

@MainActor
extension CaptureWorkflowModel: VideoCaptureWorkflowPort {}
