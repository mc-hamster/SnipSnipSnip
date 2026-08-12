import Foundation

@MainActor
struct AppModelCompositionOverrides {
    var recoveryStore: DocumentRecoveryStore?
    var videoRecoveryStore: VideoRecoveryStore?
    var clipboardHistoryStore: ClipboardHistoryStore?
    var captureService: (any ScreenCaptureServiceType)?
    var screenInspectorCapturePlatform: (any ScreenCapturePlatform)?
    var screenRecordingService: ScreenRecordingService?
    var uiMapCaptureService: (any UIMapCaptureServiceType)?
    var connectedDeviceCaptureService: (any ConnectedDeviceCaptureServiceType)?
    var incompatibleDocumentCoordinator: IncompatibleDocumentCoordinator
    var launchAtLoginController: LaunchAtLoginController

    init(
        recoveryStore: DocumentRecoveryStore? = nil,
        videoRecoveryStore: VideoRecoveryStore? = nil,
        clipboardHistoryStore: ClipboardHistoryStore? = nil,
        captureService: (any ScreenCaptureServiceType)? = nil,
        screenInspectorCapturePlatform: (any ScreenCapturePlatform)? = nil,
        screenRecordingService: ScreenRecordingService? = nil,
        uiMapCaptureService: (any UIMapCaptureServiceType)? = nil,
        connectedDeviceCaptureService: (any ConnectedDeviceCaptureServiceType)? = nil,
        incompatibleDocumentCoordinator: IncompatibleDocumentCoordinator = IncompatibleDocumentCoordinator(),
        launchAtLoginController: LaunchAtLoginController = LaunchAtLoginController()
    ) {
        self.recoveryStore = recoveryStore
        self.videoRecoveryStore = videoRecoveryStore
        self.clipboardHistoryStore = clipboardHistoryStore
        self.captureService = captureService
        self.screenInspectorCapturePlatform = screenInspectorCapturePlatform
        self.screenRecordingService = screenRecordingService
        self.uiMapCaptureService = uiMapCaptureService
        self.connectedDeviceCaptureService = connectedDeviceCaptureService
        self.incompatibleDocumentCoordinator = incompatibleDocumentCoordinator
        self.launchAtLoginController = launchAtLoginController
    }
}
