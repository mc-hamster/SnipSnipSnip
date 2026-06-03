import AppKit
import Combine
import Foundation

struct ActiveVideoRecording {
    let session: ScreenRecordingSession
    let overlay: RecordingControlOverlay
    let hiddenWindow: NSWindow?
}

extension AppModel {
    func recordCurrentDisplay() {
        performAfterHandlingUnsavedChanges { [weak self] in
            self?.beginFullscreenVideoRecording()
        }
    }

    func recordRegion() {
        performAfterHandlingUnsavedChanges { [weak self] in
            self?.beginRegionVideoRecording()
        }
    }

    func presentVideoWindowPicker() {
        performAfterHandlingUnsavedChanges { [weak self] in
            self?.windowPickerMode = .videoRecording
            self?.beginWindowPickerPresentation()
        }
    }

    func recordWindow(_ window: CaptureWindowSummary) {
        isShowingWindowPicker = false
        performAfterHandlingUnsavedChanges { [weak self] in
            self?.beginWindowVideoRecording(window)
        }
    }

    func pickWindowOnScreenForVideoRecording() {
        let windows = availableWindows
        isShowingWindowPicker = false

        Task {
            _ = beginCapturePrivacyLock()
            defer { endCapturePrivacyLock() }
            let hiddenWindow = hideAppWindowIfNeeded()
            defer { restoreAppWindowIfNeeded(hiddenWindow) }

            if hiddenWindow != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }

            guard ensureScreenRecordingAccess() else {
                return
            }

            isWorking = true
            workingMessage = "Pick Window"
            defer { isWorking = false }

            do {
                let windowOptions = windows.isEmpty ? try await captureService.listWindows(includeThumbnails: false) : windows
                let snapshot = try await captureService.captureDesktopOverlaySnapshot()
                let session = WindowSelectionSession(snapshot: snapshot, windows: windowOptions)

                guard let selectedWindow = await session.begin() else {
                    return
                }

                beginWindowVideoRecording(selectedWindow)
            } catch {
                present(error)
            }
        }
    }

    func stopVideoRecording() {
        guard let activeVideoRecording else {
            return
        }

        self.activeVideoRecording = nil
        stopVideoStorageMonitor()
        activeVideoRecording.overlay.close()

        Task {
            isWorking = true
            workingMessage = "Finishing Recording"
            defer { isWorking = false }

            do {
                let recording = try await activeVideoRecording.session.stop()
                restoreAppWindowIfNeeded(activeVideoRecording.hiddenWindow)
                installVideoController(VideoEditorController(recording: recording), documentURL: nil, savedSession: nil)
                requestMainWindowPresentation()
            } catch {
                restoreAppWindowIfNeeded(activeVideoRecording.hiddenWindow)
                if TemporaryVideoMediaManager.isOwnedTemporaryMediaURL(activeVideoRecording.session.outputURL) {
                    try? FileManager.default.removeItem(at: activeVideoRecording.session.outputURL)
                }
                present(error)
            }
        }
    }

    func toggleVideoRecordingPauseResume() {
        guard let activeVideoRecording else {
            return
        }

        if activeVideoRecording.session.isPaused {
            resumeVideoRecording()
        } else {
            pauseVideoRecording()
        }
    }

    func pauseVideoRecording() {
        guard let activeVideoRecording else {
            return
        }

        Task {
            do {
                try await activeVideoRecording.session.pause()
                activeVideoRecording.overlay.updatePausedState(true)
                workingMessage = "Recording Paused"
            } catch {
                present(error)
            }
        }
    }

    func resumeVideoRecording() {
        guard let activeVideoRecording else {
            return
        }

        Task {
            do {
                try await activeVideoRecording.session.resume()
                activeVideoRecording.overlay.updatePausedState(false)
                workingMessage = "Recording"
            } catch {
                present(error)
            }
        }
    }

    func exportVideo(using request: VideoExportRequest) {
        guard request.target.supports(request.format) else {
            return
        }

        if request.updatesDefaults {
            videoExportPreferences = VideoExportPreferences(format: request.format, target: request.target)
        }

        videoEditorController?.exportVideo(using: request)
    }

    func promisedVideoPayload() -> PromisedFilePayload? {
        videoEditorController?.promisedVideoPayload(using: defaultVideoExportRequest)
    }

    func installVideoController(_ controller: VideoEditorController, documentURL: URL?, savedSession: VideoEditorSession?) {
        let previousTemporaryVideoURL = currentOwnedTemporaryVideoSourceURL(replacingWith: controller.recording.sourceURL)
        clearCurrentRecoveryPendingState()
        editorController = nil
        currentDocumentURL = documentURL
        savedVideoSession = savedSession
        videoEditorController = controller
        updateDocumentChangeTracking()
        cleanupTemporaryVideoSourceIfNeeded(previousTemporaryVideoURL)

        Task { @MainActor [weak self] in
            self?.resizeMainWindowForEditorContentIfNeeded(animated: false)
        }
    }

    func configureVideoEditorObservers() {
        guard let videoEditorController else {
            videoPersistenceObserver = nil

            if editorController == nil {
                resetEditorSessionState()
            }

            return
        }

        videoPersistenceObserver = videoEditorController.$persistenceRevision
            .dropFirst()
            .sink { [weak self] _ in
                self?.updateDocumentChangeTracking()
            }

        updateDocumentChangeTracking()
    }

    private func beginFullscreenVideoRecording() {
        Task {
            guard ensureScreenRecordingAccess(), activeVideoRecording == nil else {
                return
            }

            _ = beginCapturePrivacyLock()
            defer { endCapturePrivacyLock() }

            do {
                try prepareTemporaryVideoStorageForRecording()
            } catch {
                present(error)
                return
            }

            let hiddenWindow = hideAppWindowIfNeeded()
            try? await Task.sleep(nanoseconds: 200_000_000)

            do {
                let session = try await screenRecordingService.startFullscreenRecording(preferences: videoRecordingPreferences)
                activeVideoRecording = buildActiveRecording(
                    session: session,
                    title: "Recording Fullscreen",
                    hiddenWindow: hiddenWindow
                )
                startVideoStorageMonitor(for: session)
                workingMessage = "Recording"
            } catch {
                restoreAppWindowIfNeeded(hiddenWindow)
                present(error)
            }
        }
    }

    private func beginRegionVideoRecording() {
        Task {
            guard ensureScreenRecordingAccess(), activeVideoRecording == nil else {
                return
            }

            _ = beginCapturePrivacyLock()
            defer { endCapturePrivacyLock() }

            do {
                try prepareTemporaryVideoStorageForRecording()
            } catch {
                present(error)
                return
            }

            let hiddenWindow = hideAppWindowIfNeeded()
            try? await Task.sleep(nanoseconds: 200_000_000)

            isWorking = true
            workingMessage = "Record Region"
            defer { isWorking = false }

            do {
                let snapshot = try await captureService.captureDesktopOverlaySnapshot()
                let session = RegionSelectionSession(snapshot: snapshot, preferences: regionCapturePreferences)

                guard case let .region(region, _) = await session.begin() else {
                    restoreAppWindowIfNeeded(hiddenWindow)
                    return
                }

                let recordingSession = try await screenRecordingService.startRegionRecording(
                    in: region,
                    preferences: videoRecordingPreferences
                )
                activeVideoRecording = buildActiveRecording(
                    session: recordingSession,
                    title: "Recording Region",
                    hiddenWindow: hiddenWindow
                )
                startVideoStorageMonitor(for: recordingSession)
                workingMessage = "Recording"
            } catch {
                restoreAppWindowIfNeeded(hiddenWindow)
                present(error)
            }
        }
    }

    private func beginWindowVideoRecording(_ window: CaptureWindowSummary) {
        Task {
            guard ensureScreenRecordingAccess(), activeVideoRecording == nil else {
                return
            }

            _ = beginCapturePrivacyLock()
            defer { endCapturePrivacyLock() }

            do {
                try prepareTemporaryVideoStorageForRecording()
            } catch {
                present(error)
                return
            }

            isWorking = true
            workingMessage = "Starting Recording"
            defer { isWorking = false }

            do {
                let resolvedWindow = try await screenRecordingService.resolveWindowTarget(window)
                let session = try await screenRecordingService.startWindowRecording(
                    resolvedWindow,
                    preferences: videoRecordingPreferences
                )
                activeVideoRecording = buildActiveRecording(
                    session: session,
                    title: "Recording Window",
                    hiddenWindow: nil
                )
                startVideoStorageMonitor(for: session)
                workingMessage = "Recording"
            } catch {
                present(error)
            }
        }
    }

    private func buildActiveRecording(
        session: ScreenRecordingSession,
        title: String,
        hiddenWindow: NSWindow?
    ) -> ActiveVideoRecording {
        ActiveVideoRecording(
            session: session,
            overlay: RecordingControlOverlay(
                title: title,
                isPaused: session.isPaused,
                pauseResumeAction: { [weak self] in
                    self?.toggleVideoRecordingPauseResume()
                },
                stopAction: { [weak self] in
                    self?.stopVideoRecording()
                }
            ),
            hiddenWindow: hiddenWindow
        )
    }

    private func prepareTemporaryVideoStorageForRecording() throws {
        try VideoStorageGuardrails.cleanupOwnedTemporaryMedia(excluding: currentProtectedTemporaryVideoURLs())
    }

    private func startVideoStorageMonitor(for session: ScreenRecordingSession) {
        stopVideoStorageMonitor()

        videoStorageMonitorTask = Task { @MainActor [weak self, weak session] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)

                guard !Task.isCancelled,
                      let self,
                      let session,
                      self.activeVideoRecording?.session === session else {
                    return
                }

                do {
                    try session.checkStoragePressure()
                } catch {
                    self.present(error)
                    self.stopVideoRecording()
                    return
                }
            }
        }
    }

    private func stopVideoStorageMonitor() {
        videoStorageMonitorTask?.cancel()
        videoStorageMonitorTask = nil
    }
}
