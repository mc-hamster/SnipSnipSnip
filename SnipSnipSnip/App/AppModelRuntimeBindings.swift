import AppKit
import Combine
import Foundation

@MainActor
final class AppModelRuntimeBindings {
    private let globalHotKeyCoordinator: GlobalHotKeyCoordinator
    private var applicationActivationObserver: AnyCancellable?
    private var hotKeyPreferencesObserver: AnyCancellable?

    init(
        capabilities: AppCapabilitySnapshot,
        capture: CaptureWorkflowModel,
        workflowCoordinator: AppWorkflowCoordinator,
        configuredArchiveLocationURL: URL?,
        shouldCheckCompatibilityOnLaunch: Bool,
        shouldStartArchiveMaintenance: Bool,
        isRunningUnitTests: Bool
    ) {
        globalHotKeyCoordinator = GlobalHotKeyCoordinator { action in
            Task { @MainActor in
                workflowCoordinator.handleGlobalHotKeyAction(action)
            }
        }

        bindHotKeyPreferences(from: capture)
        activateStartupServices(
            capabilities: capabilities,
            workflowCoordinator: workflowCoordinator,
            configuredArchiveLocationURL: configuredArchiveLocationURL,
            shouldCheckCompatibilityOnLaunch: shouldCheckCompatibilityOnLaunch,
            shouldStartArchiveMaintenance: shouldStartArchiveMaintenance,
            isRunningUnitTests: isRunningUnitTests
        )
        bindExternalChangeNotifications(
            workflowCoordinator: workflowCoordinator
        )
    }

    private func bindHotKeyPreferences(from capture: CaptureWorkflowModel) {
        configureHotKeys(from: capture.automationPreferences)
        hotKeyPreferencesObserver = capture.$automationPreferences
            .dropFirst()
            .sink { [weak self] preferences in
                self?.configureHotKeys(from: preferences)
            }
    }

    private func bindExternalChangeNotifications(
        workflowCoordinator: AppWorkflowCoordinator
    ) {
        applicationActivationObserver = NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )
        .sink { _ in
            Task { @MainActor in
                workflowCoordinator.handleApplicationDidBecomeActive()
            }
        }
    }

    private func activateStartupServices(
        capabilities: AppCapabilitySnapshot,
        workflowCoordinator: AppWorkflowCoordinator,
        configuredArchiveLocationURL: URL?,
        shouldCheckCompatibilityOnLaunch: Bool,
        shouldStartArchiveMaintenance: Bool,
        isRunningUnitTests: Bool
    ) {
        workflowCoordinator.activateStartupServices(
            capabilities: capabilities,
            configuredArchiveLocationURL: configuredArchiveLocationURL,
            shouldCheckCompatibilityOnLaunch: shouldCheckCompatibilityOnLaunch,
            shouldStartArchiveMaintenance: shouldStartArchiveMaintenance,
            isRunningUnitTests: isRunningUnitTests
        )
    }

    private func configureHotKeys(from preferences: CaptureAutomationPreferences) {
        globalHotKeyCoordinator.setActionKeys(preferences.actionKeys)
        globalHotKeyCoordinator.setEnabled(preferences.globalHotkeysEnabled)
    }
}
