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
    var archiveMaintenanceRunTask: Task<Void, Never>?
    var archiveMaintenanceRequested = false
    var archiveMaintenanceRunCount = 0
    var configuredArchiveLocationURL: URL?
    var archiveSecurityScopedURL: URL?
    var folderAccess: ArchiveFolderAccess?
    var requestedArchiveLocationURL: URL?
    @Published var folderAccessError: ArchiveFolderAccessError?
    @Published var maximumSizeMB: Int {
        didSet {
            preferenceStore.saveMaximumSizeMB(maximumSizeMB)
            triggerArchiveMaintenance()
        }
    }
    @Published var recycleBinRetentionDays: Int {
        didSet {
            let sanitizedValue = min(
                max(recycleBinRetentionDays, ArchiveWorkflowConstants.minimumRecycleBinRetentionDays),
                ArchiveWorkflowConstants.maximumRecycleBinRetentionDays
            )

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
        preferenceStore: ArchivePreferenceStore,
        preparedLocation: PreparedArchiveLocation? = nil
    ) {
        self.dependencies = dependencies
        self.recoveryStore = recoveryStore
        self.preferenceStore = preferenceStore
        self.configuredArchiveLocationURL = configuredArchiveLocationURL
        folderAccess = preparedLocation?.access
        archiveSecurityScopedURL = folderAccess?.didStartAccess == true ? folderAccess?.url : nil
        requestedArchiveLocationURL = preparedLocation?.requestedURL ?? configuredArchiveLocationURL
        folderAccessError = preparedLocation?.error
        self.maximumSizeMB = preferenceStore.loadMaximumSizeMB()
        self.recycleBinRetentionDays = preferenceStore.loadRecycleBinRetentionDays()
        self.directoryURL = recoveryStore.archiveURL
        if folderAccessError != nil {
            dependencies.lifecycle.presentError(String(localized: "The saved Snip History folder could not be accessed. New snips are kept in the default location. Choose Location in Snip Library settings to restore access. Existing history has not been moved or deleted."))
        }
    }
}
