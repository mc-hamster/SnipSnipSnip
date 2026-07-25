import Foundation

nonisolated struct ArchivePreferenceStore {
    private let storage: PreferenceStorage

    init(storage: PreferenceStorage) {
        self.storage = storage
    }

    func loadLocationURL() -> URL? {
        if let bookmarkData = storage.data(forKey: AppModelPreferenceKey.archiveLocationBookmarkData) {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return url
            }
        }

        guard let path = storage.string(forKey: AppModelPreferenceKey.archiveLocationPath) else {
            return nil
        }

        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func saveLocationURL(_ url: URL?) {
        if let url {
            storage.set(url.path, forKey: AppModelPreferenceKey.archiveLocationPath)

            if let bookmarkData = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                storage.set(bookmarkData, forKey: AppModelPreferenceKey.archiveLocationBookmarkData)
            } else {
                storage.removeObject(forKey: AppModelPreferenceKey.archiveLocationBookmarkData)
            }
        } else {
            storage.removeObject(forKey: AppModelPreferenceKey.archiveLocationPath)
            storage.removeObject(forKey: AppModelPreferenceKey.archiveLocationBookmarkData)
        }
    }

    func loadMaximumSizeMB() -> Int {
        let configuredSize = storage.object(forKey: AppModelPreferenceKey.archiveMaximumSizeMB) as? Int
            ?? storage.integer(forKey: AppModelPreferenceKey.archiveMaximumSizeMB)

        guard configuredSize > 0 else {
            return AppPreferenceDefaults.archiveMaximumSizeMB
        }

        return max(configuredSize, AppPreferenceDefaults.minimumArchiveMaximumSizeMB)
    }

    func saveMaximumSizeMB(_ value: Int) {
        storage.set(value, forKey: AppModelPreferenceKey.archiveMaximumSizeMB)
    }

    func loadRecycleBinRetentionDays() -> Int {
        if storage.object(forKey: AppModelPreferenceKey.recycleBinRetentionDays) != nil {
            let configuredDays = storage.integer(forKey: AppModelPreferenceKey.recycleBinRetentionDays)
            let sanitizedDays = sanitizeRecycleBinRetentionDays(configuredDays)
            storage.set(sanitizedDays, forKey: AppModelPreferenceKey.recycleBinRetentionDays)
            storage.set(true, forKey: AppModelPreferenceKey.recycleBinRetentionDefaultMigrationCompleted)
            return sanitizedDays
        }

        let hasCompletedOnboarding = (storage.object(forKey: AppModelPreferenceKey.completedOnboardingVersion) as? Int ?? 0) > 0
        let hasLegacyWelcomeState = storage.object(forKey: AppModelPreferenceKey.hasPresentedWelcomeWindow) != nil
            || storage.object(forKey: AppModelPreferenceKey.hasDismissedWelcomeCard) != nil
        let migrationCompleted = storage.bool(forKey: AppModelPreferenceKey.recycleBinRetentionDefaultMigrationCompleted)

        let defaultDays: Int
        if !migrationCompleted && (hasCompletedOnboarding || hasLegacyWelcomeState) {
            defaultDays = AppPreferenceDefaults.legacyRecycleBinRetentionDays
        } else {
            defaultDays = AppPreferenceDefaults.recycleBinRetentionDays
        }

        storage.set(defaultDays, forKey: AppModelPreferenceKey.recycleBinRetentionDays)
        storage.set(true, forKey: AppModelPreferenceKey.recycleBinRetentionDefaultMigrationCompleted)
        return defaultDays
    }

    func saveRecycleBinRetentionDays(_ value: Int) {
        storage.set(sanitizeRecycleBinRetentionDays(value), forKey: AppModelPreferenceKey.recycleBinRetentionDays)
        storage.set(true, forKey: AppModelPreferenceKey.recycleBinRetentionDefaultMigrationCompleted)
    }

    private func sanitizeRecycleBinRetentionDays(_ value: Int) -> Int {
        min(
            max(value, AppPreferenceDefaults.minimumRecycleBinRetentionDays),
            AppPreferenceDefaults.maximumRecycleBinRetentionDays
        )
    }
}
