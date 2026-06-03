import AppKit
import Foundation

extension AppModel {
    var archiveSizeLabel: String {
        ByteCountFormatter.string(fromByteCount: archiveSizeBytes, countStyle: .file)
    }

    var archiveLocationDescription: String {
        archiveDirectoryURL.path
    }

    var usesDefaultArchiveLocation: Bool {
        configuredArchiveLocationURL == nil
    }

    static func loadArchiveLocationURL(from defaults: UserDefaults) -> URL? {
        if let bookmarkData = defaults.data(forKey: AppModelPreferenceKey.archiveLocationBookmarkData) {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return url
            }
        }

        guard let path = defaults.string(forKey: AppModelPreferenceKey.archiveLocationPath) else {
            return nil
        }

        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func loadArchiveMaximumSizeMB(from defaults: UserDefaults) -> Int {
        let configuredSize = defaults.object(forKey: AppModelPreferenceKey.archiveMaximumSizeMB) as? Int
            ?? defaults.integer(forKey: AppModelPreferenceKey.archiveMaximumSizeMB)

        guard configuredSize > 0 else {
            return defaultArchiveMaximumSizeMB
        }

        return max(configuredSize, minimumArchiveMaximumSizeMB)
    }

    func chooseArchiveLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = archiveDirectoryURL
        panel.prompt = "Use Location"

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
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
            try FileManager.default.createDirectory(at: archiveDirectoryURL, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([archiveDirectoryURL])
        } catch {
            present(error)
        }
    }

    func updateArchiveMaximumSizeMB(_ value: Int) {
        archiveMaximumSizeMB = max(value, Self.minimumArchiveMaximumSizeMB)
    }

    func updateRecycleBinRetentionDays(_ value: Int) {
        recycleBinRetentionDays = max(value, Self.minimumRecycleBinRetentionDays)
    }

    func clearArchive() {
        let store = recoveryStore

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            self.pendingAutosaveTask?.cancel()
            self.pendingAutosaveTask = nil

            let pendingWriteTasks = Array(self.pendingRecoveryWriteTasks.values)
            self.pendingRecoveryWriteTasks.removeAll()
            pendingWriteTasks.forEach { $0.cancel() }

            for task in pendingWriteTasks {
                await task.value
            }

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
            guard let strongSelf = self else {
                return
            }

            await strongSelf.runArchiveMaintenanceCycle()

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.archiveMaintenanceNanoseconds)

                guard !Task.isCancelled else {
                    return
                }

                guard let strongSelf = self else {
                    return
                }

                await strongSelf.runArchiveMaintenanceCycle()
            }
        }
    }
}

extension AppModel {
    var archiveMaximumSizeBytes: Int64 {
        Int64(archiveMaximumSizeMB) * 1_024 * 1_024
    }

    func runArchiveMaintenanceCycle() async {
        let store = recoveryStore
        let maximumSizeBytes = archiveMaximumSizeBytes
        let recycleBinRetentionDays = recycleBinRetentionDays
        let result = await Task.detached(priority: .utility) { () -> (size: Int64, didPrune: Bool) in
            let cutoffDate = Calendar.current.date(byAdding: .day, value: -recycleBinRetentionDays, to: Date()) ?? .distantPast
            let didPruneRecycleBin = (try? store.pruneRecycleBin(deletedBefore: cutoffDate)) ?? false
            let didPruneArchive = (try? store.pruneArchiveIfNeeded(maximumSizeBytes: maximumSizeBytes)) ?? false
            let size = (try? store.archiveSizeInBytes()) ?? 0
            return (size, didPruneRecycleBin || didPruneArchive)
        }.value

        guard recoveryStore.archiveURL == store.archiveURL else {
            return
        }

        archiveSizeBytes = result.size

        if result.didPrune {
            refreshRecoveryPresentationState()
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
        if let url {
            defaults.set(url.path, forKey: AppModelPreferenceKey.archiveLocationPath)

            if let bookmarkData = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                defaults.set(bookmarkData, forKey: AppModelPreferenceKey.archiveLocationBookmarkData)
            } else {
                defaults.removeObject(forKey: AppModelPreferenceKey.archiveLocationBookmarkData)
            }
        } else {
            defaults.removeObject(forKey: AppModelPreferenceKey.archiveLocationPath)
            defaults.removeObject(forKey: AppModelPreferenceKey.archiveLocationBookmarkData)
        }
    }

    func reconfigureArchiveStore(baseURL: URL?) {
        pendingAutosaveTask?.cancel()
        pendingAutosaveTask = nil
        pendingRecoveryRefreshTask?.cancel()
        pendingRecoveryRefreshTask = nil
        pendingCaptureHistorySearchTask?.cancel()
        pendingCaptureHistorySearchTask = nil
        pendingRecoveryWriteTasks.values.forEach { $0.cancel() }
        pendingRecoveryWriteTasks.removeAll()
        lastAutosavedState = nil

        configuredArchiveLocationURL = baseURL
        activateArchiveDirectoryAccess(baseURL)
        recoveryStore = DocumentRecoveryStore(baseURL: baseURL)
        archiveDirectoryURL = recoveryStore.archiveURL
        reseedCurrentRecoverySessionIfNeeded()

        if shouldStartArchiveMaintenance {
            startArchiveMaintenance()
        } else {
            archiveMaintenanceTask?.cancel()
            archiveMaintenanceTask = nil
        }
    }

    func reseedCurrentRecoverySessionIfNeeded() {
        guard let controller = editorController else {
            currentRecoverySessionID = nil
            refreshRecoveryPresentationState()
            return
        }

        currentRecoverySessionID = createRecoverySessionIfNeeded(for: controller, documentURL: currentDocumentURL)
        refreshRecoveryPresentationState()
        recordRecoveryCheckpoint(for: controller, label: hasUnsavedChanges ? "Autosave" : "Saved", pendingRecovery: hasUnsavedChanges)
    }
}
