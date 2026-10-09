import Foundation

@MainActor
struct AppModelCompositionContext {
    let environment: AppEnvironment
    let preferenceStores: AppPreferenceStores
    let overrides: AppModelCompositionOverrides
    let configuredArchiveLocationURL: URL?
    let archiveLocation: PreparedArchiveLocation
    let recoveryStore: DocumentRecoveryStore
    let videoRecoveryStore: VideoRecoveryStore
    let clipboardHistoryStore: ClipboardHistoryStore
    let pendingRecoverySession: PendingRecoverySession?
    let shouldPresentOnboardingWindowOnLaunch: Bool
    let shouldPresentMainWindowOnLaunch: Bool
    let floatingReferenceCoordinator: FloatingReferenceCoordinator
    let historyPreviewCoordinator: HistoryPreviewCoordinator

    init(
        defaults: UserDefaults,
        environment providedEnvironment: AppEnvironment?,
        overrides: AppModelCompositionOverrides
    ) {
        let environment = providedEnvironment ?? AppEnvironment(defaults: defaults)
        let preferenceStores = environment.preferenceStores
        let archiveLocation = PreparedArchiveLocation(preferences: preferenceStores.archive)
        let configuredArchiveLocationURL = archiveLocation.usableURL
        let recoveryStore = overrides.recoveryStore ?? DocumentRecoveryStore(
            baseURL: configuredArchiveLocationURL, folderAccess: archiveLocation.access)
        let videoRecoveryStore = overrides.videoRecoveryStore ?? VideoRecoveryStore(files: environment.systemServices.files)
        let pendingRecoverySession = recoveryStore.latestPendingRecovery()

        self.environment = environment
        self.preferenceStores = preferenceStores
        self.overrides = overrides
        self.configuredArchiveLocationURL = configuredArchiveLocationURL
        self.archiveLocation = archiveLocation
        self.recoveryStore = recoveryStore
        self.videoRecoveryStore = videoRecoveryStore
        let clipboardPreferences = preferenceStores.clipboard.loadPreferences()
        self.clipboardHistoryStore = overrides.clipboardHistoryStore ?? ClipboardHistoryStore(
            loadStoredHistory: clipboardPreferences.isEnabled
        )
        self.pendingRecoverySession = pendingRecoverySession
        self.shouldPresentOnboardingWindowOnLaunch = preferenceStores.lifecycle.loadCompletedOnboardingVersion(
            currentVersion: AppLifecycleConstants.currentOnboardingVersion
        ) < AppLifecycleConstants.currentOnboardingVersion
            || preferenceStores.lifecycle.loadOnboardingResumeCheckpoint() != nil
        self.shouldPresentMainWindowOnLaunch = pendingRecoverySession != nil || videoRecoveryStore.hasRecovery()
            || PermissionRestartStore(defaults: environment.defaults).load() != nil
            || archiveLocation.error != nil
        self.floatingReferenceCoordinator = FloatingReferenceCoordinator()
        self.historyPreviewCoordinator = HistoryPreviewCoordinator(
            files: environment.systemServices.files
        )
    }
}
