import AppKit
import Combine
import Foundation

@MainActor
protocol WorkflowLifecyclePresenting: AnyObject {
    func presentError(_ message: String)
    func clearError()
    func updateWorkingMessage(_ message: String)
    func requestMainWindowPresentation()
    func presentSettings(tab: AppSettingsTab)
}

extension WorkflowLifecyclePresenting {
    func presentSettings(tab: AppSettingsTab) {
        requestMainWindowPresentation()
    }
}

@MainActor
final class AppLifecycleModel: ObservableObject {
    @Published var selectedSettingsTab: AppSettingsTab = .general
    @Published var selectedLibrarySettingsSection: LibrarySettingsSection = .snips
    @Published var onboardingPresentationRequest = 0
    @Published var errorMessage: String? {
        didSet {
            if let errorMessage, errorMessage != oldValue {
                AppAccessibility.announce("Error: \(errorMessage)", priority: .high)
            }
        }
    }
    @Published var mainWindowPresentationRequest = 0
    @Published var workingMessage = "Capturing"
    @Published var isCheckingProUpdates = false
    @Published private(set) var onboardingPresentationMode: OnboardingPresentationMode
    @Published var confirmsBeforeQuitting: Bool {
        didSet {
            preferenceStore.saveConfirmsBeforeQuitting(confirmsBeforeQuitting)
        }
    }

    private let capabilities: AppCapabilitySnapshot
    let launchAtLoginController: LaunchAtLoginController
    private let preferenceStore: LifecyclePreferenceStore
    private let proUpdateFetcher: any ProUpdateReleaseFetching
    private let workspace: any WorkspaceServicing
    private var shouldPresentOnboardingWindowOnLaunch: Bool
    private var shouldPresentMainWindowOnLaunch: Bool
    private var shouldOpenMainWindowAfterOnboarding = false

    init(
        capabilities: AppCapabilitySnapshot,
        preferenceStore: LifecyclePreferenceStore,
        confirmsBeforeQuitting: Bool,
        launchAtLoginController: LaunchAtLoginController,
        workspace: any WorkspaceServicing,
        proUpdateFetcher: any ProUpdateReleaseFetching = URLSession.shared,
        shouldPresentOnboardingWindowOnLaunch: Bool,
        shouldPresentMainWindowOnLaunch: Bool
    ) {
        self.capabilities = capabilities
        self.preferenceStore = preferenceStore
        self.confirmsBeforeQuitting = confirmsBeforeQuitting
        self.launchAtLoginController = launchAtLoginController
        self.workspace = workspace
        self.proUpdateFetcher = proUpdateFetcher
        self.shouldPresentOnboardingWindowOnLaunch = shouldPresentOnboardingWindowOnLaunch
        self.shouldPresentMainWindowOnLaunch = shouldPresentMainWindowOnLaunch
        let hasCompletedCurrentOnboarding = preferenceStore.loadCompletedOnboardingVersion(
            currentVersion: AppLifecycleConstants.currentOnboardingVersion
        ) >= AppLifecycleConstants.currentOnboardingVersion
        self.onboardingPresentationMode = hasCompletedCurrentOnboarding ? .replay : .firstRun
    }

    var launchAtLoginStatus: LaunchAtLoginStatus {
        launchAtLoginController.status
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginController.refreshStatus()
    }

    @discardableResult
    func updateLaunchAtLoginEnabled(_ isEnabled: Bool) -> LaunchAtLoginActionResult {
        launchAtLoginController.setEnabled(isEnabled)
    }

    func openLaunchAtLoginSettings() {
        launchAtLoginController.openSystemSettings()
    }

    func dismissError() {
        clearError()
    }

    func presentError(_ message: String) {
        errorMessage = message
    }

    func clearError() {
        errorMessage = nil
    }

    func updateWorkingMessage(_ message: String) {
        workingMessage = message
    }

    func presentBusyHotKeyFeedback(message: String) {
        updateWorkingMessage(message)
        NSSound.beep()
    }

    func consumeOnboardingWindowPresentationFlag() -> Bool {
        guard shouldPresentOnboardingWindowOnLaunch else {
            return false
        }

        shouldPresentOnboardingWindowOnLaunch = false
        shouldOpenMainWindowAfterOnboarding = true
        return true
    }

    func consumeMainWindowPresentationFlag() -> Bool {
        guard shouldPresentMainWindowOnLaunch else {
            return false
        }

        shouldPresentMainWindowOnLaunch = false
        return true
    }

    func requestOnboardingPresentation() {
        shouldOpenMainWindowAfterOnboarding = false
        onboardingPresentationMode = .replay
        onboardingPresentationRequest += 1
    }

    func requestMainWindowPresentation() {
        mainWindowPresentationRequest += 1
    }

    func presentSettings(tab: AppSettingsTab) {
        selectedSettingsTab = tab
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    func presentLibrarySettings(_ section: LibrarySettingsSection) {
        selectedLibrarySettingsSection = section
        presentSettings(tab: .library)
    }

    func completeOnboarding(requestMainWindowPresentation: () -> Void) {
        preferenceStore.saveCompletedOnboardingVersion(AppLifecycleConstants.currentOnboardingVersion)
        preferenceStore.saveOnboardingResumeCheckpoint(nil)
        onboardingPresentationMode = .replay

        if shouldOpenMainWindowAfterOnboarding {
            requestMainWindowPresentation()
        }

        shouldOpenMainWindowAfterOnboarding = false
    }

    var onboardingResumeCheckpoint: OnboardingResumeCheckpoint? {
        preferenceStore.loadOnboardingResumeCheckpoint()
    }

    var hasAcknowledgedOnboardingClipboardChoice: Bool {
        preferenceStore.loadOnboardingClipboardChoiceAcknowledged()
    }

    func saveOnboardingResumeCheckpoint(_ checkpoint: OnboardingResumeCheckpoint?) {
        preferenceStore.saveOnboardingResumeCheckpoint(checkpoint)
    }

    func acknowledgeOnboardingClipboardChoice() {
        preferenceStore.saveOnboardingClipboardChoiceAcknowledged(true)
    }

    func skipOnboarding(requestMainWindowPresentation: () -> Void) {
        completeOnboarding(requestMainWindowPresentation: requestMainWindowPresentation)
    }

    func checkForProUpdates() {
        guard capabilities.isEnabled(.proUpdateCheck), !isCheckingProUpdates else {
            return
        }

        isCheckingProUpdates = true

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                let result = try await ProUpdateChecker.checkCurrentBuild(fetcher: self.proUpdateFetcher)
                self.presentProUpdateCheckResult(result)
            } catch {
                self.presentProUpdateCheckFailure(error)
            }

            self.isCheckingProUpdates = false
        }
    }

    private func presentProUpdateCheckResult(_ result: ProUpdateCheckResult) {
        let alert = NSAlert()
        alert.alertStyle = .informational

        if result.updateIsAvailable {
            alert.messageText = "A SnipSnipSnip Pro update is available"
            alert.informativeText = "\(result.latestRelease.name) is available. You are currently running \(result.currentDisplayVersion). Download the latest package from GitHub Releases."
            alert.addButton(withTitle: "Download Update")
            alert.addButton(withTitle: "Not Now")

            if alert.runModal() == .alertFirstButtonReturn {
                workspace.open(result.latestRelease.pageURL)
            }
        } else {
            alert.messageText = "SnipSnipSnip Pro is up to date"
            alert.informativeText = "You are running \(result.currentDisplayVersion). The latest GitHub release is \(result.latestRelease.name)."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func presentProUpdateCheckFailure(_: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't check for Pro updates"
        alert.informativeText = "SnipSnipSnip Pro could not read the latest GitHub release. You can open GitHub Releases and download the newest package manually."
        alert.addButton(withTitle: "Open GitHub Releases")
        alert.addButton(withTitle: "OK")

        if alert.runModal() == .alertFirstButtonReturn {
            workspace.open(AppLinks.proGitHubReleases)
        }
    }
}
