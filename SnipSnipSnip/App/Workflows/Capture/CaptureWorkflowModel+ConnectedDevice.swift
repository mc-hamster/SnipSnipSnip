import AppKit
import Foundation

@MainActor
extension CaptureWorkflowModel {
    func refreshConnectedDevices() {
        guard dependencies.capabilities.isEnabled(.connectedDeviceCapture) else {
            connectedDevices = []
            connectedDeviceEmptyStateMessage = ConnectedDeviceCaptureMenu.emptyStateMessage
            return
        }

        Task {
            await loadConnectedDevices(showErrors: false)
        }
    }

    func loadConnectedDevices(showErrors: Bool) async {
        guard dependencies.capabilities.isEnabled(.connectedDeviceCapture) else {
            connectedDevices = []
            connectedDeviceEmptyStateMessage = ConnectedDeviceCaptureMenu.emptyStateMessage
            if showErrors {
                present(ConnectedDeviceCaptureError.publicScreenCaptureUnavailable)
            }
            return
        }

        guard !isLoadingConnectedDevices else {
            return
        }

        isLoadingConnectedDevices = true
        defer { isLoadingConnectedDevices = false }

        let devices = await connectedDeviceCaptureService.listDevices()
        connectedDevices = devices
        if devices.isEmpty {
            let reason = await connectedDeviceCaptureService.unavailableReason()
            connectedDeviceEmptyStateMessage = reason.errorDescription ?? ConnectedDeviceCaptureMenu.emptyStateMessage
        } else {
            connectedDeviceEmptyStateMessage = ConnectedDeviceCaptureMenu.emptyStateMessage
        }

        if showErrors && devices.isEmpty {
            presentConnectedDeviceEmptyState()
        }
    }

    func presentConnectedDeviceEmptyState() {
        dependencies.lifecycle.presentError(connectedDeviceEmptyStateMessage)
        dependencies.lifecycle.requestMainWindowPresentation()
    }

    func presentConnectedDeviceSessionActiveMessage() {
        present(ConnectedDeviceCaptureError.sessionAlreadyActive)
    }

    func captureConnectedDevice(_ device: ConnectedAppleDevice) {
        captureConnectedDevice(device, intent: .newDocument)
    }

    func captureConnectedDevice(
        _ device: ConnectedAppleDevice,
        intent: CaptureIntent,
        completionRole: CaptureCompletionRole = .standalone,
        oneShotOptions: CaptureOneShotOptions? = nil
    ) {
        let captureContext = preparePersistentCaptureSurfaceIntent(
            intent,
            completionRole: completionRole,
            oneShotOptions: oneShotOptions
        )
        let runOptions = currentCaptureRunOptions()
        presentConnectedDevicePreview(
            for: device,
            intent: .screenshot,
            captureContext: captureContext,
            runOptions: runOptions
        )
    }

    func recordConnectedDevice(_ device: ConnectedAppleDevice) {
        documents?.performAfterHandlingUnsavedChanges { [weak self] in
            self?.presentConnectedDevicePreview(
                for: device,
                intent: .recording,
                captureContext: .standalone,
                runOptions: self?.currentCaptureRunOptions()
                    ?? CaptureRunOptions()
            )
        }
    }

    private func presentConnectedDevicePreview(
        for device: ConnectedAppleDevice,
        intent: ConnectedDevicePreviewIntent,
        captureContext: CaptureCompletionContext,
        runOptions: CaptureRunOptions
    ) {
        Task {
            var sessionCaptureContext = captureContext
            guard dependencies.capabilities.isEnabled(.connectedDeviceCapture) else {
                present(
                    ConnectedDeviceCaptureError
                        .publicScreenCaptureUnavailable,
                    recovering: .connectedDevice(device),
                    captureContext: captureContext
                )
                return
            }

            guard video?.blocksNewCapture != true, guide?.isActive != true, connectedDevicePreviewController == nil else {
                present(
                    ConnectedDeviceCaptureError.sessionAlreadyActive,
                    recovering: .connectedDevice(device),
                    captureContext: captureContext
                )
                return
            }

            guard await confirmConnectedDeviceCameraAccessIfNeeded() else {
                resetPreparedCaptureContext(ifMatching: captureContext)
                return
            }

            let isPrivateCapture = beginCapturePrivacyLock(
                latchedPrivateCapture:
                    captureContext.oneShotOptions?.privateCapture
                    ?? privateCaptureEnabled
            )

            isWorking = true
            dependencies.lifecycle.updateWorkingMessage("Connected Device")

            do {
                try prepareTemporaryVideoStorageForConnectedDeviceRecording()
                let session = try await connectedDeviceCaptureService.makePreviewSession(
                    for: device,
                    preferences: video?.connectedDeviceRecordingPreferences ?? VideoRecordingPreferences()
                )
                let controller = ConnectedDevicePreviewWindowController(
                    device: device,
                    session: session,
                    intent: intent,
                    isPrivateCapture: isPrivateCapture,
                    screenshotFilenameTemplate: ScreenshotFilenameTemplate(pattern: screenshotFilenameTemplate),
                    openScreenshot: { [weak self] capture, isPrivateCapture in
                        guard let self else {
                            return
                        }

                        try self.completeCapture(
                            capture,
                            request: .connectedDevice(device),
                            isPrivateCapture: isPrivateCapture,
                            runOptions: runOptions,
                            completionContext: sessionCaptureContext
                        )
                        if let continuation =
                            self.persistentSurfaceContinuationContext(
                                after: sessionCaptureContext
                            ) {
                            sessionCaptureContext = continuation
                        } else {
                            self.connectedDevicePreviewController?.close()
                        }
                        self.dependencies.lifecycle.requestMainWindowPresentation()
                    },
                    openRecording: { [weak self] recording in
                        guard let self else {
                            return
                        }

                        self.outputSink?.handle(.recordingCompleted(recording))
                    },
                    presentError: { [weak self] error in
                        self?.present(
                            error,
                            recovering: .connectedDevice(device),
                            captureContext: sessionCaptureContext
                        )
                    },
                    onClose: { [weak self] in
                        guard let self else {
                            return
                        }

                        self.connectedDevicePreviewController = nil
                        self.isConnectedDeviceSessionActive = false
                        if let sessionID = sessionCaptureContext
                            .persistentSurfaceSessionID {
                            self.resetPersistentCaptureSurfaceSession(
                                sessionID
                            )
                        } else {
                            self.resetPreparedCaptureContext(
                                ifMatching: sessionCaptureContext
                            )
                        }
                        self.endCapturePrivacyLock()
                    }
                )
                connectedDevicePreviewController = controller
                isConnectedDeviceSessionActive = true
                isWorking = false
                controller.showWindow(nil)
                dependencies.appWindowPresenter.activateApp()
                try await controller.start()
            } catch {
                connectedDevicePreviewController?.close()
                connectedDevicePreviewController = nil
                isConnectedDeviceSessionActive = false
                isWorking = false
                endCapturePrivacyLock()
                present(
                    error,
                    recovering: .connectedDevice(device),
                    captureContext: captureContext
                )
            }
        }
    }

    private func prepareTemporaryVideoStorageForConnectedDeviceRecording() throws {
        try VideoStorageGuardrails.cleanupOwnedTemporaryMedia(excluding: documents?.currentProtectedTemporaryVideoURLs() ?? [])
    }

    private func confirmConnectedDeviceCameraAccessIfNeeded() async -> Bool {
        guard await connectedDeviceCaptureService.videoAuthorizationStatus() == .notDetermined else {
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Allow Camera Access for Connected Device Preview?"
        alert.informativeText = "\(AppBranding.displayName) uses Camera access only when you preview, capture, or record a connected iPhone or iPad. macOS exposes trusted device screens as video sources, so this permission is required before the live preview can start."
        alert.addButton(withTitle: "Allow Camera")
        alert.addButton(withTitle: "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
    }
}
