import AppKit
import Combine
import Foundation

@MainActor
final class AppModelRuntimeBindings {
    private let globalHotKeyCoordinator: GlobalHotKeyCoordinator
    private var applicationActivationObserver: AnyCancellable?
    private var hotKeyPreferencesObserver: AnyCancellable?
    private var presetHotKeysObserver: AnyCancellable?

    init(
        capabilities: AppCapabilitySnapshot,
        capture: CaptureWorkflowModel,
        workflowCoordinator: AppWorkflowCoordinator,
        configuredArchiveLocationURL: URL?,
        shouldCheckCompatibilityOnLaunch: Bool,
        shouldStartArchiveMaintenance: Bool,
        isRunningUnitTests: Bool
    ) {
        globalHotKeyCoordinator = GlobalHotKeyCoordinator(
            actionHandler: { action in Task { @MainActor in workflowCoordinator.handleGlobalHotKeyAction(action) } },
            presetHandler: { presetID in Task { @MainActor in workflowCoordinator.handleGlobalPresetHotKey(presetID) } }
        )

        bindHotKeyPreferences(from: capture)
        activateStartupServices(
            capabilities: capabilities,
            workflowCoordinator: workflowCoordinator,
            configuredArchiveLocationURL: configuredArchiveLocationURL,
            shouldCheckCompatibilityOnLaunch: shouldCheckCompatibilityOnLaunch,
            shouldStartArchiveMaintenance: shouldStartArchiveMaintenance,
            isRunningUnitTests: isRunningUnitTests
        )
        if !isRunningUnitTests {
            bindExternalChangeNotifications(
                workflowCoordinator: workflowCoordinator
            )
        }
    }

    private func bindHotKeyPreferences(from capture: CaptureWorkflowModel) {
        configureHotKeys(from: capture.automationPreferences)
        configurePresetHotKeys(from: capture.capturePresets)
        hotKeyPreferencesObserver = capture.$automationPreferences
            .dropFirst()
            .sink { [weak self] preferences in
                self?.configureHotKeys(from: preferences)
            }
        presetHotKeysObserver = capture.$capturePresets
            .dropFirst()
            .sink { [weak self] presets in self?.configurePresetHotKeys(from: presets) }
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

    private func configurePresetHotKeys(from presets: [CapturePreset]) {
        globalHotKeyCoordinator.setPresetKeys(Dictionary(uniqueKeysWithValues: presets.compactMap { preset in
            preset.hotKey.map { (preset.id, $0) }
        }))
    }
}
