import AppKit
import Foundation

struct ActiveVideoRecording {
    let session: ScreenRecordingSession
    let overlay: RecordingControlOverlay
    let hiddenWindow: AppWindowVisibilityToken?
}

@MainActor
extension VideoWorkflowModel {
    var isRecording: Bool {
        activeVideoRecording != nil
    }

    var defaultExportRequest: VideoExportRequest {
        VideoExportRequest(
            format: .mp4,
            target: exportPreferences.target
        )
    }

    func recordCurrentDisplay() {
        documents?.performAfterHandlingUnsavedChanges { [weak self] in
            self?.beginFullscreenVideoRecording()
        }
    }

    func recordRegion() {
        documents?.performAfterHandlingUnsavedChanges { [weak self] in
            self?.beginRegionVideoRecording()
        }
    }

    func presentVideoWindowPicker() {
        documents?.performAfterHandlingUnsavedChanges { [weak self] in
            guard let self else {
                return
            }

            dependencies.capture.beginVideoWindowSelection()
        }
    }

    func recordWindow(_ window: CaptureWindowSummary) {
        dependencies.capture.dismissWindowPicker()
        documents?.performAfterHandlingUnsavedChanges { [weak self] in
            self?.beginWindowVideoRecording(window)
        }
    }

    func pickWindowOnScreenForVideoRecording() {
        let windows = dependencies.capture.availableWindows
        dependencies.capture.dismissWindowPicker()

        Task {
            _ = dependencies.capture.beginCapturePrivacyLock()
            defer { dependencies.capture.endCapturePrivacyLock() }
            let hiddenWindow = hideAppWindowIfNeeded()
            defer { restoreAppWindowIfNeeded(hiddenWindow) }

            if hiddenWindow != nil {
                try? await dependencies.systemServices.scheduler.sleep(nanoseconds: 200_000_000)
            }

            guard dependencies.permissions.preflight([.screenRecording], featureName: "Capture").isGranted else {
                return
            }

            do {
                let selectedWindow = try await dependencies.capture.performVideoWork(message: "Pick Window") {
                    let selection = try await dependencies.capture.videoWindowSelectionSnapshot(fallbackWindows: windows)
                    let session = WindowSelectionSession(
                        snapshot: selection.snapshot,
                        windows: selection.windows,
                        capabilities: dependencies.capabilities,
                        accessibility: dependencies.systemServices.accessibility,
                        screens: dependencies.systemServices.screens
                    )

                    return await session.begin()
                }

                if let selectedWindow {
                    beginWindowVideoRecording(selectedWindow)
                }
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
            do {
                try await dependencies.capture.performVideoWork(message: "Finishing Recording") {
                    let recording = try await activeVideoRecording.session.stop()
                    restoreAppWindowIfNeeded(activeVideoRecording.hiddenWindow)
                    documents?.installVideoController(
                        VideoEditorController(recording: recording),
                        documentURL: nil,
                        savedSession: nil
                    )
                    requestMainWindowPresentation()
                }
            } catch {
                restoreAppWindowIfNeeded(activeVideoRecording.hiddenWindow)
                if TemporaryVideoMediaManager.isOwnedTemporaryMediaURL(activeVideoRecording.session.outputURL, files: dependencies.systemServices.files) {
                    try? dependencies.systemServices.files.removeItem(at: activeVideoRecording.session.outputURL)
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
                dependencies.lifecycle.updateWorkingMessage("Recording Paused")
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
                dependencies.lifecycle.updateWorkingMessage("Recording")
            } catch {
                present(error)
            }
        }
    }

    func exportVideo(using request: VideoExportRequest) {
        guard VideoExportSupport.capability(for: request.format, target: request.target).isSupported else {
            return
        }

        if request.updatesDefaults {
            exportPreferences = VideoExportPreferences(format: request.format, target: request.target)
        }

        documents?.videoEditorController?.exportVideo(using: request)
    }

    func promisedVideoPayload() -> PromisedFilePayload? {
        documents?.videoEditorController?.promisedVideoPayload(using: defaultExportRequest)
    }

    private func beginFullscreenVideoRecording() {
        Task {
            guard dependencies.permissions.preflight([.screenRecording], featureName: "Capture").isGranted,
                  activeVideoRecording == nil else {
                return
            }

            _ = dependencies.capture.beginCapturePrivacyLock()
            defer { dependencies.capture.endCapturePrivacyLock() }

            do {
                try prepareTemporaryVideoStorageForRecording()
            } catch {
                present(error)
                return
            }

            let hiddenWindow = hideAppWindowIfNeeded()
            try? await dependencies.systemServices.scheduler.sleep(nanoseconds: 200_000_000)

            do {
                let session = try await recordingService.startFullscreenRecording(preferences: recordingPreferences)
                activeVideoRecording = buildActiveRecording(
                    session: session,
                    title: "Recording Fullscreen",
                    hiddenWindow: hiddenWindow
                )
                startVideoStorageMonitor(for: session)
                dependencies.lifecycle.updateWorkingMessage("Recording")
            } catch {
                restoreAppWindowIfNeeded(hiddenWindow)
                present(error)
            }
        }
    }

    private func beginRegionVideoRecording() {
        Task {
            guard dependencies.permissions.preflight([.screenRecording], featureName: "Capture").isGranted,
                  activeVideoRecording == nil else {
                return
            }

            _ = dependencies.capture.beginCapturePrivacyLock()
            defer { dependencies.capture.endCapturePrivacyLock() }

            do {
                try prepareTemporaryVideoStorageForRecording()
            } catch {
                present(error)
                return
            }

            let hiddenWindow = hideAppWindowIfNeeded()
            try? await dependencies.systemServices.scheduler.sleep(nanoseconds: 200_000_000)

            do {
                try await dependencies.capture.performVideoWork(message: "Record Region") {
                    let selectionSnapshot = try await dependencies.capture.videoWindowSelectionSnapshot(fallbackWindows: [])
                    let session = RegionSelectionSession(
                        snapshot: selectionSnapshot.snapshot,
                        windows: selectionSnapshot.windows,
                        preferences: dependencies.capture.regionCapturePreferences
                    )

                    guard let selection = await session.begin() else {
                        restoreAppWindowIfNeeded(hiddenWindow)
                        return
                    }

                    switch selection {
                    case let .region(region, _):
                        let recordingSession = try await recordingService.startRegionRecording(
                            in: region,
                            preferences: recordingPreferences
                        )
                        activeVideoRecording = buildActiveRecording(
                            session: recordingSession,
                            title: "Recording Region",
                            hiddenWindow: hiddenWindow
                        )
                        startVideoStorageMonitor(for: recordingSession)
                        dependencies.lifecycle.updateWorkingMessage("Recording")
                    case .window(let window):
                        let resolvedWindow = try await recordingService.resolveWindowTarget(window)
                        let recordingSession = try await recordingService.startWindowRecording(
                            resolvedWindow,
                            preferences: recordingPreferences
                        )
                        activeVideoRecording = buildActiveRecording(
                            session: recordingSession,
                            title: "Recording Window",
                            hiddenWindow: hiddenWindow
                        )
                        startVideoStorageMonitor(for: recordingSession)
                        dependencies.lifecycle.updateWorkingMessage("Recording")
                    }
                }
            } catch {
                restoreAppWindowIfNeeded(hiddenWindow)
                present(error)
            }
        }
    }

    private func beginWindowVideoRecording(_ window: CaptureWindowSummary) {
        Task {
            guard dependencies.permissions.preflight([.screenRecording], featureName: "Capture").isGranted,
                  activeVideoRecording == nil else {
                return
            }

            _ = dependencies.capture.beginCapturePrivacyLock()
            defer { dependencies.capture.endCapturePrivacyLock() }

            do {
                try prepareTemporaryVideoStorageForRecording()
            } catch {
                present(error)
                return
            }

            do {
                try await dependencies.capture.performVideoWork(message: "Starting Recording") {
                    let resolvedWindow = try await recordingService.resolveWindowTarget(window)
                    let session = try await recordingService.startWindowRecording(
                        resolvedWindow,
                        preferences: recordingPreferences
                    )
                    activeVideoRecording = buildActiveRecording(
                        session: session,
                        title: "Recording Window",
                        hiddenWindow: nil
                    )
                    startVideoStorageMonitor(for: session)
                    dependencies.lifecycle.updateWorkingMessage("Recording")
                }
            } catch {
                present(error)
            }
        }
    }

    private func buildActiveRecording(
        session: ScreenRecordingSession,
        title: String,
        hiddenWindow: AppWindowVisibilityToken?
    ) -> ActiveVideoRecording {
        let overlay = RecordingControlOverlay(
            title: title,
            sourceLabel: title.replacingOccurrences(of: "Recording ", with: ""),
            preferences: recordingPreferences,
            isPaused: session.isPaused,
            pauseResumeAction: { [weak self] in
                self?.toggleVideoRecordingPauseResume()
            },
            stopAction: { [weak self] in
                self?.stopVideoRecording()
            },
            audioOptionsAction: { [weak session] recordsSystemAudio, recordsMicrophone in
                try await session?.updateAudioOptions(
                    recordsSystemAudio: recordsSystemAudio,
                    recordsMicrophone: recordsMicrophone
                )
            }
        )
        session.audioLevelHandler = { [weak overlay] levels in
            overlay?.updateAudioLevels(levels)
        }

        return ActiveVideoRecording(
            session: session,
            overlay: overlay,
            hiddenWindow: hiddenWindow
        )
    }

    private func prepareTemporaryVideoStorageForRecording() throws {
        try VideoStorageGuardrails.cleanupOwnedTemporaryMedia(excluding: documents?.currentProtectedTemporaryVideoURLs() ?? [])
    }

    private func startVideoStorageMonitor(for session: ScreenRecordingSession) {
        stopVideoStorageMonitor()

        videoStorageMonitorTask = Task { @MainActor [weak self, weak session] in
            while !Task.isCancelled {
                try? await self?.dependencies.systemServices.scheduler.sleep(nanoseconds: 15_000_000_000)

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

    private func present(_ error: Error) {
        dependencies.capture.present(error)
    }

    private func requestMainWindowPresentation() {
        dependencies.lifecycle.requestMainWindowPresentation()
    }

    private func hideAppWindowIfNeeded() -> AppWindowVisibilityToken? {
        dependencies.appWindowPresenter.hideAppWindowIfNeeded()
    }

    private func restoreAppWindowIfNeeded(_ token: AppWindowVisibilityToken?) {
        dependencies.appWindowPresenter.restoreAppWindowIfNeeded(token)
    }
}
