import Foundation

struct VideoStartRecovery: Identifiable {
    let id = UUID()
    let message: String
    let needsMicrophoneAccess: Bool
}

@MainActor
extension VideoWorkflowModel {
    var currentRecordingPreferences: VideoRecordingPreferences {
        preparedRecordingPreferences ?? recordingPreferences
    }

    func retryVideoStart(withoutMicrophone: Bool = false) {
        guard let operation = pendingRecordingOperation, !blocksNewCapture else { return }
        var preferences = currentRecordingPreferences
        if withoutMicrophone { preferences.recordsMicrophone = false }
        recordingStartRecovery = nil
        reserveAndPrepareRecording(source: pendingRecordingSource, preferences: preferences, operation)
    }

    func dismissVideoStartRecovery() {
        recordingStartRecovery = nil
        pendingRecordingOperation = nil
        preparedRecordingPreferences = nil
    }

    func openMicrophoneSettings() {
        dependencies.permissions.openMediaPermissionSettings(.microphone)
    }

    static func isMicrophonePermissionError(_ error: Error) -> Bool {
        if case ScreenRecordingError.microphonePermissionDenied = error { return true }
        return false
    }

    func presentVideoStartFailure(_ error: Error) {
        _ = dependencies.permissions.reconcileScreenRecordingPermissionFailureIfNeeded(after: error)
        recordingStartRecovery = VideoStartRecovery(
            message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
            needsMicrophoneAccess: Self.isMicrophonePermissionError(error)
        )
        dependencies.permissions.refreshPermissions()
        dependencies.lifecycle.requestMainWindowPresentation()
    }
}
