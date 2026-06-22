import Combine
import Foundation

@MainActor
struct VideoWorkflowDependencies {
    let capabilities: AppCapabilitySnapshot
    let systemServices: AppSystemServices
    let appWindowPresenter: any AppWindowPresenting
    let permissions: any PermissionGatekeeping
    let lifecycle: any WorkflowLifecyclePresenting
    let capture: any VideoCaptureWorkflowPort
}

@MainActor
final class VideoWorkflowModel: ObservableObject {
    let dependencies: VideoWorkflowDependencies
    let recordingService: ScreenRecordingService
    weak var documents: (any VideoDocumentWorkflowPort)?
    @Published var activeVideoRecording: ActiveVideoRecording?
    @Published var recordingPreferences: VideoRecordingPreferences {
        didSet {
            preferenceStore.saveRecordingPreferences(recordingPreferences)
        }
    }
    @Published var exportPreferences: VideoExportPreferences {
        didSet {
            preferenceStore.saveExportPreferences(exportPreferences)
        }
    }
    var videoStorageMonitorTask: Task<Void, Never>?
    private let preferenceStore: VideoPreferenceStore

    init(
        dependencies: VideoWorkflowDependencies,
        recordingService: ScreenRecordingService,
        preferenceStore: VideoPreferenceStore
    ) {
        self.dependencies = dependencies
        self.recordingService = recordingService
        self.preferenceStore = preferenceStore
        self.recordingPreferences = preferenceStore.loadRecordingPreferences()
        self.exportPreferences = preferenceStore.loadExportPreferences()
    }
}
