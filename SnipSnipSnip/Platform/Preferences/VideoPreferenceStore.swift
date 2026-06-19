import Foundation

nonisolated struct VideoPreferenceStore {
    private let storage: PreferenceStorage
    private let recordingPreferences = CodablePreference<VideoRecordingPreferences>(
        key: AppModelPreferenceKey.videoRecordingPreferences,
        defaultValue: VideoRecordingPreferences()
    )
    private let exportPreferences = CodablePreference<VideoExportPreferences>(
        key: AppModelPreferenceKey.videoExportPreferences,
        defaultValue: VideoExportPreferences()
    )

    init(storage: PreferenceStorage) {
        self.storage = storage
    }

    func loadRecordingPreferences() -> VideoRecordingPreferences {
        recordingPreferences.load(from: storage)
    }

    func saveRecordingPreferences(_ preferences: VideoRecordingPreferences) {
        recordingPreferences.save(preferences, to: storage)
    }

    func loadExportPreferences() -> VideoExportPreferences {
        exportPreferences.load(from: storage).sanitized()
    }

    func saveExportPreferences(_ preferences: VideoExportPreferences) {
        exportPreferences.save(preferences.sanitized(), to: storage)
    }
}

nonisolated extension VideoExportPreferences {
    func sanitized() -> VideoExportPreferences {
        VideoExportSupport.capability(for: format, target: target).isSupported ? self : VideoExportPreferences()
    }
}
