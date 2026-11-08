import Foundation

nonisolated struct ArchivePreferenceStore {
    private let storage: PreferenceStorage
    let bookmarks: ArchiveBookmarkClient
    let requiresSecurityScope: Bool

    init(storage: PreferenceStorage, bookmarks: ArchiveBookmarkClient = .live,
         requiresSecurityScope: Bool = ArchiveBookmarkClient.requiresSecurityScope) {
        self.storage = storage
        self.bookmarks = bookmarks
        self.requiresSecurityScope = requiresSecurityScope
    }

    func loadLocationURL() -> URL? {
        resolveLocation().accessibleURL
    }

    func resolveLocation() -> ArchiveLocationResolution {
        let pathURL = storage.string(forKey: AppModelPreferenceKey.archiveLocationPath)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let bookmarkData = storage.data(forKey: AppModelPreferenceKey.archiveLocationBookmarkData) {
            do {
                let resolution = try bookmarks.resolve(bookmarkData)
                if resolution.isStale {
                    let renewed = try bookmarks.create(resolution.url)
                    storage.set(renewed, forKey: AppModelPreferenceKey.archiveLocationBookmarkData)
                }
                storage.set(resolution.url.path, forKey: AppModelPreferenceKey.archiveLocationPath)
                return ArchiveLocationResolution(requestedURL: resolution.url, error: nil)
            } catch {
                // Preserve the saved choice for reauthorization, never treat its
                // plain path as a replacement for a failed security capability.
                return ArchiveLocationResolution(requestedURL: pathURL, error: .bookmarkUnavailable)
            }
        }
        return ArchiveLocationResolution(requestedURL: pathURL,
            error: pathURL.map { requiresSecurityScope && !bookmarks.hasPermanentAccess($0) } == true ? .bookmarkUnavailable : nil)
    }

    func saveLocationURL(_ url: URL?) throws {
        if let url {
            do {
                let bookmarkData = try bookmarks.create(url)
                // Commit only after the persistent capability is created.
                storage.set(bookmarkData, forKey: AppModelPreferenceKey.archiveLocationBookmarkData)
            } catch {
                guard !requiresSecurityScope || bookmarks.hasPermanentAccess(url) else { throw ArchiveFolderAccessError.bookmarkUnavailable }
                // Unsandboxed editions legitimately use ordinary filesystem
                // paths; they do not require a security-scoped capability.
                storage.removeObject(forKey: AppModelPreferenceKey.archiveLocationBookmarkData)
            }
            storage.set(url.path, forKey: AppModelPreferenceKey.archiveLocationPath)
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
