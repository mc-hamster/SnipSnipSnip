import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    static let isRunningUnitTests: Bool = {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
#if DEBUG
        return ProcessInfo.processInfo.arguments.contains(
            "--snipsnipsnip-composition-ui-testing"
        )
#else
        return false
#endif
    }()

    let lifecycle: AppLifecycleModel
    let capture: CaptureWorkflowModel
    let permissions: PermissionWorkflowModel
    let documents: DocumentWorkflowModel
    let clipboard: ClipboardWorkflowModel
    let video: VideoWorkflowModel
    let guide: GuideWorkflowModel
    let archive: ArchiveWorkflowModel
    let tools: ToolWorkflowModel
    let creation: CreationWorkflowModel
    let quickControls: QuickControlsModel
    let quickControlsCoordinator: QuickControlsCoordinator
    let workflowCoordinator: AppWorkflowCoordinator
    let environment: AppEnvironment
    var capabilities: AppCapabilitySnapshot { environment.capabilities }
    private var runtimeBindings: AppModelRuntimeBindings?
    let automation: AutomationWorkflowModel
    let automationService: AppAutomationService

    init(
        defaults: UserDefaults = .standard,
        environment: AppEnvironment? = nil,
        compositionOverrides: AppModelCompositionOverrides = AppModelCompositionOverrides(),
        shouldCheckCompatibilityOnLaunch: Bool = !AppModel.isRunningUnitTests,
        shouldStartArchiveMaintenance: Bool = true
    ) {
        let composition = AppModelComposition(
            defaults: defaults,
            environment: environment,
            overrides: compositionOverrides,
            shouldStartArchiveMaintenance: shouldStartArchiveMaintenance
        )
        self.environment = composition.environment
        self.lifecycle = composition.lifecycle
        self.capture = composition.capture
        self.permissions = composition.permissions
        self.documents = composition.documents
        self.clipboard = composition.clipboard
        self.video = composition.video
        self.guide = composition.guide
        self.archive = composition.archive
        self.tools = composition.tools
        self.creation = composition.creation
        let quickControls = QuickControlsModel(
            capabilities: composition.environment.capabilities,
            lifecycle: composition.lifecycle,
            capture: composition.capture,
            clipboard: composition.clipboard,
            video: composition.video,
            guide: composition.guide,
            tools: composition.tools,
            creation: composition.creation,
            preferenceStore: composition.environment.preferenceStores.quickControls
        )
        self.quickControls = quickControls
        self.quickControlsCoordinator = QuickControlsCoordinator(model: quickControls)
        self.automation = composition.automation
        self.automationService = AppAutomationService(host: composition.automation)
        self.workflowCoordinator = composition.workflowCoordinator
        runtimeBindings = AppModelRuntimeBindings(
            capabilities: composition.environment.capabilities,
            capture: composition.capture,
            workflowCoordinator: composition.workflowCoordinator,
            configuredArchiveLocationURL: composition.configuredArchiveLocationURL,
            shouldCheckCompatibilityOnLaunch: shouldCheckCompatibilityOnLaunch,
            shouldStartArchiveMaintenance: shouldStartArchiveMaintenance,
            isRunningUnitTests: Self.isRunningUnitTests
        )
    }

    nonisolated deinit {}

}
