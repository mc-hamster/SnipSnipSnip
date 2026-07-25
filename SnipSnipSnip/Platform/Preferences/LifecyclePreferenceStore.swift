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

    func loadOnboardingResumeCheckpoint() -> OnboardingResumeCheckpoint? {
        storage.string(forKey: AppModelPreferenceKey.onboardingResumeCheckpoint)
            .flatMap(OnboardingResumeCheckpoint.init(rawValue:))
    }

    func saveOnboardingResumeCheckpoint(_ checkpoint: OnboardingResumeCheckpoint?) {
        if let checkpoint {
            storage.set(checkpoint.rawValue, forKey: AppModelPreferenceKey.onboardingResumeCheckpoint)
        } else {
            storage.removeObject(forKey: AppModelPreferenceKey.onboardingResumeCheckpoint)
        }
    }

    func loadOnboardingClipboardChoiceAcknowledged() -> Bool {
        storage.bool(forKey: AppModelPreferenceKey.onboardingClipboardChoiceAcknowledged)
    }

    func saveOnboardingClipboardChoiceAcknowledged(_ acknowledged: Bool) {
        storage.set(acknowledged, forKey: AppModelPreferenceKey.onboardingClipboardChoiceAcknowledged)
    }

    func loadPostOnboardingDiscoveryPending() -> Bool {
        storage.bool(forKey: AppModelPreferenceKey.postOnboardingDiscoveryPending)
    }

    func savePostOnboardingDiscoveryPending(_ pending: Bool) {
        storage.set(pending, forKey: AppModelPreferenceKey.postOnboardingDiscoveryPending)
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
