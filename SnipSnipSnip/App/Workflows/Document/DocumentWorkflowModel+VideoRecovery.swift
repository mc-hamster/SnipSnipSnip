import Foundation

struct VideoRecoveryWorkflowState {
    let store: VideoRecoveryStore
    var hasRecovery: Bool
    var isRecovering = false
    var ownsCurrentVideo = false

    init(store: VideoRecoveryStore) {
        self.store = store
        self.hasRecovery = store.hasRecovery()
    }
}

@MainActor
extension DocumentWorkflowModel {
    var videoRecoveryStore: VideoRecoveryStore { videoRecoveryState.store }
    var hasRecoverableVideo: Bool {
        get { videoRecoveryState.hasRecovery }
        set { videoRecoveryState.hasRecovery = newValue }
    }
    var isRecoveringVideo: Bool {
        get { videoRecoveryState.isRecovering }
        set { videoRecoveryState.isRecovering = newValue }
    }
    var currentVideoUsesRecoveryCheckpoint: Bool {
        get { videoRecoveryState.ownsCurrentVideo }
        set { videoRecoveryState.ownsCurrentVideo = newValue }
    }

    func prepareForNewVideoRecording() async -> Bool {
        guard (editorController != nil || videoEditorController != nil || guideEditorController != nil),
              hasUnsavedChanges else {
            return true
        }

        return await withCheckedContinuation { continuation in
            pendingEditorAction = { continuation.resume(returning: true) }
            pendingEditorCancellation = { continuation.resume(returning: false) }
            isShowingUnsavedChangesPrompt = true
            requestMainWindowPresentation()
        }
    }

    func recoverLastVideoSession() {
        guard editorController == nil,
              videoEditorController == nil,
              guideEditorController == nil,
              !isRecoveringVideo else { return }

        isRecoveringVideo = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isRecoveringVideo = false }
            do {
                guard let document = try await VideoRecoveryWorker.load(from: videoRecoveryStore) else {
                    hasRecoverableVideo = false
                    return
                }
                let controller = VideoEditorController(
                    recording: document.recording,
                    session: document.session,
                    posterImage: nil
                )
                installVideoController(controller, documentURL: nil, savedSession: nil)
                currentVideoUsesRecoveryCheckpoint = true
                requestMainWindowPresentation()
            } catch {
                present(error)
            }
        }
    }

    func discardRecoverableVideo() {
        guard !isRecoveringVideo else { return }
        videoRecoveryStore.remove()
        hasRecoverableVideo = false
        currentVideoUsesRecoveryCheckpoint = false
    }

    func writeVideoRecoveryCheckpointIfNeeded() async -> Bool {
        guard let controller = videoEditorController, hasUnsavedChanges else { return true }
        let document = EditableVideoDocument(
            recording: controller.recording,
            session: controller.documentSession
        )
        do {
            try await VideoRecoveryWorker.save(document, to: videoRecoveryStore)
            hasRecoverableVideo = true
            currentVideoUsesRecoveryCheckpoint = true
            return true
        } catch {
            present(error)
            return false
        }
    }

    func clearVideoRecoveryAfterSaveOrDiscard() {
        guard currentVideoUsesRecoveryCheckpoint else { return }
        videoRecoveryStore.remove()
        hasRecoverableVideo = false
        currentVideoUsesRecoveryCheckpoint = false
    }

    func completeVideoRecoveryAfterSave(_ wasRecoveryCheckpointVideo: Bool) {
        guard wasRecoveryCheckpointVideo else { return }
        currentVideoUsesRecoveryCheckpoint = true
        clearVideoRecoveryAfterSaveOrDiscard()
    }
}

nonisolated private struct VideoRecoveryPayload: @unchecked Sendable {
    let document: EditableVideoDocument
    let store: VideoRecoveryStore
}

nonisolated private enum VideoRecoveryWorker {
    static func save(_ document: EditableVideoDocument, to store: VideoRecoveryStore) async throws {
        let payload = VideoRecoveryPayload(document: document, store: store)
        try await Task.detached(priority: .utility) {
            try payload.store.save(payload.document)
        }.value
    }

    static func load(from store: VideoRecoveryStore) async throws -> EditableVideoDocument? {
        try await Task.detached(priority: .utility) { try store.load() }.value
    }
}
