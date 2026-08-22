import Foundation

extension DocumentWorkflowModel {
    var pendingRecoveryWriteTasks: [UUID: Task<Bool, Never>] {
        get { recoveryOperations.pendingTasks }
        set { recoveryOperations.pendingTasks = newValue }
    }

    var recoveryWriteTail: Task<Bool, Never>? {
        get { recoveryOperations.tail }
        set { recoveryOperations.tail = newValue }
    }

    var recoveryOperationIDsRequiredForConsistency: Set<UUID> {
        get { recoveryOperations.requiredOperationIDs }
        set { recoveryOperations.requiredOperationIDs = newValue }
    }

    var lastEnqueuedRecoveryState: AutosaveState? {
        get { recoveryOperations.lastEnqueuedState }
        set { recoveryOperations.lastEnqueuedState = newValue }
    }

    var recoverySessionsWithPendingClearEnqueued: Set<UUID> {
        get { recoveryOperations.pendingClearSessionIDs }
        set { recoveryOperations.pendingClearSessionIDs = newValue }
    }

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

        clearRecoveryPendingState(for: pendingRecoverySession.id)
    }

    func restoreHistoryEntry(_ entry: DocumentHistoryEntry) {
        historyPreviewCoordinator.close()
        performAfterHandlingUnsavedChanges { [weak self] in
            self?.restoreHistoryEntryImmediately(entry)
        }
    }

    func restoreRecentSnipEntry(_ entry: DocumentHistoryEntry) {
        historyPreviewCoordinator.close()
        shelveCurrentDocumentForRecents()
        restoreHistoryEntryImmediately(entry, clearPendingRecovery: false)
    }

    func deleteHistoryEntry(_ entry: DocumentHistoryEntry) {
        let store = recoveryStore
        enqueueRecoveryOperation(
            mustComplete: true,
            operation: {
                try await RecoveryCheckpointWriter.performStoreMutation {
                    try store.deleteHistoryEntry(entry)
                }
            },
            onSuccess: { model in
                model.refreshHistoryEntries()
                model.triggerArchiveMaintenance()
            }
        )
    }

    func deleteCaptureHistorySession(_ entry: DocumentHistoryEntry) {
        deleteRecoverySession(entry.sessionID)
    }

    func deleteAllHistoryEntries() {
        guard let currentRecoverySessionID else {
            return
        }

        let store = recoveryStore
        enqueueRecoveryOperation(
            mustComplete: true,
            operation: {
                try await RecoveryCheckpointWriter.performStoreMutation {
                    try store.deleteHistoryEntries(for: currentRecoverySessionID)
                }
            },
            onSuccess: { model in
                model.refreshHistoryEntries()
                model.triggerArchiveMaintenance()
            }
        )
    }

    func deleteRecentSnipEntry(_ entry: DocumentHistoryEntry) {
        deleteRecoverySession(entry.sessionID)
    }

    func deleteAllRecentSnipEntries() {
        let store = recoveryStore
        let excludedSessionID = currentRecoverySessionID
        enqueueRecoveryOperation(
            mustComplete: true,
            operation: {
                try await RecoveryCheckpointWriter.performStoreMutation {
                    try store.deletePendingRecoverySessions(excluding: excludedSessionID)
                }
            },
            onSuccess: { model in
                model.refreshHistoryEntries()
                model.triggerArchiveMaintenance()
            }
        )
    }

    private func deleteRecoverySession(_ sessionID: UUID) {
        let store = recoveryStore
        enqueueRecoveryOperation(
            mustComplete: true,
            operation: {
                try await RecoveryCheckpointWriter.performStoreMutation {
                    try store.deleteSession(sessionID)
                }
            },
            onSuccess: { model in
                model.recoverySessionsWithPendingClearEnqueued.remove(sessionID)
                model.refreshHistoryEntries()
                model.triggerArchiveMaintenance()
            }
        )
    }

    func restoreHistoryEntryImmediately(_ entry: DocumentHistoryEntry, clearPendingRecovery: Bool = true) {
        do {
            let document = try recoveryStore.restoreDocument(from: entry)
            let controller = EditorController(
                capture: document.capture,
                session: document.session,
                capabilities: capabilities,
                uiMapOverlayOptions: uiMapPinnedOverlayDefaults,
                isPrivateDocument: document.isPrivate,
                workflowResumeState: document.workflowResumeState,
                sourceDocumentFormatVersion: document.sourceFormatVersion,
                compositionStoredAssets: document.compositionStoredAssets
            )
            controller.restoreWorkflowWorkspace()
            installEditorController(
                controller,
                documentURL: entry.sourceDocumentURL,
                savedSession: nil,
                recoverySessionID: entry.sessionID
            )
            if clearPendingRecovery {
                clearRecoveryPendingState(for: entry.sessionID)
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
            captureHistoryLimit: DocumentWorkflowConstants.captureHistoryLimit,
            recentSnipLimit: DocumentWorkflowConstants.recentSnipLimit,
            recycleBinLimit: DocumentWorkflowConstants.recycleBinLimit
        )

        pendingRecoveryRefreshTask = Task { @MainActor [weak self] in
            let state = await RecoveryPresentationStateLoader.load(request)

            guard let self, !Task.isCancelled, self.recoveryRefreshGeneration == generation else {
                return
            }

            self.pendingRecoveryRefreshTask = nil
            self.historyEntries = state.historyEntries
            self.allCaptureHistoryEntries = state.allCaptureHistoryEntries
            self.snipLibraryEntries =
                DocumentHistoryEntrySelection.latestPerSession(
                    from: state.allCaptureHistoryEntries
                )
            self.recentSnipEntries = state.recentSnipEntries
            self.recycleBinEntries = state.recycleBinEntries
            self.pendingRecoverySession = state.pendingRecoverySession
            self.scheduleIndexedCaptureHistorySearch()
        }
    }

    func scheduleAutosave(for controller: EditorController) {
        pendingAutosaveTask?.cancel()

        guard !isInteractiveCaptureAutosaveSuspended else {
            pendingAutosaveTask = nil
            return
        }

        guard shouldAutosave(for: controller) else {
            pendingAutosaveTask = nil
            return
        }

        let pendingState = AutosaveState(controller: controller, documentURL: currentDocumentURL)

        guard pendingState != lastAutosavedState,
              pendingState != lastEnqueuedRecoveryState else {
            return
        }

        pendingAutosaveTask = Task { @MainActor [weak self, weak controller] in
            do {
                try await self?.systemServices.scheduler.sleep(nanoseconds: DocumentWorkflowConstants.autosaveDebounceNanoseconds)
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

            guard currentState != self.lastAutosavedState,
                  currentState != self.lastEnqueuedRecoveryState else {
                self.pendingAutosaveTask = nil
                return
            }

            self.recordRecoveryCheckpoint(for: controller, label: "Autosave", pendingRecovery: self.hasUnsavedChanges)
            self.pendingAutosaveTask = nil
        }
    }

    func shouldAutosave(for controller: EditorController) -> Bool {
        !controller.isPrivateDocument
            && (currentDocumentURL == nil || AutosaveState(controller: controller, documentURL: currentDocumentURL) != savedEditorAutosaveState)
    }

    func suspendAutosaveForInteractiveCapture() -> InteractiveCaptureAutosaveSuspension {
        let suspension = InteractiveCaptureAutosaveSuspension(
            editorControllerID: editorController.map(ObjectIdentifier.init)
        )
        pendingAutosaveTask?.cancel()
        pendingAutosaveTask = nil
        return suspension
    }

    func resumeAutosaveAfterInteractiveCapture(_ suspension: InteractiveCaptureAutosaveSuspension) {
        guard let controller = editorController,
              suspension.editorControllerID == ObjectIdentifier(controller),
              shouldAutosave(for: controller) else {
            return
        }

        scheduleAutosave(for: controller)
    }

    func prepareForArchiveClear() async {
        pendingAutosaveTask?.cancel()
        pendingAutosaveTask = nil

        let pendingWriteTasks = Array(pendingRecoveryWriteTasks.values)
        pendingRecoveryWriteTasks.removeAll()
        pendingWriteTasks.forEach { $0.cancel() }

        for task in pendingWriteTasks {
            _ = await task.value
        }

        recoveryWriteTail = nil
        recoveryOperationIDsRequiredForConsistency.removeAll()
        lastEnqueuedRecoveryState = nil
        recoverySessionsWithPendingClearEnqueued.removeAll()
    }

    func prepareForApplicationExit() async -> Bool {
        guard await writeVideoRecoveryCheckpointIfNeeded() else {
            return false
        }

        pendingAutosaveTask?.cancel()
        pendingAutosaveTask = nil

        if let controller = editorController,
           currentRecoverySessionID != nil,
           shouldAutosave(for: controller) {
            controller.commitPendingTextEdits()
            updateDocumentChangeTracking()

            let state = AutosaveState(controller: controller, documentURL: currentDocumentURL)
            if state != lastAutosavedState, state != lastEnqueuedRecoveryState {
                recordRecoveryCheckpoint(
                    for: controller,
                    label: "Autosave",
                    pendingRecovery: hasUnsavedChanges
                )
            }
        }

        let pendingWriteTasks = Array(pendingRecoveryWriteTasks.values)
        var allWritesSucceeded = true
        for task in pendingWriteTasks {
            if await task.value == false {
                allWritesSucceeded = false
            }
        }
        return allWritesSucceeded
    }

    func rebindRecoveryStore(_ store: DocumentRecoveryStore) {
        pendingAutosaveTask?.cancel()
        pendingAutosaveTask = nil
        pendingRecoveryRefreshTask?.cancel()
        pendingRecoveryRefreshTask = nil
        pendingCaptureHistorySearchTask?.cancel()
        pendingCaptureHistorySearchTask = nil
        for (taskID, task) in pendingRecoveryWriteTasks
        where !recoveryOperationIDsRequiredForConsistency.contains(taskID) {
            task.cancel()
        }
        lastAutosavedState = nil
        lastEnqueuedRecoveryState = nil
        recoverySessionsWithPendingClearEnqueued.removeAll()
        recoveryStore = store
    }

    func reseedRecoverySessionAfterArchiveChange() {
        guard let controller = editorController else {
            currentRecoverySessionID = nil
            refreshRecoveryPresentationState()
            return
        }
        guard !controller.isPrivateDocument else {
            currentRecoverySessionID = nil
            refreshRecoveryPresentationState()
            return
        }

        currentRecoverySessionID = createRecoverySessionIfNeeded(for: controller, documentURL: currentDocumentURL)
        refreshRecoveryPresentationState()
        recordRecoveryCheckpoint(for: controller, label: hasUnsavedChanges ? "Autosave" : "Saved", pendingRecovery: hasUnsavedChanges)
    }

    func recordRecoveryCheckpoint(for controller: EditorController, label: String, pendingRecovery: Bool) {
        guard !controller.isPrivateDocument, let currentRecoverySessionID else {
            return
        }

        controller.commitPendingTextEdits()

        let taskID = systemServices.ids.uuid()
        let controllerID = ObjectIdentifier(controller)
        let autosaveState = AutosaveState(controller: controller, documentURL: currentDocumentURL)
        let payload = RecoveryCheckpointWritePayload(
            store: recoveryStore,
            sessionID: currentRecoverySessionID,
            title: recoverySessionTitle(for: controller, documentURL: currentDocumentURL),
            sourceDocumentURL: currentDocumentURL,
            label: label,
            document: controller.editableDocument,
            renderInput: controller.compositionDocumentPreviewInput(),
            pendingRecovery: pendingRecovery,
            hasUnsavedChanges: hasUnsavedChanges,
            includeUIMapSearchText: windowUIMapEnabled
        )

        lastEnqueuedRecoveryState = autosaveState
        if pendingRecovery {
            recoverySessionsWithPendingClearEnqueued.remove(currentRecoverySessionID)
        }

        enqueueRecoveryOperation(
            taskID: taskID,
            operation: {
                try await RecoveryCheckpointWriter.save(payload)
            },
            onSuccess: { [weak controller] model in
                let isCurrentController = model.editorController.map { ObjectIdentifier($0) } == controllerID

                if isCurrentController {
                    model.lastAutosavedState = autosaveState
                }

                if !pendingRecovery {
                    model.recoverySessionsWithPendingClearEnqueued.insert(currentRecoverySessionID)
                }

                model.refreshRecoveryPresentationState()
                model.triggerArchiveMaintenance()

                if label == "Capture", isCurrentController, let controller {
                    model.indexCurrentCaptureIfNeeded(using: controller)
                }
            },
            onFailure: { model in
                if model.lastEnqueuedRecoveryState == autosaveState {
                    model.lastEnqueuedRecoveryState = nil
                }
            }
        )
    }

    @discardableResult
    func enqueueRecoveryOperation(
        taskID: UUID? = nil,
        mustComplete: Bool = false,
        operation: @escaping @MainActor () async throws -> Void,
        onSuccess: @escaping @MainActor (DocumentWorkflowModel) -> Void = { _ in },
        onFailure: @escaping @MainActor (DocumentWorkflowModel) -> Void = { _ in }
    ) -> Task<Bool, Never> {
        let resolvedTaskID = taskID ?? systemServices.ids.uuid()
        let predecessor = recoveryWriteTail
        let task = Task { @MainActor [weak self] in
            if let predecessor {
                _ = await predecessor.value
            }

            guard let self else {
                return false
            }
            defer {
                self.pendingRecoveryWriteTasks[resolvedTaskID] = nil
                self.recoveryOperationIDsRequiredForConsistency.remove(resolvedTaskID)
            }

            do {
                try Task.checkCancellation()
                try await operation()
                try Task.checkCancellation()
                onSuccess(self)
                return true
            } catch is CancellationError {
                onFailure(self)
                return true
            } catch {
                onFailure(self)
                self.present(error)
                return false
            }
        }

        pendingRecoveryWriteTasks[resolvedTaskID] = task
        if mustComplete {
            recoveryOperationIDsRequiredForConsistency.insert(resolvedTaskID)
        }
        recoveryWriteTail = task
        return task
    }

    func clearCurrentRecoveryPendingState() {
        guard let currentRecoverySessionID else {
            refreshPendingRecoverySession()
            return
        }

        clearRecoveryPendingState(for: currentRecoverySessionID)
    }

    func excludeCurrentPrivateDocumentFromRecoveryAndHistory() {
        pendingAutosaveTask?.cancel()
        pendingAutosaveTask = nil
        pendingRecoveryRefreshTask?.cancel()
        pendingRecoveryRefreshTask = nil
        pendingCaptureHistorySearchTask?.cancel()
        pendingCaptureHistorySearchTask = nil
        captureHistorySearchGeneration += 1
        recoveryRefreshGeneration += 1
        textRecognitionCoordinator.cancelAll()
        cancelPendingAutoCopy()

        guard let sessionID = currentRecoverySessionID else {
            pendingRecoverySession = nil
            refreshRecoveryPresentationState()
            return
        }

        // Publish the privacy boundary synchronously before canceling task
        // handles. A detached checkpoint writer may already be inside package
        // encoding and must observe this mark at its manifest commit boundary.
        recoveryStore.registerPrivacyExclusion(for: sessionID)
        pendingRecoveryWriteTasks.values.forEach { $0.cancel() }
        pendingRecoveryWriteTasks.removeAll()
        recoveryWriteTail = nil
        recoveryOperationIDsRequiredForConsistency.removeAll()
        currentRecoverySessionID = nil
        lastAutosavedState = nil
        lastEnqueuedRecoveryState = nil
        pendingRecoverySession = nil
        historyEntries.removeAll { $0.sessionID == sessionID }
        allCaptureHistoryEntries.removeAll { $0.sessionID == sessionID }
        snipLibraryEntries.removeAll { $0.sessionID == sessionID }
        recentSnipEntries.removeAll { $0.sessionID == sessionID }
        recycleBinEntries.removeAll { $0.sessionID == sessionID }
        let store = recoveryStore
        enqueueRecoveryOperation(
            mustComplete: true,
            operation: {
                try await RecoveryCheckpointWriter.performStoreMutation {
                    try store.excludeSessionFromPresentation(sessionID)
                }
            },
            onSuccess: { model in
                model.recoverySessionsWithPendingClearEnqueued.remove(sessionID)
                model.refreshRecoveryPresentationState()
            },
            onFailure: { model in
                model.refreshRecoveryPresentationState()
            }
        )
    }

    func clearRecoveryPendingState(for sessionID: UUID) {
        guard recoverySessionsWithPendingClearEnqueued.insert(sessionID).inserted else {
            return
        }

        let store = recoveryStore
        enqueueRecoveryOperation(
            mustComplete: true,
            operation: {
                try await RecoveryCheckpointWriter.clearPendingRecovery(
                    for: sessionID,
                    in: store
                )
            },
            onSuccess: { model in
                model.refreshPendingRecoverySession()
                if model.currentRecoverySessionID != sessionID {
                    model.recoverySessionsWithPendingClearEnqueued.remove(sessionID)
                }
            },
            onFailure: { model in
                model.recoverySessionsWithPendingClearEnqueued.remove(sessionID)
            }
        )
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
        historyPreviewCoordinator.close()
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
    let controllerID: ObjectIdentifier
    let documentURL: URL?
    private let content: PersistedEditorContentFingerprint

    var cropRect: CGRect { content.snapshot.cropRect }
    var annotations: [Annotation] { content.snapshot.annotations }
    var nextCalloutNumber: Int { content.snapshot.nextCalloutNumber }
    var presentation: ScreenshotPresentation { content.snapshot.presentation }
    var pinnedUIMapElementIDs: [UUID] {
        content.snapshot.pinnedUIMapElementIDs
    }
    var toolStyles: [EditorTool: AnnotationStyle] { content.toolStyles }
    var savedPresentations: [SavedPresentation] {
        content.savedPresentations
    }

    init(controller: EditorController, documentURL: URL?) {
        controllerID = ObjectIdentifier(controller)
        self.documentURL = documentURL
        content = PersistedEditorContentFingerprint(controller: controller)
    }
}

/// Exact process-local representation of content written to `.sss`. It
/// deliberately strips focus/selection state while retaining the complete
/// composition, document purpose, Presentation configuration, reusable
/// styles, privacy provenance, and immutable source revisions.
private struct PersistedEditorContentFingerprint: Equatable {
    let snapshot: EditorSnapshot
    let toolStyles: [EditorTool: AnnotationStyle]
    let savedPresentations: [SavedPresentation]
    let compositionAssets: [CompositionStoredAsset]
    let isPrivate: Bool

    init(controller: EditorController) {
        var persistedSnapshot = controller.documentSession.currentSnapshot
        persistedSnapshot.selectedAnnotationIDs = []
        if var composition = persistedSnapshot.composition {
            composition.selectedItemIDs = []
            composition.canvas.selectedAnnotationIDs = []
            for index in composition.items.indices {
                composition.items[index].editState.selectedAnnotationIDs = []
            }
            persistedSnapshot.composition = composition
        }

        snapshot = persistedSnapshot
        toolStyles = controller.toolStyles
        savedPresentations = controller.savedPresentations
        let currentAssetIDs = Set(
            persistedSnapshot.composition?.items.map(\.assetID) ?? []
        )
        compositionAssets = controller.compositionAssetRepository.storedAssets(
            referencedBy: currentAssetIDs
        )
        isPrivate = controller.isPrivateDocument
    }
}

struct RecoveryOperationState {
    var pendingTasks: [UUID: Task<Bool, Never>] = [:]
    var tail: Task<Bool, Never>?
    var requiredOperationIDs: Set<UUID> = []
    var lastEnqueuedState: AutosaveState?
    var pendingClearSessionIDs: Set<UUID> = []
}

nonisolated private struct RecoveryCheckpointWritePayload: @unchecked Sendable {
    let store: DocumentRecoveryStore
    let sessionID: UUID
    let title: String
    let sourceDocumentURL: URL?
    let label: String
    let document: EditableScreenshotDocument
    let renderInput: CompositionDocumentPreviewInput
    let pendingRecovery: Bool
    let hasUnsavedChanges: Bool
    let includeUIMapSearchText: Bool
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

            let previewImage = try CompositionDocumentPreviewRenderer.render(
                payload.renderInput
            )

            try Task.checkCancellation()

            try payload.store.saveCheckpoint(
                sessionID: payload.sessionID,
                title: payload.title,
                sourceDocumentURL: payload.sourceDocumentURL,
                label: payload.label,
                document: payload.document,
                previewImage: previewImage,
                pendingRecovery: payload.pendingRecovery,
                hasUnsavedChanges: payload.hasUnsavedChanges,
                includeUIMapSearchText: payload.includeUIMapSearchText
            )
        }

        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func clearPendingRecovery(for sessionID: UUID, in store: DocumentRecoveryStore) async throws {
        try await performStoreMutation {
            try store.clearPendingRecovery(for: sessionID)
        }
    }

    static func performStoreMutation(_ mutation: @escaping @Sendable () throws -> Void) async throws {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            try mutation()
        }

        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
