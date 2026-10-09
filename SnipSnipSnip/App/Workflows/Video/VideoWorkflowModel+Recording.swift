import AppKit
import Foundation

struct ActiveVideoRecording {
    let generation: UUID
    let session: ScreenRecordingSession
    let overlay: RecordingControlOverlay
    let hiddenWindow: AppWindowVisibilityToken?
}

struct VideoRecordingAudioOptions: Equatable, Sendable {
    let recordsSystemAudio: Bool
    let recordsMicrophone: Bool
}

@MainActor
extension VideoWorkflowModel {
    var isRecording: Bool {
        activeVideoRecording != nil
    }

    var blocksNewCapture: Bool {
        recordingLifecycle.blocksNewCapture
    }

    var defaultExportRequest: VideoExportRequest {
        VideoExportRequest(format: .mp4, target: exportPreferences.target)
    }

    func recordCurrentDisplay() {
        recordCurrentDisplay(presentationContext: .application)
    }

    func recordCurrentDisplay(
        presentationContext: WorkflowPresentationContext
    ) {
        reserveAndPrepareRecording(source: .screen) { [weak self] generation in
            await self?.beginFullscreenVideoRecording(
                generation: generation,
                presentationContext: presentationContext
            )
        }
    }

    func recordRegion() {
        recordRegion(presentationContext: .application)
    }

    func recordRegion(
        presentationContext: WorkflowPresentationContext
    ) {
        reserveAndPrepareRecording(source: .region) { [weak self] generation in
            await self?.beginRegionVideoRecording(
                generation: generation,
                presentationContext: presentationContext
            )
        }
    }

    func recordWindowOnScreen(
        presentationContext: WorkflowPresentationContext
    ) {
        reserveAndPrepareRecording(source: .window) { [weak self] generation in
            guard let self else { return }
            await beginWindowOnScreenVideoRecording(
                generation: generation,
                windows: dependencies.capture.availableWindows,
                presentationContext: presentationContext
            )
        }
    }

    func presentVideoWindowPicker() {
        reserveAndPrepareRecording(source: .window) { [weak self] generation in
            await self?.beginVideoWindowPicker(generation: generation)
        }
    }

    private func beginVideoWindowPicker(generation: UUID) async {
        guard isCurrentPreparingGeneration(generation), !Task.isCancelled else { return }
        pendingWindowPickerGeneration = generation
        do {
            try await dependencies.capture.beginVideoWindowSelection()
        } catch {
            guard isCurrentPreparingGeneration(generation) else { return }
            dependencies.capture.dismissWindowPicker()
            failPreparingRecording(generation: generation, error: error)
        }
    }

    func recordWindow(_ window: CaptureWindowSummary) {
        dependencies.capture.dismissWindowPicker()
        guard let generation = pendingWindowPickerGeneration,
              recordingLifecycle.generation == generation else {
            return
        }
        pendingWindowPickerGeneration = nil
        pendingRecordingOperation = { [weak self] generation in
            await self?.beginWindowVideoRecording(window, generation: generation)
        }
        recordingStartTask = Task { @MainActor [weak self] in
            await self?.beginWindowVideoRecording(window, generation: generation)
        }
    }

    func cancelPendingVideoRecording() {
        guard recordingLifecycle.phase == .preparing,
              let generation = recordingLifecycle.generation else { return }
        recordingStartTask?.cancel()
        recordingStartTask = nil
        if pendingWindowPickerGeneration != nil { dependencies.capture.dismissWindowPicker() }
        pendingWindowPickerGeneration = nil
        pendingRecordingOperation = nil
        preparedRecordingPreferences = nil
        recordingLifecycle.reset(generation: generation)
    }

    func pickWindowOnScreenForVideoRecording() {
        guard let generation = pendingWindowPickerGeneration,
              recordingLifecycle.generation == generation else { return }

        let windows = dependencies.capture.availableWindows
        pendingWindowPickerGeneration = nil
        dependencies.capture.dismissWindowPicker()

        recordingStartTask = Task { @MainActor [weak self] in
            await self?.beginWindowOnScreenVideoRecording(
                generation: generation,
                windows: windows,
                presentationContext: .application
            )
        }
    }

    private func beginWindowOnScreenVideoRecording(
        generation: UUID,
        windows: [CaptureWindowSummary],
        presentationContext: WorkflowPresentationContext
    ) async {
        _ = dependencies.capture.beginCapturePrivacyLock()
        defer { dependencies.capture.endCapturePrivacyLock() }
        let hiddenWindow = hideAppWindowIfNeeded(for: presentationContext)

        if hiddenWindow != nil {
            try? await dependencies.systemServices.scheduler.sleep(
                nanoseconds: 200_000_000
            )
        }

        guard isCurrentPreparingGeneration(generation), !Task.isCancelled else {
            restoreAppWindowIfNeeded(hiddenWindow)
            return
        }

        guard verifyPreparedRecordingAccess(generation: generation, hiddenWindow: hiddenWindow) else { return }

        do {
            let selectedWindow = try await dependencies.capture
                .performVideoWork(message: "Pick Window") {
                    let selection = try await dependencies.capture
                        .videoWindowSelectionSnapshot()
                    let session = WindowSelectionSession(
                        snapshot: selection.snapshot,
                        windows: selection.windows,
                        prompt: .video
                    )
                    return await session.begin()
                }

            guard let selectedWindow,
                  isCurrentPreparingGeneration(generation),
                  !Task.isCancelled else {
                failPreparingRecording(
                    generation: generation,
                    hiddenWindow: hiddenWindow
                )
                return
            }
            restoreAppWindowIfNeeded(hiddenWindow)
            await beginWindowVideoRecording(
                selectedWindow,
                generation: generation
            )
        } catch {
            failPreparingRecording(
                generation: generation,
                hiddenWindow: hiddenWindow,
                error: error
            )
        }
    }

    func resumeRecordingAfterPermissionRestart(source: PermissionRestartVideoSource, preferences: VideoRecordingPreferences) {
        reserveAndPrepareRecording(source: source, preferences: preferences) { [weak self] generation in
            guard let self else { return }
            switch source {
            case .screen: await beginFullscreenVideoRecording(generation: generation, presentationContext: .application)
            case .region: await beginRegionVideoRecording(generation: generation, presentationContext: .application)
            case .window:
                await beginVideoWindowPicker(generation: generation)
            }
        }
    }

    func stopVideoRecording() {
        guard let activeVideoRecording,
              recordingLifecycle.transition(to: .finishing, generation: activeVideoRecording.generation) else {
            return
        }

        stopVideoStorageMonitor()
        activeVideoRecording.overlay.updatePhase(.finishing, commandInFlight: true)
        let previous = recordingCommandTail
        let task = Task { @MainActor [weak self] in
            _ = await previous?.value
            _ = await self?.finishRecording(activeVideoRecording, unexpectedError: nil)
        }
        recordingCommandTail = task
    }

    func toggleVideoRecordingPauseResume() {
        switch recordingLifecycle.phase {
        case .recording:
            pauseVideoRecording()
        case .paused:
            resumeVideoRecording()
        default:
            return
        }
    }

    func pauseVideoRecording() {
        guard let active = activeVideoRecording,
              recordingLifecycle.phase == .recording,
              !recordingLifecycle.isCommandInFlight else { return }

        recordingLifecycle.setCommandInFlight(true, generation: active.generation)
        active.overlay.updatePhase(.recording, commandInFlight: true)
        let previous = recordingCommandTail
        let task = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self,
                  recordingLifecycle.phase == .recording,
                  self.activeVideoRecording?.session === active.session else { return }
            do {
                try await active.session.pause()
                guard recordingLifecycle.transition(to: .paused, generation: active.generation) else { return }
                recordingLifecycle.setCommandInFlight(false, generation: active.generation)
                active.overlay.updatePhase(.paused, commandInFlight: false)
                dependencies.lifecycle.updateWorkingMessage(WorkflowVocabulary.Status.videoPaused)
            } catch {
                if recordingLifecycle.phase == .recording {
                    recordingLifecycle.setCommandInFlight(false, generation: active.generation)
                    active.overlay.updatePhase(.recording, commandInFlight: false)
                    present(error)
                }
            }
        }
        recordingCommandTail = task
    }

    func resumeVideoRecording() {
        guard let active = activeVideoRecording,
              recordingLifecycle.phase == .paused,
              !recordingLifecycle.isCommandInFlight else { return }

        recordingLifecycle.setCommandInFlight(true, generation: active.generation)
        active.overlay.updatePhase(.paused, commandInFlight: true)
        let previous = recordingCommandTail
        let task = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self,
                  recordingLifecycle.phase == .paused,
                  self.activeVideoRecording?.session === active.session else { return }
            do {
                try await active.session.resume()
                guard recordingLifecycle.transition(to: .recording, generation: active.generation) else { return }
                recordingLifecycle.setCommandInFlight(false, generation: active.generation)
                active.overlay.updatePhase(.recording, commandInFlight: false)
                dependencies.lifecycle.updateWorkingMessage(WorkflowVocabulary.Status.videoRecording)
            } catch {
                if recordingLifecycle.phase == .paused {
                    recordingLifecycle.setCommandInFlight(false, generation: active.generation)
                    active.overlay.updatePhase(.paused, commandInFlight: false)
                    present(error)
                }
            }
        }
        recordingCommandTail = task
    }

    func updateVideoAudioOptions(
        recordsSystemAudio: Bool,
        recordsMicrophone: Bool
    ) async throws {
        guard let active = activeVideoRecording else {
            throw CancellationError()
        }
        let requested = VideoRecordingAudioOptions(
            recordsSystemAudio: recordsSystemAudio,
            recordsMicrophone: recordsMicrophone
        )
        desiredVideoAudioOptions = requested
        recordingLifecycle.setCommandInFlight(true, generation: active.generation)
        active.overlay.updatePhase(recordingLifecycle.phase, commandInFlight: true)

        let previous = recordingCommandTail
        let operation = Task<Result<Void, Error>, Never> { @MainActor [weak self] in
            _ = await previous?.value
            guard let self,
                  desiredVideoAudioOptions == requested,
                  recordingLifecycle.phase == .recording || recordingLifecycle.phase == .paused,
                  self.activeVideoRecording?.session === active.session else {
                return .success(())
            }
            do {
                try await active.session.updateAudioOptions(
                    recordsSystemAudio: requested.recordsSystemAudio,
                    recordsMicrophone: requested.recordsMicrophone
                )
                if desiredVideoAudioOptions == requested {
                    recordingLifecycle.setCommandInFlight(false, generation: active.generation)
                    active.overlay.updatePhase(recordingLifecycle.phase, commandInFlight: false)
                }
                return .success(())
            } catch {
                guard recordingLifecycle.phase == .recording || recordingLifecycle.phase == .paused else {
                    return .success(())
                }
                recordingLifecycle.setCommandInFlight(false, generation: active.generation)
                active.overlay.updatePhase(recordingLifecycle.phase, commandInFlight: false)
                return .failure(error)
            }
        }
        recordingCommandTail = Task { @MainActor in _ = await operation.value }
        try await operation.value.get()
    }

    func exportVideo(using request: VideoExportRequest) {
        guard VideoExportSupport.capability(for: request.format, target: request.target).isSupported else { return }
        if request.updatesDefaults {
            exportPreferences = VideoExportPreferences(format: request.format, target: request.target)
        }
        documents?.videoEditorController?.exportVideo(using: request)
    }

    func promisedVideoPayload() -> PromisedFilePayload? {
        documents?.videoEditorController?.promisedVideoPayload(using: defaultExportRequest)
    }

    func reserveAndPrepareRecording(
        source: PermissionRestartVideoSource = .screen,
        preferences: VideoRecordingPreferences? = nil,
        _ operation: @escaping @MainActor (UUID) async -> Void
    ) {
        guard !recordingLifecycle.blocksNewCapture else { return }
        let preferences = preferences ?? recordingPreferences
        guard dependencies.permissions.preflight([.screenRecording], featureName: "Video").isGranted else {
            dependencies.permissions.deferOperation(requiring: [.screenRecording], featureName: "Video") { [weak self] in
                self?.reserveAndPrepareRecording(source: source, preferences: preferences, operation)
            }
            if !dependencies.capture.privateCaptureEnabled {
                dependencies.permissions.rememberPermissionRestartAction(.video(source, preferences))
            }
            return
        }
        dependencies.permissions.cancelDeferredOperation(ifFeature: nil)
        guard let generation = recordingLifecycle.reserveStart() else { return }
        pendingRecordingSource = source
        preparedRecordingPreferences = preferences
        recordingStartRecovery = nil
        pendingRecordingOperation = operation
        completedRecordingGeneration = nil
        completedRecordingSucceeded = false
        recordingStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if preferences.recordsMicrophone { try await recordingService.platform.requestMicrophoneAccess() }
            } catch {
                failPreparingRecording(generation: generation, error: error)
                return
            }
            guard verifyPreparedRecordingAccess(generation: generation) else { return }
            let canContinue = await documents?.prepareForNewVideoRecording() ?? true
            guard canContinue, isCurrentPreparingGeneration(generation), !Task.isCancelled else {
                recordingLifecycle.reset(generation: generation)
                return
            }
            await operation(generation)
        }
    }

    private func beginFullscreenVideoRecording(
        generation: UUID,
        presentationContext: WorkflowPresentationContext
    ) async {
        guard verifyPreparedRecordingAccess(generation: generation) else { return }

        _ = dependencies.capture.beginCapturePrivacyLock()
        defer { dependencies.capture.endCapturePrivacyLock() }
        do {
            try prepareTemporaryVideoStorageForRecording()
        } catch {
            failPreparingRecording(generation: generation, error: error)
            return
        }

        let hiddenWindow = hideAppWindowIfNeeded(for: presentationContext)
        try? await dependencies.systemServices.scheduler.sleep(nanoseconds: 200_000_000)
        guard isCurrentPreparingGeneration(generation), !Task.isCancelled else {
            restoreAppWindowIfNeeded(hiddenWindow)
            return
        }

        do {
            let session = try await recordingService.startFullscreenRecording(preferences: currentRecordingPreferences)
            await activateRecording(
                session: session,
                sourceLabel: WorkflowVocabulary.Source.screen,
                hiddenWindow: hiddenWindow,
                generation: generation
            )
        } catch {
            failPreparingRecording(generation: generation, hiddenWindow: hiddenWindow, error: error)
        }
    }

    private func beginRegionVideoRecording(
        generation: UUID,
        presentationContext: WorkflowPresentationContext
    ) async {
        guard verifyPreparedRecordingAccess(generation: generation) else { return }

        _ = dependencies.capture.beginCapturePrivacyLock()
        defer { dependencies.capture.endCapturePrivacyLock() }
        do {
            try prepareTemporaryVideoStorageForRecording()
        } catch {
            failPreparingRecording(generation: generation, error: error)
            return
        }

        let hiddenWindow = hideAppWindowIfNeeded(for: presentationContext)
        try? await dependencies.systemServices.scheduler.sleep(nanoseconds: 200_000_000)
        guard isCurrentPreparingGeneration(generation), !Task.isCancelled else {
            restoreAppWindowIfNeeded(hiddenWindow)
            return
        }

        do {
            let result: (ScreenRecordingSession, String)? = try await dependencies.capture.performVideoWork(message: "Record Region") {
                let selectionSnapshot = try await dependencies.capture.videoWindowSelectionSnapshot()
                let selectionSession = RegionSelectionSession(
                    snapshot: selectionSnapshot.snapshot,
                    windows: selectionSnapshot.windows,
                    preferences: dependencies.capture.regionCapturePreferences,
                    livePreviewCapturePlatform: dependencies.systemServices.screenCapturePlatform
                )
                guard let selection = await selectionSession.begin() else { return nil }
                switch selection {
                case let .region(region, _):
                    return (
                        try await recordingService.startRegionRecording(in: region, preferences: currentRecordingPreferences),
                        WorkflowVocabulary.Source.region
                    )
                case .window(let window):
                    let resolved = try await recordingService.resolveWindowTarget(window)
                    return (
                        try await recordingService.startWindowRecording(resolved, preferences: currentRecordingPreferences),
                        WorkflowVocabulary.Source.window
                    )
                }
            }

            guard let result else {
                failPreparingRecording(generation: generation, hiddenWindow: hiddenWindow)
                return
            }
            await activateRecording(
                session: result.0,
                sourceLabel: result.1,
                hiddenWindow: hiddenWindow,
                generation: generation
            )
        } catch {
            failPreparingRecording(generation: generation, hiddenWindow: hiddenWindow, error: error)
        }
    }

    private func beginWindowVideoRecording(_ window: CaptureWindowSummary, generation: UUID) async {
        guard verifyPreparedRecordingAccess(generation: generation) else { return }

        _ = dependencies.capture.beginCapturePrivacyLock()
        defer { dependencies.capture.endCapturePrivacyLock() }
        do {
            try prepareTemporaryVideoStorageForRecording()
            let session = try await dependencies.capture.performVideoWork(message: "Starting Recording") {
                let resolvedWindow = try await recordingService.resolveWindowTarget(window)
                return try await recordingService.startWindowRecording(resolvedWindow, preferences: currentRecordingPreferences)
            }
            await activateRecording(
                session: session,
                sourceLabel: WorkflowVocabulary.Source.window,
                hiddenWindow: nil,
                generation: generation
            )
        } catch {
            failPreparingRecording(generation: generation, error: error)
        }
    }

    private func activateRecording(
        session: ScreenRecordingSession,
        sourceLabel: String,
        hiddenWindow: AppWindowVisibilityToken?,
        generation: UUID
    ) async {
        guard isCurrentPreparingGeneration(generation), !Task.isCancelled else {
            _ = try? await session.stop()
            restoreAppWindowIfNeeded(hiddenWindow)
            return
        }

        let overlay = RecordingControlOverlay(
            title: sourceLabel,
            sourceLabel: sourceLabel,
            preferences: currentRecordingPreferences,
            phase: .recording,
            presentationFrame: session.presentationFrame,
            pauseResumeAction: { [weak self] in self?.toggleVideoRecordingPauseResume() },
            stopAction: { [weak self] in self?.stopVideoRecording() },
            audioOptionsAction: { [weak self] recordsSystemAudio, recordsMicrophone in
                guard let self else { throw CancellationError() }
                try await self.updateVideoAudioOptions(
                    recordsSystemAudio: recordsSystemAudio,
                    recordsMicrophone: recordsMicrophone
                )
            }
        )
        let active = ActiveVideoRecording(
            generation: generation,
            session: session,
            overlay: overlay,
            hiddenWindow: hiddenWindow
        )
        activeVideoRecording = active
        pendingRecordingOperation = nil
        recordingStartRecovery = nil
        desiredVideoAudioOptions = VideoRecordingAudioOptions(
            recordsSystemAudio: currentRecordingPreferences.recordsSystemAudio,
            recordsMicrophone: currentRecordingPreferences.recordsMicrophone
        )
        recordingStartTask = nil
        guard recordingLifecycle.transition(to: .recording, generation: generation) else {
            _ = try? await session.stop()
            restoreAppWindowIfNeeded(hiddenWindow)
            overlay.close()
            activeVideoRecording = nil
            desiredVideoAudioOptions = nil
            recordingLifecycle.reset(generation: generation)
            return
        }
        session.audioLevelHandler = { [weak overlay] levels in overlay?.updateAudioLevels(levels) }
        session.terminalFailureHandler = { [weak self, weak session] error in
            guard let self, let session,
                  self.activeVideoRecording?.session === session else { return }
            self.handleUnexpectedRecordingFailure(error, active: active)
        }
        if recordingLifecycle.phase == .recording {
            startVideoStorageMonitor(for: session)
            dependencies.lifecycle.updateWorkingMessage(WorkflowVocabulary.Status.videoRecording)
        }
    }

    private func handleUnexpectedRecordingFailure(_ error: Error, active: ActiveVideoRecording) {
        guard recordingLifecycle.transition(to: .finishing, generation: active.generation) else { return }
        stopVideoStorageMonitor()
        active.overlay.updatePhase(.finishing, commandInFlight: true)
        let previous = recordingCommandTail
        let task = Task { @MainActor [weak self] in
            _ = await previous?.value
            _ = await self?.finishRecording(active, unexpectedError: error)
        }
        recordingCommandTail = task
    }

    private func finishRecording(
        _ active: ActiveVideoRecording,
        unexpectedError: Error?
    ) async -> Bool {
        guard activeVideoRecording?.session === active.session else {
            return completedRecordingGeneration == active.generation && completedRecordingSucceeded
        }
        do {
            let recording = try await dependencies.capture.performVideoWork(message: WorkflowVocabulary.Status.videoFinishing) {
                try await active.session.stop()
            }
            recordFinalizationResult(true, generation: active.generation)
            completeRecordingCleanup(active)
            documents?.installVideoController(
                VideoEditorController(recording: recording),
                documentURL: nil,
                savedSession: nil
            )
            requestMainWindowPresentation()
            if unexpectedError != nil || active.session.recoveredFromSegmentFailure {
                present(ScreenRecordingError.recordingFailed(
                    "Recording stopped unexpectedly. The captured Video was recovered."
                ))
            }
            return true
        } catch {
            recordFinalizationResult(false, generation: active.generation)
            completeRecordingCleanup(active)
            present(unexpectedError ?? error)
            return false
        }
    }

    func prepareRecordingForApplicationExit() async -> Bool {
        if recordingLifecycle.phase == .preparing {
            cancelPendingVideoRecording()
            return true
        }

        guard let active = activeVideoRecording else { return true }
        if recordingLifecycle.phase != .finishing {
            guard recordingLifecycle.transition(to: .finishing, generation: active.generation) else {
                return false
            }
            stopVideoStorageMonitor()
            active.overlay.updatePhase(.finishing, commandInFlight: true)
        }

        let previous = recordingCommandTail
        _ = await previous?.value
        if activeVideoRecording?.session !== active.session {
            return completedRecordingGeneration == active.generation && completedRecordingSucceeded
        }
        return await finishRecording(active, unexpectedError: nil)
    }

    private func recordFinalizationResult(_ succeeded: Bool, generation: UUID) {
        completedRecordingGeneration = generation
        completedRecordingSucceeded = succeeded
    }

    private func completeRecordingCleanup(_ active: ActiveVideoRecording) {
        stopVideoStorageMonitor()
        restoreAppWindowIfNeeded(active.hiddenWindow)
        active.overlay.close()
        activeVideoRecording = nil
        desiredVideoAudioOptions = nil
        recordingCommandTail = nil
        recordingLifecycle.reset(generation: active.generation)
    }

    private func verifyPreparedRecordingAccess(generation: UUID, hiddenWindow: AppWindowVisibilityToken? = nil) -> Bool {
        guard isCurrentPreparingGeneration(generation), !Task.isCancelled else {
            restoreAppWindowIfNeeded(hiddenWindow)
            return false
        }
        dependencies.permissions.refreshPermissions()
        guard dependencies.permissions.permissionStatus.hasScreenRecording else {
            failPreparingRecording(generation: generation, hiddenWindow: hiddenWindow, error: ScreenRecordingError.permissionDenied)
            return false
        }
        return true
    }

    private func failPreparingRecording(
        generation: UUID,
        hiddenWindow: AppWindowVisibilityToken? = nil,
        error: Error? = nil
    ) {
        restoreAppWindowIfNeeded(hiddenWindow)
        guard isCurrentPreparingGeneration(generation) else { return }
        pendingWindowPickerGeneration = nil
        recordingStartTask = nil
        recordingLifecycle.reset(generation: generation)
        if let error, !(error is CancellationError) { presentVideoStartFailure(error) }
    }

    private func isCurrentPreparingGeneration(_ generation: UUID) -> Bool {
        recordingLifecycle.phase == .preparing && recordingLifecycle.generation == generation
    }

    private func prepareTemporaryVideoStorageForRecording() throws {
        try VideoStorageGuardrails.cleanupOwnedTemporaryMedia(
            excluding: documents?.currentProtectedTemporaryVideoURLs() ?? []
        )
    }

    private func startVideoStorageMonitor(for session: ScreenRecordingSession) {
        stopVideoStorageMonitor()
        videoStorageMonitorTask = Task { @MainActor [weak self, weak session] in
            while !Task.isCancelled {
                try? await self?.dependencies.systemServices.scheduler.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled,
                      let self, let session,
                      self.activeVideoRecording?.session === session else { return }
                do {
                    try session.checkStoragePressure()
                } catch {
                    present(error)
                    stopVideoRecording()
                    return
                }
            }
        }
    }

    private func stopVideoStorageMonitor() {
        videoStorageMonitorTask?.cancel()
        videoStorageMonitorTask = nil
    }

    private func present(_ error: Error) { dependencies.capture.present(error) }
    private func requestMainWindowPresentation() { dependencies.lifecycle.requestMainWindowPresentation() }
    private func hideAppWindowIfNeeded() -> AppWindowVisibilityToken? { dependencies.appWindowPresenter.hideAppWindowIfNeeded() }
    private func hideAppWindowIfNeeded(
        for context: WorkflowPresentationContext
    ) -> AppWindowVisibilityToken? {
        dependencies.appWindowPresenter.hideAppWindowIfNeeded(for: context)
    }
    private func restoreAppWindowIfNeeded(_ token: AppWindowVisibilityToken?) { dependencies.appWindowPresenter.restoreAppWindowIfNeeded(token) }
}
