import Foundation

nonisolated struct LifecyclePreferenceStore {
    private let storage: PreferenceStorage

    init(storage: PreferenceStorage) {
        self.storage = storage
    }

    func loadCompletedOnboardingVersion(currentVersion: Int) -> Int {
        if let storedVersion = storage.object(forKey: AppModelPreferenceKey.completedOnboardingVersion) as? Int {
            return storedVersion
        }

        let hasLegacyWelcomeState = storage.object(forKey: AppModelPreferenceKey.hasPresentedWelcomeWindow) != nil
            || storage.object(forKey: AppModelPreferenceKey.hasDismissedWelcomeCard) != nil

        return hasLegacyWelcomeState ? currentVersion : 0
    }

    func saveCompletedOnboardingVersion(_ version: Int) {
        storage.set(version, forKey: AppModelPreferenceKey.completedOnboardingVersion)
    }

    func saveWelcomeCardDismissed() {
        storage.set(true, forKey: AppModelPreferenceKey.hasDismissedWelcomeCard)
    }

    func loadConfirmsBeforeQuitting() -> Bool {
        guard let storedValue = storage.object(forKey: AppLifecyclePreferenceKeys.confirmsBeforeQuitting) as? Bool else {
            return true
        }

        return storedValue
    }

    func saveConfirmsBeforeQuitting(_ confirmsBeforeQuitting: Bool) {
        storage.set(confirmsBeforeQuitting, forKey: AppLifecyclePreferenceKeys.confirmsBeforeQuitting)
    }
}
