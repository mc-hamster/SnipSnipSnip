import Foundation

nonisolated struct AutomationPreferenceStore {
    private let storage: PreferenceStorage
    private let preferences = CodablePreference<CaptureAutomationPreferences>(
        key: AppModelPreferenceKey.captureAutomationPreferences,
        defaultValue: CaptureAutomationPreferences()
    )

    init(storage: PreferenceStorage) {
        self.storage = storage
    }

    func loadPreferences() -> CaptureAutomationPreferences {
        preferences.load(from: storage)
    }

    func savePreferences(_ value: CaptureAutomationPreferences) {
        preferences.save(value, to: storage)
    }
}
