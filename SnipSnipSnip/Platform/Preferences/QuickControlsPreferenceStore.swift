import Foundation

nonisolated struct QuickControlsPreferenceStore {
    private let storage: PreferenceStorage
    private let preference = CodablePreference(
        key: AppModelPreferenceKey.quickControlsPreferences,
        defaultValue: QuickControlsPreferences.default
    )

    init(storage: PreferenceStorage) {
        self.storage = storage
    }

    func loadPreferences() -> QuickControlsPreferences {
        preference.load(from: storage).migratedToCurrentDock()
    }

    func savePreferences(_ preferences: QuickControlsPreferences) {
        preference.save(preferences.sanitized(), to: storage)
    }
}
