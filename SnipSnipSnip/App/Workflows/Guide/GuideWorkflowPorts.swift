import Foundation

@MainActor
protocol GuideCaptureWorkflowPort: AnyObject {
    var availableWindows: [CaptureWindowSummary] { get }
    var regionCapturePreferences: RegionCapturePreferences { get }
    var isWorking: Bool { get }
    var isConnectedDeviceSessionActive: Bool { get }
    var privateCaptureEnabled: Bool { get }
    var guideHotKeyCode: UInt16 { get }
    func videoWindowSelectionSnapshot(fallbackWindows: [CaptureWindowSummary]) async throws -> (windows: [CaptureWindowSummary], snapshot: DesktopCompositeSnapshot)
}

@MainActor
protocol GuideVideoWorkflowPort: AnyObject { var isRecording: Bool { get } }

@MainActor
protocol CoordinatorGuidePort: AnyObject {
    var isActive: Bool { get }
    func presentQuickStart()
    func togglePauseResume()
    func addManualStep()
    func undoLastStep()
    func stopGuide()
    func prepareForConflictingAction(named action: String) async -> Bool
    func resetGuidePreferencesToDefaults()
}

@MainActor
protocol GuideAutomationPort: AnyObject {
    func guideAutomation(_ command: GuideAutomationCommand, request: AutomationRequest) async -> AutomationResultEnvelope
}

@MainActor
extension CaptureWorkflowModel: GuideCaptureWorkflowPort {
    var guideHotKeyCode: UInt16 { UInt16(automationPreferences.guideHotkey.keyCode) }
}

@MainActor
extension VideoWorkflowModel: GuideVideoWorkflowPort {}

@MainActor
extension GuideWorkflowModel: CoordinatorGuidePort {
    func resetGuidePreferencesToDefaults() {
        capturePreferences = GuideCapturePreferences()
        exportSettings = GuideExportSettings()
        theme = GuideTheme()
        setDefaultLogo(nil)
    }
}
