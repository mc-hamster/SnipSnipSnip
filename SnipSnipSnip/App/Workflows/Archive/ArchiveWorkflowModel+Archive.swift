import Foundation

struct ArchiveMaintenanceRequest {
    let store: DocumentRecoveryStore
    let maximumSizeBytes: Int64
    let recycleBinRetentionDays: Int
    let now: Date
}

struct ArchiveMaintenanceResult: Equatable {
    let archiveSizeBytes: Int64
    let didPrune: Bool
}

enum ArchiveMaintenanceManager {
    static func run(_ request: ArchiveMaintenanceRequest) async -> ArchiveMaintenanceResult {
        await Task.detached(priority: .utility) {
            let cutoffDate = Calendar.current.date(byAdding: .day, value: -request.recycleBinRetentionDays, to: request.now) ?? .distantPast
            let didPruneRecycleBin = (try? request.store.pruneRecycleBin(deletedBefore: cutoffDate)) ?? false
            let didPruneArchive = (try? request.store.pruneArchiveIfNeeded(maximumSizeBytes: request.maximumSizeBytes)) ?? false
            let archiveSizeBytes = (try? request.store.archiveSizeInBytes()) ?? 0
            return ArchiveMaintenanceResult(
                archiveSizeBytes: archiveSizeBytes,
                didPrune: didPruneRecycleBin || didPruneArchive
            )
        }.value
    }
}

extension ArchiveWorkflowModel {
    var archiveSizeLabel: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var archiveLocationDescription: String {
        directoryURL.path
    }

    var usesDefaultArchiveLocation: Bool {
        configuredArchiveLocationURL == nil
    }

    static func loadArchiveLocationURL(from defaults: UserDefaults) -> URL? {
        AppPreferenceStores(storage: defaults).archive.loadLocationURL()
    }

    static func loadArchiveMaximumSizeMB(from defaults: UserDefaults) -> Int {
        AppPreferenceStores(storage: defaults).archive.loadMaximumSizeMB()
    }

    func chooseArchiveLocation() {
        guard let selectedURL = dependencies.locationPresenter.selectArchiveLocation(initialDirectory: directoryURL) else {
            return
        }

        persistArchiveLocation(selectedURL)
        reconfigureArchiveStore(baseURL: selectedURL)
    }

    func resetArchiveLocationToDefault() {
        persistArchiveLocation(nil)
        reconfigureArchiveStore(baseURL: nil)
    }

    func openArchiveLocationInFinder() {
        do {
            try dependencies.systemServices.files.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            dependencies.systemServices.workspace.activateFileViewerSelecting([directoryURL])
        } catch {
            present(error)
        }
    }

    func updateArchiveMaximumSizeMB(_ value: Int) {
        maximumSizeMB = max(value, ArchiveWorkflowConstants.minimumMaximumSizeMB)
    }

    func updateRecycleBinRetentionDays(_ value: Int) {
        recycleBinRetentionDays = min(
            max(value, ArchiveWorkflowConstants.minimumRecycleBinRetentionDays),
            ArchiveWorkflowConstants.maximumRecycleBinRetentionDays
        )
    }

    func clearArchive() {
        let store = recoveryStore

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            await self.documents?.prepareForArchiveClear()

            do {
                try await Task.detached(priority: .utility) {
                    try store.clearArchive()
                }.value

                self.reseedCurrentRecoverySessionIfNeeded()
                self.triggerArchiveMaintenance()
            } catch {
                self.present(error)
            }
        }
    }

    func triggerArchiveMaintenance() {
        Task { @MainActor [weak self] in
            await self?.runArchiveMaintenanceCycle()
        }
    }

    func startArchiveMaintenance() {
        archiveMaintenanceTask?.cancel()
        archiveMaintenanceTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            await self.runArchiveMaintenanceCycle()

            while !Task.isCancelled {
                try? await self.dependencies.systemServices.scheduler.sleep(nanoseconds: ArchiveWorkflowConstants.maintenanceDebounceNanoseconds)

                guard !Task.isCancelled else {
                    return
                }

                await self.runArchiveMaintenanceCycle()
            }
        }
    }

    var archiveMaximumSizeBytes: Int64 {
        Int64(maximumSizeMB) * 1_024 * 1_024
    }

    func runArchiveMaintenanceCycle() async {
        let request = ArchiveMaintenanceRequest(
            store: recoveryStore,
            maximumSizeBytes: archiveMaximumSizeBytes,
            recycleBinRetentionDays: recycleBinRetentionDays,
            now: dependencies.systemServices.clock.now()
        )
        let result = await ArchiveMaintenanceManager.run(request)

        guard recoveryStore.archiveURL == request.store.archiveURL else {
            return
        }

        sizeBytes = result.archiveSizeBytes

        if result.didPrune {
            documents?.refreshRecoveryPresentationState()
        }
    }

    func activateArchiveDirectoryAccess(_ url: URL?) {
        if archiveSecurityScopedURL?.path == url?.path {
            return
        }

        if let archiveSecurityScopedURL {
            archiveSecurityScopedURL.stopAccessingSecurityScopedResource()
            self.archiveSecurityScopedURL = nil
        }

        guard let url else {
            return
        }

        guard url.startAccessingSecurityScopedResource() else {
            return
        }

        archiveSecurityScopedURL = url
    }

    func persistArchiveLocation(_ url: URL?) {
        preferenceStore.saveLocationURL(url)
    }

    func reconfigureArchiveStore(baseURL: URL?) {
        configuredArchiveLocationURL = baseURL
        activateArchiveDirectoryAccess(baseURL)
        recoveryStore = DocumentRecoveryStore(baseURL: baseURL)
        documents?.rebindRecoveryStore(recoveryStore)
        directoryURL = recoveryStore.archiveURL
        reseedCurrentRecoverySessionIfNeeded()

        if shouldStartMaintenance {
            startArchiveMaintenance()
        } else {
            archiveMaintenanceTask?.cancel()
            archiveMaintenanceTask = nil
        }
    }

    func reseedCurrentRecoverySessionIfNeeded() {
        documents?.reseedRecoverySessionAfterArchiveChange()
    }

    private func present(_ error: Error) {
        dependencies.lifecycle.presentError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }
}
