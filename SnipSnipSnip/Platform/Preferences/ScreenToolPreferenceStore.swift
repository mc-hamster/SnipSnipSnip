import Foundation

nonisolated struct ScreenToolPreferenceStore {
    private let storage: PreferenceStorage
    private let rulerPreferences = CodablePreference<ScreenRulerPreferences>(
        key: AppModelPreferenceKey.screenRulerPreferences,
        defaultValue: .default
    )
    private let inspectorPreferences = CodablePreference<ScreenInspectorPreferences>(
        key: AppModelPreferenceKey.screenInspectorPreferences,
        defaultValue: .default
    )

    init(storage: PreferenceStorage) {
        self.storage = storage
    }

    func loadRulerPreferences() -> ScreenRulerPreferences {
        rulerPreferences.load(from: storage).sanitized()
    }

    func saveRulerPreferences(_ preferences: ScreenRulerPreferences) {
        rulerPreferences.save(preferences.sanitized(), to: storage)
    }

    func loadInspectorPreferences() -> ScreenInspectorPreferences {
        inspectorPreferences.load(from: storage).sanitized()
    }

    func saveInspectorPreferences(_ preferences: ScreenInspectorPreferences) {
        inspectorPreferences.save(preferences.sanitized(), to: storage)
    }
}
