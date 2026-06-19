import Foundation

nonisolated struct ClipboardPreferenceStore {
    private let storage: PreferenceStorage
    private let preferences = CodablePreference<ClipboardPreferences>(
        key: AppModelPreferenceKey.clipboardPreferences,
        defaultValue: .default
    )

    init(storage: PreferenceStorage) {
        self.storage = storage
    }

    func loadAutoCopyEnabled() -> Bool {
        storage.object(forKey: AppModelPreferenceKey.autoCopyEnabled) as? Bool ?? true
    }

    func saveAutoCopyEnabled(_ enabled: Bool) {
        storage.set(enabled, forKey: AppModelPreferenceKey.autoCopyEnabled)
    }

    func loadPreferences() -> ClipboardPreferences {
        var loadedPreferences = preferences.load(from: storage)
        let existingMatches = Set(loadedPreferences.ignoredApps.map { $0.id })
        let missingDefaultIgnores = ClipboardPreferences.defaultIgnoredApps.filter { !existingMatches.contains($0.id) }
        loadedPreferences.ignoredApps.append(contentsOf: missingDefaultIgnores)
        return loadedPreferences.sanitized()
    }

    func savePreferences(_ value: ClipboardPreferences) {
        preferences.save(value.sanitized(), to: storage)
    }
}
