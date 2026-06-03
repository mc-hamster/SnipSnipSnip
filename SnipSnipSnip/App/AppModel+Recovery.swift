import Foundation

extension AppModel {
    func restorePendingRecovery() {
        guard let pendingRecoverySession else {
            return
        }

        restoreHistoryEntry(pendingRecoverySession.latestEntry)
    }

    func dismissPendingRecovery() {
        guard let pendingRecoverySession else {
            return
        }

        do {
            try recoveryStore.clearPendingRecovery(for: pendingRecoverySession.id)
            refreshPendingRecoverySession()
        } catch {
            present(error)
        }
    }

    func restoreHistoryEntry(_ entry: DocumentHistoryEntry) {
        performAfterHandlingUnsavedChanges { [weak self] in
            self?.restoreHistoryEntryImmediately(entry)
        }
    }

    func restoreRecentSnipEntry(_ entry: DocumentHistoryEntry) {
        shelveCurrentDocumentForRecents()
        restoreHistoryEntryImmediately(entry, clearPendingRecovery: false)
    }

    func deleteHistoryEntry(_ entry: DocumentHistoryEntry) {
        do {
            try recoveryStore.deleteHistoryEntry(entry)
            refreshHistoryEntries()
            refreshPendingRecoverySession()
            triggerArchiveMaintenance()
        } catch {
            present(error)
        }
    }

    func deleteAllHistoryEntries() {
        guard let currentRecoverySessionID else {
            return
        }

        do {
            try recoveryStore.deleteHistoryEntries(for: currentRecoverySessionID)
            refreshHistoryEntries()
            refreshPendingRecoverySession()
            triggerArchiveMaintenance()
        } catch {
            present(error)
        }
    }

    func deleteRecentSnipEntry(_ entry: DocumentHistoryEntry) {
        do {
            try recoveryStore.deleteSession(entry.sessionID)
            refreshHistoryEntries()
            refreshPendingRecoverySession()
            triggerArchiveMaintenance()
        } catch {
            present(error)
        }
    }

    func deleteAllRecentSnipEntries() {
        do {
            try recoveryStore.deletePendingRecoverySessions(excluding: currentRecoverySessionID)
            refreshHistoryEntries()
            refreshPendingRecoverySession()
            triggerArchiveMaintenance()
        } catch {
            present(error)
        }
    }

    func restoreHistoryEntryImmediately(_ entry: DocumentHistoryEntry, clearPendingRecovery: Bool = true) {
        do {
            let document = try recoveryStore.restoreDocument(from: entry)
            let controller = EditorController(capture: document.capture, session: document.session)
            installEditorController(
                controller,
                documentURL: entry.sourceDocumentURL,
                savedSession: nil,
                recoverySessionID: entry.sessionID
            )
            if clearPendingRecovery {
                try recoveryStore.clearPendingRecovery(for: entry.sessionID)
                refreshPendingRecoverySession()
            }
            requestMainWindowPresentation()
        } catch {
            present(error)
        }
    }

    func createRecoverySessionIfNeeded(for controller: EditorController, documentURL: URL?) -> UUID? {
        do {
            return try recoveryStore.createSession(
                title: recoverySessionTitle(for: controller, documentURL: documentURL),
                sourceDocumentURL: documentURL
            )
        } catch {
            present(error)
            return nil
        }
    }

    func recoverySessionTitle(for controller: EditorController, documentURL: URL?) -> String {
        if let documentURL {
            return documentURL.lastPathComponent
        }

        return ScreenshotFilenameTemplate(pattern: screenshotFilenameTemplate).resolvedFilename(for: controller.capture, formatExtension: "sss") + ".sss"
    }

    func refreshRecoveryPresentationState() {
        recoveryRefreshGeneration += 1
        let generation = recoveryRefreshGeneration

        pendingRecoveryRefreshTask?.cancel()

        let request = RecoveryPresentationRefreshRequest(
            store: recoveryStore,
            currentSessionID: currentRecoverySessionID,
            captureHistoryLimit: Self.captureHistoryLimit,
            recentSnipLimit: Self.recentSnipLimit,
            recycleBinLimit: Self.recycleBinLimit
        )

        pendingRecoveryRefreshTask = Task { @MainActor [weak self] in
            let state = await RecoveryPresentationStateLoader.load(request)

            guard let self, !Task.isCancelled, self.recoveryRefreshGeneration == generation else {
                return
            }

            self.pendingRecoveryRefreshTask = nil
            self.historyEntries = state.historyEntries
            self.allCaptureHistoryEntries = state.allCaptureHistoryEntries
            self.recentSnipEntries = state.recentSnipEntries
            self.recycleBinEntries = state.recycleBinEntries
            self.pendingRecoverySession = state.pendingRecoverySession
            self.scheduleIndexedCaptureHistorySearch()
        }
    }

    func scheduleAutosave(for controller: EditorController) {
        pendingAutosaveTask?.cancel()

        guard interactiveCaptureAutosaveSuspensionDepth == 0 else {
            pendingAutosaveTask = nil
            return
        }

        guard shouldAutosave(for: controller) else {
            pendingAutosaveTask = nil
            return
        }

        let pendingState = AutosaveState(controller: controller, documentURL: currentDocumentURL)

        guard pendingState != lastAutosavedState else {
            return
        }

        pendingAutosaveTask = Task { @MainActor [weak self, weak controller] in
            do {
                try await Task.sleep(nanoseconds: Self.autosaveDebounceNanoseconds)
            } catch {
                return
            }

            guard let self, let controller, self.editorController === controller else {
                return
            }

            guard self.shouldAutosave(for: controller) else {
                self.pendingAutosaveTask = nil
                return
            }

            let currentState = AutosaveState(controller: controller, documentURL: self.currentDocumentURL)

            guard currentState != self.lastAutosavedState else {
                self.pendingAutosaveTask = nil
                return
            }

            self.recordRecoveryCheckpoint(for: controller, label: "Autosave", pendingRecovery: self.hasUnsavedChanges)
            self.pendingAutosaveTask = nil
        }
    }

    func shouldAutosave(for controller: EditorController) -> Bool {
        currentDocumentURL == nil || AutosaveState(controller: controller, documentURL: currentDocumentURL) != savedEditorAutosaveState
    }

    func recordRecoveryCheckpoint(for controller: EditorController, label: String, pendingRecovery: Bool) {
        guard let currentRecoverySessionID else {
            return
        }

        controller.commitPendingTextEdits()

        let taskID = UUID()
        let controllerID = ObjectIdentifier(controller)
        let autosaveState = AutosaveState(controller: controller, documentURL: currentDocumentURL)
        let payload = RecoveryCheckpointWritePayload(
            store: recoveryStore,
            sessionID: currentRecoverySessionID,
            title: recoverySessionTitle(for: controller, documentURL: currentDocumentURL),
            sourceDocumentURL: currentDocumentURL,
            label: label,
            document: EditableScreenshotDocument(capture: controller.capture, session: controller.documentSession),
            renderInput: ExportRenderInput(baseImage: controller.capture.image, snapshot: controller.snapshot),
            pendingRecovery: pendingRecovery,
            hasUnsavedChanges: hasUnsavedChanges
        )

        pendingRecoveryWriteTasks[taskID] = Task { @MainActor [weak self, weak controller] in
            do {
                try await RecoveryCheckpointWriter.save(payload)
                try Task.checkCancellation()

                guard let self else {
                    return
                }

                self.pendingRecoveryWriteTasks[taskID] = nil
                let isCurrentController = self.editorController.map { ObjectIdentifier($0) } == controllerID

                if isCurrentController {
                    self.lastAutosavedState = autosaveState
                }

                self.refreshRecoveryPresentationState()
                self.triggerArchiveMaintenance()

                if label == "Capture", isCurrentController, let controller {
                    self.indexCurrentCaptureIfNeeded(using: controller)
                }
            } catch {
                guard let self else {
                    return
                }

                self.pendingRecoveryWriteTasks[taskID] = nil

                if !Task.isCancelled {
                    self.present(error)
                }
            }
        }
    }

    func clearCurrentRecoveryPendingState() {
        guard let currentRecoverySessionID else {
            refreshPendingRecoverySession()
            return
        }

        do {
            try recoveryStore.clearPendingRecovery(for: currentRecoverySessionID)
            refreshPendingRecoverySession()
        } catch {
            present(error)
        }
    }

    func refreshHistoryEntries() {
        refreshRecoveryPresentationState()
    }

    func refreshPendingRecoverySession() {
        refreshRecoveryPresentationState()
    }

    func refreshRecentSnipEntries() {
        refreshRecoveryPresentationState()
    }

    func restoreRecycledHistoryEntry(_ entry: DocumentHistoryEntry) {
        performAfterHandlingUnsavedChanges { [weak self] in
            guard let self else {
                return
            }

            do {
                try self.recoveryStore.restoreRecycledHistoryEntry(entry)
                self.restoreHistoryEntryImmediately(entry)
                self.refreshHistoryEntries()
            } catch {
                self.present(error)
            }
        }
    }

    func permanentlyDeleteRecycledHistoryEntry(_ entry: DocumentHistoryEntry) {
        do {
            try recoveryStore.permanentlyDeleteRecycledHistoryEntry(entry)
            refreshHistoryEntries()
            triggerArchiveMaintenance()
        } catch {
            present(error)
        }
    }

    func emptyRecycleBin() {
        do {
            try recoveryStore.emptyRecycleBin()
            refreshHistoryEntries()
            triggerArchiveMaintenance()
        } catch {
            present(error)
        }
    }
}

struct AutosaveState: Equatable {
    let documentURL: URL?
    let cropRect: CGRect
    let annotations: [Annotation]
    let toolStyles: [EditorTool: AnnotationStyle]

    init(controller: EditorController, documentURL: URL?) {
        self.documentURL = documentURL
        cropRect = controller.snapshot.cropRect
        annotations = controller.snapshot.annotations
        toolStyles = controller.toolStyles
    }
}

nonisolated private struct RecoveryCheckpointWritePayload: @unchecked Sendable {
    let store: DocumentRecoveryStore
    let sessionID: UUID
    let title: String
    let sourceDocumentURL: URL?
    let label: String
    let document: EditableScreenshotDocument
    let renderInput: ExportRenderInput
    let pendingRecovery: Bool
    let hasUnsavedChanges: Bool
}

nonisolated private struct RecoveryPresentationRefreshRequest: @unchecked Sendable {
    let store: DocumentRecoveryStore
    let currentSessionID: UUID?
    let captureHistoryLimit: Int
    let recentSnipLimit: Int
    let recycleBinLimit: Int
}

nonisolated private enum RecoveryPresentationStateLoader {
    static func load(_ request: RecoveryPresentationRefreshRequest) async -> RecoveryPresentationState {
        let task = Task.detached(priority: .utility) { () -> RecoveryPresentationState in
            if Task.isCancelled {
                return RecoveryPresentationState(
                    historyEntries: [],
                    allCaptureHistoryEntries: [],
                    recentSnipEntries: [],
                    recycleBinEntries: [],
                    pendingRecoverySession: nil
                )
            }

            return request.store.presentationState(
                currentSessionID: request.currentSessionID,
                captureHistoryLimit: request.captureHistoryLimit,
                recentSnipLimit: request.recentSnipLimit,
                recycleBinLimit: request.recycleBinLimit
            )
        }

        return await withTaskCancellationHandler(operation: {
            await task.value
        }, onCancel: {
            task.cancel()
        })
    }
}

nonisolated private enum RecoveryCheckpointWriter {
    static func save(_ payload: RecoveryCheckpointWritePayload) async throws {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()

            guard let previewImage = EditorRenderer.render(
                baseImage: payload.renderInput.baseImage,
                snapshot: payload.renderInput.snapshot
            ) else {
                throw ImageExportError.encodingFailed
            }

            try Task.checkCancellation()

            try payload.store.saveCheckpoint(
                sessionID: payload.sessionID,
                title: payload.title,
                sourceDocumentURL: payload.sourceDocumentURL,
                label: payload.label,
                document: payload.document,
                previewImage: previewImage,
                pendingRecovery: payload.pendingRecovery,
                hasUnsavedChanges: payload.hasUnsavedChanges
            )
        }

        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
