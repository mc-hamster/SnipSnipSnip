import Combine
import Foundation

@MainActor
protocol ArchiveLocationPresenting {
    func selectArchiveLocation(initialDirectory: URL) -> URL?
}

@MainActor
struct ArchiveWorkflowDependencies {
    let systemServices: AppSystemServices
    let lifecycle: any WorkflowLifecyclePresenting
    let locationPresenter: any ArchiveLocationPresenting
}

@MainActor
final class ArchiveWorkflowModel: ObservableObject {
    let dependencies: ArchiveWorkflowDependencies
    var recoveryStore: DocumentRecoveryStore
    let preferenceStore: ArchivePreferenceStore
    weak var documents: (any ArchiveDocumentWorkflowPort)?
    var shouldStartMaintenance = true
    var archiveMaintenanceTask: Task<Void, Never>?
    var configuredArchiveLocationURL: URL?
    var archiveSecurityScopedURL: URL?
    @Published var maximumSizeMB: Int {
        didSet {
            preferenceStore.saveMaximumSizeMB(maximumSizeMB)
            triggerArchiveMaintenance()
        }
    }
    @Published var recycleBinRetentionDays: Int {
        didSet {
            let sanitizedValue = max(recycleBinRetentionDays, ArchiveWorkflowConstants.minimumRecycleBinRetentionDays)

            guard sanitizedValue == recycleBinRetentionDays else {
                recycleBinRetentionDays = sanitizedValue
                return
            }

            preferenceStore.saveRecycleBinRetentionDays(recycleBinRetentionDays)
            triggerArchiveMaintenance()
        }
    }
    @Published var sizeBytes: Int64 = 0
    @Published var directoryURL: URL

    init(
        dependencies: ArchiveWorkflowDependencies,
        recoveryStore: DocumentRecoveryStore,
        configuredArchiveLocationURL: URL?,
        preferenceStore: ArchivePreferenceStore
    ) {
        self.dependencies = dependencies
        self.recoveryStore = recoveryStore
        self.preferenceStore = preferenceStore
        self.configuredArchiveLocationURL = configuredArchiveLocationURL
        self.maximumSizeMB = preferenceStore.loadMaximumSizeMB()
        self.recycleBinRetentionDays = preferenceStore.loadRecycleBinRetentionDays()
        self.directoryURL = recoveryStore.archiveURL
    }
}
