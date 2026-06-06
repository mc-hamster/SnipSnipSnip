import AppKit
import Foundation

extension AppModel {
    func initialCaptureHistoryIndexImage(for controller: EditorController) -> CGImage {
        controller.capture.image
    }

    var filteredCaptureHistoryEntries: [DocumentHistoryEntry] {
        filteredEntries(from: allCaptureHistoryEntries)
    }

    var captureHistorySearchResultsLabel: String {
        let query = captureSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return "Recent checkpoints, autosaves, and shelved snips from every session."
        }

        let resultCount = filteredCaptureHistoryEntries.count
        return resultCount == 1 ? "1 result for \"\(query)\"" : "\(resultCount) results for \"\(query)\""
    }

    func scheduleIndexedCaptureHistorySearch() {
        captureHistorySearchGeneration += 1
        let generation = captureHistorySearchGeneration
        let query = captureSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        pendingCaptureHistorySearchTask?.cancel()

        guard !query.isEmpty else {
            pendingCaptureHistorySearchTask = nil
            allCaptureHistoryEntries = recoveryStore.allHistoryEntries(limit: Self.captureHistoryLimit)
            return
        }

        let store = recoveryStore
        let searchLimit = Self.captureHistorySearchLimit
        pendingCaptureHistorySearchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)

            guard !Task.isCancelled else {
                return
            }

            let searchTask = Task.detached(priority: .utility) {
                store.searchHistoryEntries(matching: query, limit: searchLimit)
            }
            let entries = await withTaskCancellationHandler {
                await searchTask.value
            } onCancel: {
                searchTask.cancel()
            }

            guard let self, !Task.isCancelled, self.captureHistorySearchGeneration == generation else {
                return
            }

            self.pendingCaptureHistorySearchTask = nil
            self.allCaptureHistoryEntries = entries
        }
    }

    func handleGlobalHotKeyAction(_ action: GlobalHotKeyAction) {
        guard !isWorking else {
            return
        }

        switch action {
        case .region:
            captureRegion()
        case .window:
            presentWindowPicker()
        case .fullscreen:
            captureCurrentDisplay()
        case .frontmostWindow:
            captureFrontmostWindow()
        case .repeatLastCapture:
            repeatLastCapture()
        case .screenInspector:
            toggleScreenInspector()
        }
    }

    func indexCurrentCaptureIfNeeded(using controller: EditorController) {
        guard let currentRecoverySessionID,
              let entry = recoveryStore.historyEntries(for: currentRecoverySessionID).first else {
            return
        }

        let capturedImage = initialCaptureHistoryIndexImage(for: controller)
        textRecognitionCoordinator.recognizeText(for: entry, image: capturedImage) { [weak self] searchableText in
            self?.applyRecognizedSearchText(searchableText, to: entry)
        }
    }

    private func filteredEntries(from entries: [DocumentHistoryEntry]) -> [DocumentHistoryEntry] {
        let query = captureSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return entries
        }

        return entries.filter { $0.matchesSearchQuery(query) }
    }

    private func applyRecognizedSearchText(_ searchableText: String, to entry: DocumentHistoryEntry) {
        do {
            try recoveryStore.updateCheckpointSearchableText(
                sessionID: entry.sessionID,
                checkpointID: entry.id,
                searchableText: searchableText
            )
        } catch {
            present(error)
            return
        }

        historyEntries = updatingSearchableText(in: historyEntries, for: entry, searchableText: searchableText)
        allCaptureHistoryEntries = updatingSearchableText(in: allCaptureHistoryEntries, for: entry, searchableText: searchableText)
        recentSnipEntries = updatingSearchableText(in: recentSnipEntries, for: entry, searchableText: searchableText)
        scheduleIndexedCaptureHistorySearch()

        if let pendingRecoverySession,
           pendingRecoverySession.latestEntry.id == entry.id,
           pendingRecoverySession.latestEntry.sessionID == entry.sessionID {
            let updatedEntry = pendingRecoverySession.latestEntry.updating(searchableText: searchableText)
            self.pendingRecoverySession = PendingRecoverySession(
                id: pendingRecoverySession.id,
                title: pendingRecoverySession.title,
                latestEntry: updatedEntry
            )
        }
    }

    private func updatingSearchableText(
        in entries: [DocumentHistoryEntry],
        for targetEntry: DocumentHistoryEntry,
        searchableText: String
    ) -> [DocumentHistoryEntry] {
        entries.map { entry in
            guard entry.id == targetEntry.id, entry.sessionID == targetEntry.sessionID else {
                return entry
            }

            return entry.updating(searchableText: searchableText)
        }
    }
}
