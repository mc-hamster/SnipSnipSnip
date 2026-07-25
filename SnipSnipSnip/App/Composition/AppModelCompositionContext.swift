import Foundation

@MainActor
struct AppModelCompositionContext {
    let environment: AppEnvironment
    let preferenceStores: AppPreferenceStores
    let overrides: AppModelCompositionOverrides
    let configuredArchiveLocationURL: URL?
    let recoveryStore: DocumentRecoveryStore
    let clipboardHistoryStore: ClipboardHistoryStore
    let pendingRecoverySession: PendingRecoverySession?
    let shouldPresentOnboardingWindowOnLaunch: Bool
    let shouldPresentMainWindowOnLaunch: Bool
    let floatingReferenceCoordinator: FloatingReferenceCoordinator

    init(
        defaults: UserDefaults,
        environment providedEnvironment: AppEnvironment?,
        overrides: AppModelCompositionOverrides
    ) {
        let environment = providedEnvironment ?? AppEnvironment(defaults: defaults)
        let preferenceStores = environment.preferenceStores
        let configuredArchiveLocationURL = preferenceStores.archive.loadLocationURL()
        let recoveryStore = overrides.recoveryStore ?? DocumentRecoveryStore(baseURL: configuredArchiveLocationURL)
        let pendingRecoverySession = recoveryStore.latestPendingRecovery()

        self.environment = environment
        self.preferenceStores = preferenceStores
        self.overrides = overrides
        self.configuredArchiveLocationURL = configuredArchiveLocationURL
        self.recoveryStore = recoveryStore
        let clipboardPreferences = preferenceStores.clipboard.loadPreferences()
        self.clipboardHistoryStore = overrides.clipboardHistoryStore ?? ClipboardHistoryStore(
            loadStoredHistory: clipboardPreferences.isEnabled
        )
        self.pendingRecoverySession = pendingRecoverySession
        self.shouldPresentOnboardingWindowOnLaunch = preferenceStores.lifecycle.loadCompletedOnboardingVersion(
            currentVersion: AppLifecycleConstants.currentOnboardingVersion
        ) < AppLifecycleConstants.currentOnboardingVersion
            || preferenceStores.lifecycle.loadOnboardingResumeCheckpoint() != nil
        self.shouldPresentMainWindowOnLaunch = pendingRecoverySession != nil
        self.floatingReferenceCoordinator = FloatingReferenceCoordinator()
    }
}
