import CoreGraphics
import Foundation

extension DocumentWorkflowModel {
    /// Archive presents one current document per retained session; Capture
    /// History intentionally exposes every checkpoint and autosave revision.
    var compositionArchiveEntries: [DocumentHistoryEntry] {
        DocumentHistoryEntrySelection.latestPerSession(
            from: allCaptureHistoryEntries
        )
    }

    func handleIncompatibleRecoveryEntriesOnLaunch() {
        let incompatibleEntries = recoveryStore.incompatibleHistoryEntries()

        guard !incompatibleEntries.isEmpty else {
            return
        }

        let didContinue = incompatibleDocumentCoordinator.handleIncompatibleFiles(
            incompatibleEntries.map(\.packageURL),
            sourceDescription: WorkflowVocabulary.Library.snipHistory,
            presentError: present
        ) {
            try self.recoveryStore.purgeHistoryEntriesAfterExternalRemoval(incompatibleEntries)
        }

        guard didContinue else {
            return
        }

        reloadRecoveryPresentationStateFromStore()
    }

    func reloadRecoveryPresentationStateFromStore() {
        pendingRecoverySession = recoveryStore.latestPendingRecovery()
        let allEntries = recoveryStore.allHistoryEntries(
            limit: DocumentWorkflowConstants.captureHistoryLimit
        )
        allCaptureHistoryEntries = allEntries
        snipLibraryEntries = DocumentHistoryEntrySelection.latestPerSession(
            from: allEntries
        )
        recentSnipEntries = recoveryStore.pendingRecoveryEntries(limit: DocumentWorkflowConstants.recentSnipLimit)
        recycleBinEntries = recoveryStore.recycledHistoryEntries(limit: DocumentWorkflowConstants.recycleBinLimit)

        if let currentRecoverySessionID {
            historyEntries = recoveryStore.historyEntries(for: currentRecoverySessionID)
        } else {
            historyEntries = []
        }

        scheduleIndexedCaptureHistorySearch()
    }

    func initialCaptureHistoryIndexImage(for controller: EditorController) -> CGImage {
        guard controller.hasComposition else {
            return controller.documentCapture.image
        }
        var snapshot = controller.documentSession.currentSnapshot
        snapshot.presentation = .plain
        let input = controller.compositionDocumentPreviewInput(snapshot: snapshot)
        return (try? CompositionDocumentPreviewRenderer.render(input))
            ?? controller.documentCapture.image
    }

    var filteredCaptureHistoryEntries: [DocumentHistoryEntry] {
        filteredEntries(from: allCaptureHistoryEntries)
    }

    var captureHistorySearchResultsLabel: String {
        let query = captureSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return "Snip History includes checkpoints, autosaves, and shelved snips from every session."
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
            let allEntries = recoveryStore.allHistoryEntries(
                limit: DocumentWorkflowConstants.captureHistoryLimit
            )
            allCaptureHistoryEntries = allEntries
            snipLibraryEntries =
                DocumentHistoryEntrySelection.latestPerSession(
                    from: allEntries
                )
            return
        }

        let store = recoveryStore
        let searchLimit = DocumentWorkflowConstants.captureHistorySearchLimit
        pendingCaptureHistorySearchTask = Task { @MainActor [weak self] in
            try? await self?.systemServices.scheduler.sleep(nanoseconds: 180_000_000)

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

    func indexCurrentCaptureIfNeeded(using controller: EditorController) {
        guard !controller.isPrivateDocument,
              let currentRecoverySessionID,
              let entry = recoveryStore.historyEntries(for: currentRecoverySessionID).first else {
            return
        }

        let capturedImage = initialCaptureHistoryIndexImage(for: controller)
        textRecognitionCoordinator.recognizeText(
            for: entry,
            image: capturedImage,
            includeUIMapSearchText: windowUIMapEnabled
        ) { [weak self] searchableText in
            self?.applyRecognizedSearchText(searchableText, to: entry)
        }
    }

    func currentProtectedTemporaryVideoURLs() -> [URL] {
        [videoEditorController?.recording.sourceURL, activeVideoRecording?.session.outputURL]
            .compactMap { $0 }
            .filter { TemporaryVideoMediaManager.isOwnedTemporaryMediaURL($0, files: systemServices.files) }
    }

    func currentOwnedTemporaryVideoSourceURL(replacingWith newSourceURL: URL?) -> URL? {
        guard let currentSourceURL = videoEditorController?.recording.sourceURL,
              TemporaryVideoMediaManager.isOwnedTemporaryMediaURL(currentSourceURL, files: systemServices.files) else {
            return nil
        }

        guard currentSourceURL.standardizedFileURL != newSourceURL?.standardizedFileURL else {
            return nil
        }

        return currentSourceURL
    }

    func cleanupTemporaryVideoSourceIfNeeded(previousSourceURL: URL?) {
        guard let previousSourceURL,
              TemporaryVideoMediaManager.isOwnedTemporaryMediaURL(previousSourceURL, files: systemServices.files) else {
            return
        }

        try? systemServices.files.removeItem(at: previousSourceURL)
    }

    func cleanupTemporaryVideoSourceIfNeeded(_ previousSourceURL: URL?) {
        cleanupTemporaryVideoSourceIfNeeded(previousSourceURL: previousSourceURL)
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
            refreshRecoveryPresentationState()
        } catch {
            present(error)
        }
    }
}

nonisolated enum DocumentHistoryEntrySelection {
    static func latestPerSession(
        from entries: [DocumentHistoryEntry]
    ) -> [DocumentHistoryEntry] {
        Dictionary(grouping: entries, by: \.sessionID)
            .values
            .compactMap { sessionEntries in
                sessionEntries.max { $0.savedAt < $1.savedAt }
            }
            .sorted { $0.savedAt > $1.savedAt }
    }
}
