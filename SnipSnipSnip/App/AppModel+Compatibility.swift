import Foundation

extension AppModel {
    func handleIncompatibleRecoveryEntriesOnLaunch() {
        let incompatibleEntries = recoveryStore.incompatibleHistoryEntries()

        guard !incompatibleEntries.isEmpty else {
            return
        }

        let didContinue = incompatibleDocumentCoordinator.handleIncompatibleFiles(
            incompatibleEntries.map(\.packageURL),
            sourceDescription: "archive history",
            presentError: present
        ) {
            try self.recoveryStore.purgeHistoryEntriesAfterExternalRemoval(incompatibleEntries)
        }

        guard didContinue else {
            return
        }

        reloadRecoveryPresentationStateFromStore()
    }

    @discardableResult
    func handleIncompatibleDocumentIfNeeded(at url: URL) -> Bool {
        guard compatibilityStatus(forDocumentAt: url).isUnsupportedFormatVersion else {
            return false
        }

        _ = incompatibleDocumentCoordinator.handleIncompatibleFiles(
            [url],
            sourceDescription: "selected document",
            presentError: present
        )
        return true
    }

    private func compatibilityStatus(forDocumentAt url: URL) -> PackageCompatibilityStatus {
        if url.pathExtension.lowercased() == "sssvideo" {
            return SSSVideoDocumentPackage.compatibilityStatus(at: url)
        }

        return SSSDocumentPackage.compatibilityStatus(at: url)
    }

    private func reloadRecoveryPresentationStateFromStore() {
        pendingRecoverySession = recoveryStore.latestPendingRecovery()
        allCaptureHistoryEntries = recoveryStore.allHistoryEntries(limit: Self.captureHistoryLimit)
        recentSnipEntries = recoveryStore.pendingRecoveryEntries(limit: Self.recentSnipLimit)
        recycleBinEntries = recoveryStore.recycledHistoryEntries(limit: Self.recycleBinLimit)

        if let currentRecoverySessionID {
            historyEntries = recoveryStore.historyEntries(for: currentRecoverySessionID)
        } else {
            historyEntries = []
        }

        scheduleIndexedCaptureHistorySearch()
    }
}