import AppKit
import Foundation

extension AppModel {
    func refreshConnectedDevices() {
        guard FeatureFlags.connectedDeviceCaptureEnabled else {
            connectedDevices = []
            connectedDeviceEmptyStateMessage = ConnectedDeviceCaptureMenu.emptyStateMessage
            return
        }

        Task {
            await loadConnectedDevices(showErrors: false)
        }
    }

    func loadConnectedDevices(showErrors: Bool) async {
        guard FeatureFlags.connectedDeviceCaptureEnabled else {
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
        errorMessage = connectedDeviceEmptyStateMessage
        requestMainWindowPresentation()
    }

    func captureConnectedDevice(_ device: ConnectedAppleDevice) {
        presentConnectedDevicePreview(for: device, intent: .screenshot)
    }

    func recordConnectedDevice(_ device: ConnectedAppleDevice) {
        performAfterHandlingUnsavedChanges { [weak self] in
            self?.presentConnectedDevicePreview(for: device, intent: .recording)
        }
    }

    private func presentConnectedDevicePreview(
        for device: ConnectedAppleDevice,
        intent: ConnectedDevicePreviewIntent
    ) {
        Task {
            guard FeatureFlags.connectedDeviceCaptureEnabled else {
                present(ConnectedDeviceCaptureError.publicScreenCaptureUnavailable)
                return
            }

            guard activeVideoRecording == nil, connectedDevicePreviewController == nil else {
                present(ConnectedDeviceCaptureError.sessionAlreadyActive)
                return
            }

            let isPrivateCapture = beginCapturePrivacyLock()

            isWorking = true
            workingMessage = "Connected Device"

            do {
                try prepareTemporaryVideoStorageForConnectedDeviceRecording()
                let session = try await connectedDeviceCaptureService.makePreviewSession(
                    for: device,
                    preferences: videoRecordingPreferences
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
                            isPrivateCapture: isPrivateCapture
                        )
                        self.requestMainWindowPresentation()
                    },
                    openRecording: { [weak self] recording in
                        guard let self else {
                            return
                        }

                        self.installVideoController(
                            VideoEditorController(recording: recording),
                            documentURL: nil,
                            savedSession: nil
                        )
                        self.requestMainWindowPresentation()
                    },
                    presentError: { [weak self] error in
                        self?.present(error)
                    },
                    onClose: { [weak self] in
                        guard let self else {
                            return
                        }

                        self.connectedDevicePreviewController = nil
                        self.isConnectedDeviceSessionActive = false
                        self.endCapturePrivacyLock()
                    }
                )
                connectedDevicePreviewController = controller
                isConnectedDeviceSessionActive = true
                isWorking = false
                controller.showWindow(nil)
                NSApp.activate(ignoringOtherApps: true)
                try await controller.start()
            } catch {
                connectedDevicePreviewController?.close()
                connectedDevicePreviewController = nil
                isConnectedDeviceSessionActive = false
                isWorking = false
                endCapturePrivacyLock()
                present(error)
            }
        }
    }

    private func prepareTemporaryVideoStorageForConnectedDeviceRecording() throws {
        try VideoStorageGuardrails.cleanupOwnedTemporaryMedia(excluding: currentProtectedTemporaryVideoURLs())
    }
}
