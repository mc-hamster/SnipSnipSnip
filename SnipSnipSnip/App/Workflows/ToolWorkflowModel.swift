import Combine
import Foundation

@MainActor
final class ToolWorkflowModel: ObservableObject {
    let screenRulerCoordinator: ScreenRulerCoordinator
    let screenInspectorCoordinator: ScreenInspectorCoordinator
    weak var outputSink: (any WorkflowOutputSink)?
    private let preferenceStore: ScreenToolPreferenceStore
    @Published var screenRulerPreferences: ScreenRulerPreferences {
        didSet {
            let sanitizedPreferences = screenRulerPreferences.sanitized()
            if sanitizedPreferences != screenRulerPreferences {
                screenRulerPreferences = sanitizedPreferences
                return
            }

            preferenceStore.saveRulerPreferences(screenRulerPreferences)
            screenRulerCoordinator.updatePreferences(screenRulerPreferences)
        }
    }
    @Published var screenInspectorPreferences: ScreenInspectorPreferences {
        didSet {
            let sanitizedPreferences = screenInspectorPreferences.sanitized()
            if sanitizedPreferences != screenInspectorPreferences {
                screenInspectorPreferences = sanitizedPreferences
                return
            }

            preferenceStore.saveInspectorPreferences(screenInspectorPreferences)
            screenInspectorCoordinator.updatePreferences(screenInspectorPreferences)
        }
    }

    init(
        screenRulerCoordinator: ScreenRulerCoordinator,
        screenInspectorCoordinator: ScreenInspectorCoordinator,
        preferenceStore: ScreenToolPreferenceStore,
        screenRulerPreferences: ScreenRulerPreferences,
        screenInspectorPreferences: ScreenInspectorPreferences
    ) {
        self.screenRulerCoordinator = screenRulerCoordinator
        self.screenInspectorCoordinator = screenInspectorCoordinator
        self.preferenceStore = preferenceStore
        self.screenRulerPreferences = screenRulerPreferences
        self.screenInspectorPreferences = screenInspectorPreferences
        bindCoordinatorHandlers()
    }

    func presentScreenRuler(_ kind: ScreenRulerKind) {
        screenRulerCoordinator.present(kind)
    }

    func closeAllScreenRulers() {
        screenRulerCoordinator.closeAll()
    }

    func presentScreenInspector(onClose: (() -> Void)? = nil) {
        screenInspectorCoordinator.present(onClose: onClose)
    }

    func toggleScreenInspector() {
        screenInspectorCoordinator.toggle()
    }

    func toggleScreenInspector(
        presentationContext: WorkflowPresentationContext
    ) {
        screenInspectorCoordinator.toggle(
            on: presentationContext.displayID
        )
    }

    func closeScreenInspector() {
        screenInspectorCoordinator.close()
    }

    private func bindCoordinatorHandlers() {
        screenRulerCoordinator.setPreferencesChangeHandler { [weak self] preferences in
            guard let self, self.screenRulerPreferences != preferences else {
                return
            }

            self.screenRulerPreferences = preferences
        }
        screenInspectorCoordinator.setPreferencesChangeHandler { [weak self] preferences in
            guard let self, self.screenInspectorPreferences != preferences else {
                return
            }

            self.screenInspectorPreferences = preferences
        }
        screenInspectorCoordinator.setSnipHandler { [weak self] sample in
            self?.outputSink?.handle(ToolWorkflowOutput.screenInspectorSnip(sample))
        }
    }
}
