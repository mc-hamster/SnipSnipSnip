import CoreGraphics
import XCTest
@testable import SnipSnipSnip

@MainActor
final class AppArchitecturePlatformTests: XCTestCase {
    func testCapabilityProviderMatchesFeatureFlagCompatibilityFacade() {
        let provider = BuildTargetCapabilityProvider()

        for target in [BuildTarget.dev, .internalTesting, .externalTesting, .release, .selfRelease] {
            let snapshot = provider.snapshot(for: target)

            XCTAssertEqual(snapshot.isEnabled(.scrollingCapture), FeatureFlags.scrollingCaptureEnabled(for: target))
            XCTAssertEqual(snapshot.isEnabled(.accessibilityAutomation), FeatureFlags.accessibilityAutomationEnabled(for: target))
            XCTAssertEqual(snapshot.isEnabled(.connectedDeviceCapture), FeatureFlags.connectedDeviceCaptureEnabled(for: target))
            XCTAssertEqual(snapshot.isEnabled(.uiMap), FeatureFlags.uiMapEnabled(for: target))
            XCTAssertEqual(snapshot.isEnabled(.proUpdateCheck), FeatureFlags.proUpdateCheckEnabled(for: target))

            XCTAssertTrue(snapshot.isEnabled(.regionCapture))
            XCTAssertTrue(snapshot.isEnabled(.windowCapture))
            XCTAssertTrue(snapshot.isEnabled(.fullscreenCapture))
            XCTAssertTrue(snapshot.isEnabled(.editor))
            XCTAssertTrue(snapshot.isEnabled(.automation))
            XCTAssertTrue(snapshot.isEnabled(.export))
        }
    }

    func testSystemCapturePermissionServiceReflectsInjectedSystemStateAndVerifier() async {
        let service = SystemCapturePermissionService(
            capabilities: capabilities([.screenRecording]),
            client: makePermissionClient(
                screenRecordingStatus: true,
                accessibilityStatus: false,
                verificationResult: false
            )
        )

        XCTAssertEqual(
            service.currentStatus(),
            CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: false)
        )
        let verifiedScreenRecordingAccess = await service.verifyScreenRecordingAccess()
        XCTAssertFalse(verifiedScreenRecordingAccess)
    }

    func testSystemCapturePermissionServiceGatesAccessibilityRequestsByCapability() {
        XCTAssertFalse(
            SystemCapturePermissionService(
                capabilities: capabilities([.screenRecording]),
                client: makePermissionClient()
            )
            .canRequest(.accessibility)
        )

        for capability in [AppCapability.scrollingCapture, .uiMap, .accessibilityAutomation, .guide] {
            let service = SystemCapturePermissionService(
                capabilities: capabilities([.screenRecording, capability]),
                client: makePermissionClient()
            )

            XCTAssertTrue(service.canRequest(.accessibility), "\(capability) should allow Accessibility requests.")
        }
    }

    func testReleaseGuideCanRequestAccessibilityWithoutMakingItAGlobalCaptureRequirement() {
        let capabilities = BuildTargetCapabilityProvider().snapshot(for: .release)
        let service = SystemCapturePermissionService(
            capabilities: capabilities,
            client: makePermissionClient()
        )
        let status = CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: false)

        XCTAssertTrue(capabilities.isEnabled(.guide))
        XCTAssertTrue(service.canRequest(.accessibility))
        XCTAssertTrue(status.missingRequirements(for: capabilities).isEmpty)
    }

    func testSystemCapturePermissionServiceDelegatesSystemActionsExactlyOnce() {
        let recorder = PermissionClientRecorder()
        let service = SystemCapturePermissionService(
            capabilities: capabilities([.screenRecording, .scrollingCapture]),
            client: makePermissionClient(
                screenRecordingStatus: true,
                accessibilityStatus: true,
                recorder: recorder,
                appName: "Test App",
                appPath: "/Applications/Test App.app",
                failureDetector: { $0 is SentinelPermissionError }
            )
        )

        XCTAssertEqual(service.currentAppName, "Test App")
        XCTAssertEqual(service.currentAppPath, "/Applications/Test App.app")

        XCTAssertTrue(service.requestAccess(for: .screenRecording))
        XCTAssertTrue(service.requestAccess(for: .accessibility))
        service.openSystemSettings(for: .screenRecording)
        service.revealCurrentAppInFinder()
        service.copyCurrentAppPathToPasteboard()

        XCTAssertTrue(service.indicatesScreenRecordingPermissionFailure(SentinelPermissionError()))
        XCTAssertEqual(recorder.screenRecordingRequestCount, 1)
        XCTAssertEqual(recorder.accessibilityRequestCount, 1)
        XCTAssertEqual(recorder.openedSettingsRequirementIDs, ["screen-recording"])
        XCTAssertEqual(recorder.revealCount, 1)
        XCTAssertEqual(recorder.copyPathCount, 1)
    }

    func testAppEnvironmentBuildsPermissionAndDomainServicesFromCapabilitySnapshot() async throws {
        let snapshot = capabilities([.screenRecording, .export], target: .release)
        let provider = CapabilityProviderSpy(snapshot: snapshot)
        let environment = AppEnvironment(
            defaults: makeDefaults(),
            buildTarget: .release,
            capabilityProvider: provider
        )

        XCTAssertEqual(provider.requestedTargets, [.release])
        XCTAssertEqual(environment.capabilities, snapshot)

        let permissionService = try XCTUnwrap(environment.permissions as? SystemCapturePermissionService)
        XCTAssertEqual(permissionService.capabilities, snapshot)

        let capturePermissionService = try XCTUnwrap(
            environment.makeScreenCaptureService().permissions as? SystemCapturePermissionService
        )
        XCTAssertEqual(capturePermissionService.capabilities, snapshot)

        let recordingPermissionService = try XCTUnwrap(
            environment.makeScreenRecordingService().permissions as? SystemCapturePermissionService
        )
        XCTAssertEqual(recordingPermissionService.capabilities, snapshot)

        let scrollingPermissionService = try XCTUnwrap(
            environment
                .makeScrollingCaptureService(captureService: environment.makeScreenCaptureService())
                .permissions as? SystemCapturePermissionService
        )
        XCTAssertEqual(scrollingPermissionService.capabilities, snapshot)

        let disabledCapture = CapturedScreenshot(
            image: makeImage(),
            kind: .fullscreen,
            sourceName: "Fullscreen",
            sourceRect: CGRect(x: 0, y: 0, width: 2, height: 2),
            capturedAt: Date()
        )
        let disabledUIMap = await environment.makeUIMapCaptureService().captureUIMap(for: disabledCapture)
        XCTAssertNil(disabledUIMap)

        let connectedDevices = await environment.makeConnectedDeviceCaptureService().listDevices()
        XCTAssertTrue(connectedDevices.isEmpty)
    }

    func testPreferenceStoresPreserveLegacyKeysAndFallbacks() throws {
        let defaults = makeDefaults()
        let stores = AppPreferenceStores(storage: defaults)

        defaults.set(Data([0xFF, 0x00]), forKey: AppModelPreferenceKey.capturePresets)
        defaults.set(0.25, forKey: AppModelPreferenceKey.screenshotJPEGQuality)
        defaults.set(true, forKey: AppModelPreferenceKey.autoCopyEnabled)
        defaults.set(Data([0x01]), forKey: AppModelPreferenceKey.screenRulerPreferences)

        XCTAssertTrue(stores.capture.loadCapturePresets().isEmpty)
        XCTAssertEqual(stores.capture.loadScreenshotJPEGQuality(), ImageExportOptions.sanitizedJPEGQuality(0.25))
        XCTAssertTrue(stores.clipboard.loadAutoCopyEnabled())
        XCTAssertEqual(stores.screenTools.loadRulerPreferences(), .default)

        let presets = [
            CapturePreset(
                name: "Full",
                target: .fullscreen,
                options: CaptureRunOptions()
            )
        ]
        stores.capture.saveCapturePresets(presets)
        XCTAssertEqual(AppPreferenceStores(storage: defaults).capture.loadCapturePresets(), presets)
    }

    func testAutomationPresetResolverFindsByIDAndCaseInsensitiveName() {
        let preset = CapturePreset(
            name: "Design Review",
            target: .fullscreen,
            options: CaptureRunOptions()
        )
        let resolver = AutomationPresetResolver(presets: [preset])

        XCTAssertEqual(resolver.resolve(RunPresetAutomationCommand(id: preset.id)), preset)
        XCTAssertEqual(resolver.resolve(RunPresetAutomationCommand(name: "design review")), preset)
        XCTAssertNil(resolver.resolve(RunPresetAutomationCommand(name: "missing")))
    }

    func testAnnotationDescriptorsCoverEveryKind() {
        let image = makeImage()
        let kinds: [AnnotationKind] = [
            .rectangle(RectangleShape(rect: CGRect(x: 0, y: 0, width: 10, height: 10))),
            .ellipse(EllipseShape(rect: CGRect(x: 0, y: 0, width: 10, height: 10))),
            .line(LineShape(start: .zero, end: CGPoint(x: 10, y: 10))),
            .arrow(ArrowShape(start: .zero, end: CGPoint(x: 10, y: 10))),
            .statusMark(StatusMarkShape(rect: CGRect(x: 0, y: 0, width: 10, height: 10))),
            .freehand(FreehandShape(points: [.zero, CGPoint(x: 10, y: 10)])),
            .highlighter(HighlighterShape(points: [.zero, CGPoint(x: 10, y: 10)])),
            .highlight(HighlightShape(rect: CGRect(x: 0, y: 0, width: 10, height: 10))),
            .text(TextShape(rect: CGRect(x: 0, y: 0, width: 10, height: 10), text: "A")),
            .callout(CalloutShape(rect: CGRect(x: 0, y: 0, width: 10, height: 10), number: 1, text: "A")),
            .measurement(MeasurementShape(start: .zero, end: CGPoint(x: 10, y: 10))),
            .spotlight(SpotlightShape(rect: CGRect(x: 0, y: 0, width: 10, height: 10))),
            .imageOverlay(ImageOverlayShape(assetID: UUID(), rect: CGRect(x: 0, y: 0, width: 10, height: 10), image: image)),
            .redaction(RedactionShape(rect: CGRect(x: 0, y: 0, width: 10, height: 10), mode: .solid)),
        ]

        for kind in kinds {
            let descriptor = kind.descriptor
            XCTAssertFalse(descriptor.displayName.isEmpty)
            XCTAssertEqual(kind.editorTool, descriptor.editorTool)
            XCTAssertEqual(kind.supportsFillEditing, descriptor.supportsFillEditing)
        }
        XCTAssertTrue(AnnotationKind.text(TextShape(rect: .zero, text: "")).isTextEditable)
        XCTAssertEqual(AnnotationKind.redaction(RedactionShape(rect: .zero, mode: .blur)).redactionMode, .blur)
    }

    func testExtractedRenderGeometryPreservesArrowBodyAndLabelBasics() {
        let shape = ArrowShape(
            start: CGPoint(x: 10, y: 10),
            end: CGPoint(x: 110, y: 30),
            curvature: 24,
            label: "Step 1",
            labelPlacement: .parallelAbove
        )

        XCTAssertFalse(EditorRenderGeometry.arrowBodyPath(for: shape).boundingBoxOfPath.isEmpty)
        XCTAssertFalse(AnnotationGeometry.arrowLabelRect(for: shape).isEmpty)
        XCTAssertFalse(EditorRenderGeometry.arrowLabelGeometry(for: shape, yAxisPointsDown: false).rect.isEmpty)
        XCTAssertNotEqual(
            EditorRenderGeometry.arrowLabelGeometry(for: shape, yAxisPointsDown: false).rect,
            EditorRenderGeometry.arrowLabelGeometry(for: shape, yAxisPointsDown: true).rect
        )
    }

    func testAppModelBoundariesDoNotReachBackToGlobalFlagsOrDefaults() throws {
        let guardedFiles = [
            "SnipSnipSnip/App/AppModel.swift",
            "SnipSnipSnip/App/Workflows/Archive/ArchiveWorkflowModel+Archive.swift",
            "SnipSnipSnip/App/Workflows/Capture/CaptureWorkflowModel+Commands.swift",
            "SnipSnipSnip/App/Workflows/Capture/CaptureWorkflowModel+Completion.swift",
            "SnipSnipSnip/App/Workflows/Capture/CaptureWorkflowModel+ConnectedDevice.swift",
            "SnipSnipSnip/App/Workflows/Capture/CaptureWorkflowModel+Execution.swift",
            "SnipSnipSnip/App/Workflows/Capture/CaptureWorkflowModel+PermissionGate.swift",
            "SnipSnipSnip/App/Workflows/Capture/CaptureWorkflowModel+Presets.swift",
            "SnipSnipSnip/App/Workflows/Capture/CaptureWorkflowModel+Scrolling.swift",
            "SnipSnipSnip/App/Workflows/Capture/CaptureWorkflowModel+WindowCapture.swift",
            "SnipSnipSnip/App/Workflows/Capture/CaptureWorkflowModel+Windows.swift",
            "SnipSnipSnip/App/Workflows/Clipboard/ClipboardWorkflowModel+Clipboard.swift",
            "SnipSnipSnip/App/Workflows/Document/DocumentWorkflowModel+EditorSession.swift",
            "SnipSnipSnip/App/Workflows/Document/DocumentWorkflowModel+Recovery.swift",
            "SnipSnipSnip/App/Workflows/Document/DocumentWorkflowModel+History.swift",
            "SnipSnipSnip/App/Workflows/Permission/PermissionWorkflowModel.swift",
            "SnipSnipSnip/App/Workflows/Permission/PermissionWorkflowModel+Requests.swift",
            "SnipSnipSnip/App/Workflows/Permission/PermissionWorkflowModel+SetupGuide.swift",
            "SnipSnipSnip/App/Workflows/Permission/PermissionWorkflowModel+Verification.swift",
            "SnipSnipSnip/App/Workflows/Video/VideoWorkflowModel+Recording.swift",
        ]
        let disallowedFragments = [
            "FeatureFlags.",
            "UserDefaults.standard",
        ]

        for file in guardedFiles {
            let contents = try String(contentsOf: repositoryRoot.appendingPathComponent(file), encoding: .utf8)
            for fragment in disallowedFragments {
                XCTAssertFalse(
                    contents.contains(fragment),
                    "\(file) should use AppEnvironment capabilities and preference stores instead of \(fragment)"
                )
            }
        }
    }

    func testAppModelShellDoesNotOwnPublishedWorkflowState() throws {
        let appModelURL = repositoryRoot.appendingPathComponent("SnipSnipSnip/App/AppModel.swift")
        let appModel = try String(contentsOf: appModelURL, encoding: .utf8)
        let composition = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/AppModelComposition.swift"),
            encoding: .utf8
        )
        let workflowModels = try workflowSource()
        let appModelLineCount = appModel.split(separator: "\n", omittingEmptySubsequences: false).count
        let compositionLineCount = composition.split(separator: "\n", omittingEmptySubsequences: false).count

        XCTAssertFalse(
            appModel.contains("@Published"),
            "AppModel should stay a shell and must not regain domain @Published state."
        )
        XCTAssertFalse(
            appModel.contains("import AppKit"),
            "AppModel should not import AppKit; AppKit details belong in workflows, presenters, or platform adapters."
        )
        XCTAssertFalse(
            appModel.contains("objectWillChange.send()") || appModel.contains("notifyObjectWillChange"),
            "AppModel should not forward workflow change notifications; views and commands should observe workflows directly."
        )
        XCTAssertLessThanOrEqual(
            appModelLineCount,
            150,
            "AppModel should keep shrinking; add behavior to workflows instead of growing the shell."
        )
        XCTAssertTrue(
            appModel.contains("AppModelComposition("),
            "AppModel should delegate workflow construction to AppModelComposition instead of accumulating a giant initializer."
        )
        XCTAssertLessThanOrEqual(
            compositionLineCount,
            120,
            "AppModelComposition should stay a wiring sequence; move domain construction recipes into focused composition helpers."
        )
        XCTAssertTrue(
            composition.contains("AppModelCompositionContext(")
                && composition.contains("Self.makeCaptureWorkflow(")
                && composition.contains("Self.makeDocumentWorkflow(")
                && composition.contains("Self.makeWorkflowCoordinator(")
                && composition.contains("Self.wireWorkflowReferences("),
            "AppModelComposition should orchestrate focused composition helpers instead of owning domain construction inline."
        )
        for forbiddenCompositionDetail in [
            "CaptureWorkflowDependencies(",
            "DocumentWorkflowDependencies(",
            "ClipboardWorkflowDependencies(",
            "VideoWorkflowDependencies(",
            "ArchiveWorkflowDependencies(",
        ] {
            XCTAssertFalse(
                composition.contains(forbiddenCompositionDetail),
                "Domain dependency recipes belong in App/Composition helper files, not AppModelComposition.swift: \(forbiddenCompositionDetail)"
            )
        }
        XCTAssertTrue(
            appModel.contains("AppModelRuntimeBindings("),
            "AppModel should delegate runtime observers and startup bindings instead of owning them directly."
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Workflows/AppWorkflowModels.swift").path),
            "Workflow declarations should stay split by domain instead of returning to a central AppWorkflowModels.swift file."
        )
        for forbiddenShellFragment in [
            "var editorController:",
            "var videoEditorController:",
            "var autoCopyEnabled:",
            "var captureDelay:",
            "var screenshotJPEGQuality:",
            "var permissionStatus:",
            "var pendingAutosaveTask:",
            "var activeVideoRecording:",
            "var archiveMaintenanceTask:",
            "var editableRedactionSaveConfirmationHandler:",
            "var shouldPresentOnboardingWindowOnLaunch",
            "var shouldPresentMainWindowOnLaunch",
            "func consumeOnboardingWindowPresentationFlag(",
            "func consumeMainWindowPresentationFlag(",
            "func requestOnboardingPresentation(",
            "func completeOnboarding(",
            "func skipOnboarding(",
            "func dismissWelcomeCard(",
            "func checkForProUpdates(",
            "func presentProUpdateCheckResult(",
            "func presentProUpdateCheckFailure(",
            "func handleGlobalHotKeyAction(",
            "func presentBusyHotKeyFeedback(",
            "var canResetPreferencesToDefaults",
            "func resetPreferencesToDefaults(",
            "FloatingReferenceCoordinator",
            "floatingReferenceCoordinator",
            "cachedAutomationService",
            "var automationService",
            "DocumentRecoveryStore",
            "ClipboardHistoryStore",
            "ScreenCaptureServiceType",
            "ScreenRecordingService",
            "UIMapCaptureServiceType",
            "ConnectedDeviceCaptureServiceType",
            "IncompatibleDocumentCoordinator",
            "LaunchAtLoginController"
        ] {
            XCTAssertFalse(
                appModel.contains(forbiddenShellFragment),
                "Production AppModel should not expose compatibility forwarding: \(forbiddenShellFragment)"
            )
        }
        XCTAssertTrue(
            appModel.contains("compositionOverrides: AppModelCompositionOverrides"),
            "Production AppModel should receive test/domain substitutions through a single composition override value."
        )
        for forbiddenCompositionFragment in [
            "CaptureWorkflowDependencies(",
            "DocumentWorkflowDependencies(",
            "ClipboardWorkflowDependencies(",
            "VideoWorkflowDependencies(",
            "ArchiveWorkflowDependencies("
        ] {
            XCTAssertFalse(
                appModel.contains(forbiddenCompositionFragment),
                "Workflow dependency construction belongs in AppModelComposition, not AppModel."
            )
        }
        XCTAssertFalse(
            workflowModels.contains("AppEnvironment"),
            "Workflows should receive narrow dependency structs/ports instead of the whole AppEnvironment."
        )
        XCTAssertTrue(
            workflowModels.contains("protocol WorkflowLifecyclePresenting"),
            "Shared lifecycle presentation/status access should be expressed as a narrow workflow port."
        )
        XCTAssertTrue(
            workflowModels.contains("func presentError(_ message: String)")
                && workflowModels.contains("func updateWorkingMessage(_ message: String)")
                && workflowModels.contains("func presentPresentationExperimentalNotice()"),
            "WorkflowLifecyclePresenting should expose lifecycle commands instead of mutable state."
        )
        XCTAssertTrue(
            workflowModels.contains("extension AppLifecycleModel: WorkflowLifecyclePresenting"),
            "AppLifecycleModel should explicitly satisfy the narrow lifecycle presentation port."
        )
        XCTAssertFalse(
            workflowModels.contains("let lifecycle: AppLifecycleModel"),
            "Workflows should receive WorkflowLifecyclePresenting instead of the concrete AppLifecycleModel."
        )
        for forbiddenLifecycleMutation in [
            "dependencies.lifecycle.errorMessage",
            "dependencies.lifecycle.workingMessage",
            "dependencies.lifecycle.isShowingPresentationExperimentalNotice",
            "lifecycle?.errorMessage",
            "lifecycle?.onboardingPresentationRequest",
        ] {
            XCTAssertFalse(
                workflowModels.contains(forbiddenLifecycleMutation),
                "Workflow/coordinator lifecycle effects should use command methods instead of storage access: \(forbiddenLifecycleMutation)"
            )
        }

        for toolCommand in [
            "func presentScreenRuler(",
            "func closeAllScreenRulers(",
            "func presentScreenInspector(",
            "func toggleScreenInspector(",
            "func closeScreenInspector(",
        ] {
            XCTAssertFalse(
                appModel.contains(toolCommand),
                "Tool commands belong to ToolWorkflowModel, not AppModel."
            )
            XCTAssertTrue(
                workflowModels.contains(toolCommand),
                "Expected ToolWorkflowModel command missing: \(toolCommand)"
            )
        }

        for lifecycleMember in [
            "var launchAtLoginStatus:",
            "func refreshLaunchAtLoginStatus(",
            "func updateLaunchAtLoginEnabled(",
            "func openLaunchAtLoginSettings(",
            "func consumeOnboardingWindowPresentationFlag(",
            "func consumeMainWindowPresentationFlag(",
            "func requestOnboardingPresentation(",
            "func completeOnboarding(",
            "func skipOnboarding(",
            "func dismissWelcomeCard(",
            "func checkForProUpdates(",
        ] {
            XCTAssertFalse(
                appModel.contains(lifecycleMember),
                "Lifecycle command ownership belongs to AppLifecycleModel, not AppModel."
            )
            XCTAssertTrue(
                workflowModels.contains(lifecycleMember),
                "Expected AppLifecycleModel member missing: \(lifecycleMember)"
            )
        }

        for workflow in [
            "final class AppLifecycleModel: ObservableObject",
            "final class PermissionWorkflowModel: ObservableObject",
            "final class CaptureWorkflowModel: ObservableObject",
            "final class DocumentWorkflowModel: ObservableObject",
            "final class ClipboardWorkflowModel: ObservableObject",
            "final class VideoWorkflowModel: ObservableObject",
            "final class ArchiveWorkflowModel: ObservableObject",
            "final class ToolWorkflowModel: ObservableObject",
        ] {
            XCTAssertTrue(
                workflowModels.contains(workflow),
                "Expected workflow owner missing: \(workflow)"
            )
        }
    }

    func testWorkflowsDoNotExposeMutableCallbackHooksForCrossDomainEffects() throws {
        let files = try productionSwiftFiles()

        for forbiddenHook in [
            "automationPreferencesChangeHandler",
            "autoCopyChangeHandler",
            "maintenanceRequestHandler",
        ] {
            try assertFragment(
                forbiddenHook,
                in: files,
                isOnlyUsedIn: []
            )
        }

        let coordinator = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Workflows/AppWorkflowCoordinator.swift"),
            encoding: .utf8
        )
        let workflowModels = try workflowSource()
        XCTAssertTrue(
            coordinator.contains("protocol WorkflowOutputSink"),
            "Workflows that only emit domain outputs should depend on a sink protocol, not the concrete coordinator."
        )
        XCTAssertTrue(
            coordinator.contains("case .autoCopyChanged(let enabled):"),
            "Clipboard preference changes should route through typed workflow output instead of mutable runtime callback hooks."
        )
        XCTAssertTrue(
            workflowModels.contains("weak var outputSink: (any WorkflowOutputSink)?"),
            "ClipboardWorkflowModel should emit through WorkflowOutputSink instead of holding a concrete coordinator reference."
        )
        XCTAssertTrue(
            workflowModels.contains("enum ToolWorkflowOutput")
                && workflowModels.contains("case screenInspectorSnip(ScreenInspectorSample)")
                && workflowModels.contains("func handle(_ output: ToolWorkflowOutput)"),
            "Screen Inspector snips should route as typed tool workflow output."
        )

        let runtimeBindings = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/AppModelRuntimeBindings.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            runtimeBindings.contains("capture.$automationPreferences"),
            "Runtime hotkey configuration should observe capture preferences without injecting callback storage into CaptureWorkflowModel."
        )
        XCTAssertFalse(
            runtimeBindings.contains("AppModel.isRunningUnitTests"),
            "Runtime bindings should not reference the AppModel shell type directly."
        )
        XCTAssertFalse(
            runtimeBindings.contains("objectWillChange.sink")
                || runtimeBindings.contains("notifyObjectWillChange")
                || runtimeBindings.contains("objectWillChange.send()"),
            "Runtime bindings should not preserve the old synthetic AppModel mega-publisher."
        )
        for forbiddenRuntimeStartupFragment in [
            "PackageTemporaryDirectoryJanitor",
            "handleIncompatibleRecoveryEntriesOnLaunch()",
            "startArchiveMaintenance()",
            "refreshConnectedDevices()",
            "monitor.start",
        ] {
            XCTAssertFalse(
                runtimeBindings.contains(forbiddenRuntimeStartupFragment),
                "Runtime bindings should delegate product startup through AppWorkflowCoordinator, not own \(forbiddenRuntimeStartupFragment)."
            )
        }
        XCTAssertTrue(
            runtimeBindings.contains("workflowCoordinator.activateStartupServices("),
            "Runtime startup should enter the typed workflow coordinator boundary."
        )
        for forbiddenRuntimeHandlerFragment in [
            "setSnipHandler",
            "setPreferencesChangeHandler",
            "completeScreenInspectorSnip",
            "screenRulerCoordinator",
            "screenInspectorCoordinator",
        ] {
            XCTAssertFalse(
                runtimeBindings.contains(forbiddenRuntimeHandlerFragment),
                "Runtime bindings should not own workflow coordinator callback wiring: \(forbiddenRuntimeHandlerFragment)."
            )
        }
    }

    func testAppModelHasNoProductionBehaviorExtensions() throws {
        let files = try productionSwiftFiles()
        let appModelExtensionFiles = files
            .map(relativePath(for:))
            .filter { path in
                path.hasPrefix("SnipSnipSnip/App/AppModel+")
                    || path.hasPrefix("SnipSnipSnip/Automation/AppModel+")
            }

        XCTAssertTrue(
            appModelExtensionFiles.isEmpty,
            "AppModel behavior extensions should stay deleted. Move behavior to workflow owners instead: \(appModelExtensionFiles)"
        )

        for file in files {
            let relativePath = relativePath(for: file)
            guard relativePath != "SnipSnipSnip/App/AppModel.swift" else {
                continue
            }

            let contents = try String(contentsOf: file, encoding: .utf8)
            XCTAssertNil(
                contents.range(of: #"(?m)^\s*extension\s+AppModel\b"#, options: .regularExpression),
                "\(relativePath) must not add production AppModel extensions; add behavior to a workflow owner or coordinator."
            )
        }
    }

    func testCaptureWorkflowOwnsGenericCaptureExecutionAndCoordinatorDoesNotRouteItThroughAppModel() throws {
        let appModel = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/AppModel.swift"),
            encoding: .utf8
        )
        let appModelCaptureURL = repositoryRoot.appendingPathComponent("SnipSnipSnip/App/AppModel+Capture.swift")
        let captureExecution = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Workflows/Capture/CaptureWorkflowModel+Execution.swift"),
            encoding: .utf8
        )
        let captureCommands = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Workflows/Capture/CaptureWorkflowModel+Commands.swift"),
            encoding: .utf8
        )
        let captureScrolling = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Workflows/Capture/CaptureWorkflowModel+Scrolling.swift"),
            encoding: .utf8
        )
        let captureWindowCapture = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Workflows/Capture/CaptureWorkflowModel+WindowCapture.swift"),
            encoding: .utf8
        )
        let captureCompletion = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Workflows/Capture/CaptureWorkflowModel+Completion.swift"),
            encoding: .utf8
        )
        let capturePresets = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Workflows/Capture/CaptureWorkflowModel+Presets.swift"),
            encoding: .utf8
        )
        let captureWindows = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Workflows/Capture/CaptureWorkflowModel+Windows.swift"),
            encoding: .utf8
        )
        let capturePermissionGate = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Workflows/Capture/CaptureWorkflowModel+PermissionGate.swift"),
            encoding: .utf8
        )
        let permissionWorkflow = try workflowSource()
        let capturePorts = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Workflows/Capture/CaptureWorkflowPorts.swift"),
            encoding: .utf8
        )
        let captureModel = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Workflows/Capture/CaptureWorkflowModel.swift"),
            encoding: .utf8
        )
        let captureAutomation = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Workflows/Capture/CaptureWorkflowModel+Automation.swift"),
            encoding: .utf8
        )
        let captureConnectedDevice = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Workflows/Capture/CaptureWorkflowModel+ConnectedDevice.swift"),
            encoding: .utf8
        )
        let appWindowPresenter = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Presentation/AppWindowPresenter.swift"),
            encoding: .utf8
        )
        let coordinator = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Workflows/AppWorkflowCoordinator.swift"),
            encoding: .utf8
        )
        let captureModelLineCount = captureModel.split(separator: "\n", omittingEmptySubsequences: false).count
        let captureCommandLineCount = captureCommands.split(separator: "\n", omittingEmptySubsequences: false).count
        let captureScrollingLineCount = captureScrolling.split(separator: "\n", omittingEmptySubsequences: false).count
        let captureWindowCaptureLineCount = captureWindowCapture.split(separator: "\n", omittingEmptySubsequences: false).count

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: appModelCaptureURL.path),
            "AppModel+Capture.swift should stay deleted; capture execution, completion, windows, permissions, and preset policy belong to CaptureWorkflowModel."
        )
        XCTAssertLessThanOrEqual(
            captureModelLineCount,
            170,
            "CaptureWorkflowModel.swift should stay focused on capture state/dependencies; move behavior into domain extensions."
        )
        XCTAssertLessThanOrEqual(
            captureCommandLineCount,
            560,
            "CaptureWorkflowModel+Commands.swift should not become the new capture mini-AppModel; split feature-specific command paths into focused extensions."
        )
        XCTAssertLessThanOrEqual(
            captureScrollingLineCount,
            160,
            "CaptureWorkflowModel+Scrolling.swift should stay focused on scrolling capture entrypoints and execution."
        )
        XCTAssertLessThanOrEqual(
            captureWindowCaptureLineCount,
            250,
            "CaptureWorkflowModel+WindowCapture.swift should stay focused on window picker/capture entrypoints."
        )
        XCTAssertFalse(
            captureModel.contains("func runAutomationPreset(") || captureModel.contains("func captureAutomation("),
            "Capture automation behavior belongs in CaptureWorkflowModel+Automation.swift, not the capture state declaration."
        )
        XCTAssertTrue(
            captureAutomation.contains("func runAutomationPreset(") && captureAutomation.contains("func captureAutomation("),
            "CaptureWorkflowModel+Automation.swift should own capture automation behavior."
        )
        XCTAssertTrue(
            captureExecution.contains("func performCapture("),
            "CaptureWorkflowModel should own generic capture execution."
        )
        XCTAssertTrue(
            capturePorts.contains("protocol CaptureAutomationCoordinatorPort"),
            "Capture automation should depend on a narrow coordinator port instead of concrete AppWorkflowCoordinator."
        )
        XCTAssertTrue(
            capturePorts.contains("protocol CaptureDocumentWorkflowPort"),
            "Capture should depend on a narrow document port instead of the concrete DocumentWorkflowModel."
        )
        XCTAssertTrue(
            capturePorts.contains("protocol CaptureVideoWorkflowPort"),
            "Capture should depend on a narrow video port instead of the concrete VideoWorkflowModel."
        )
        XCTAssertTrue(
            captureModel.contains("weak var outputSink: (any WorkflowOutputSink)?"),
            "CaptureWorkflowModel should emit domain outputs through WorkflowOutputSink."
        )
        XCTAssertTrue(
            captureModel.contains("weak var automationCoordinator: (any CaptureAutomationCoordinatorPort)?"),
            "CaptureWorkflowModel should use a narrow automation coordinator port."
        )
        XCTAssertTrue(
            captureModel.contains("weak var documents: (any CaptureDocumentWorkflowPort)?"),
            "CaptureWorkflowModel should store the document port, not DocumentWorkflowModel."
        )
        XCTAssertTrue(
            captureModel.contains("weak var video: (any CaptureVideoWorkflowPort)?"),
            "CaptureWorkflowModel should store the video port, not VideoWorkflowModel."
        )
        XCTAssertFalse(
            captureModel.contains("AppWorkflowCoordinator"),
            "CaptureWorkflowModel should not store the concrete workflow coordinator."
        )
        XCTAssertFalse(
            captureModel.contains("weak var documents: DocumentWorkflowModel?"),
            "CaptureWorkflowModel must not regain a direct DocumentWorkflowModel reference."
        )
        XCTAssertFalse(
            captureModel.contains("weak var video: VideoWorkflowModel?"),
            "CaptureWorkflowModel must not regain a direct VideoWorkflowModel reference."
        )
        XCTAssertTrue(
            captureModel.contains("let appWindowPresenter: any AppWindowPresenting"),
            "CaptureWorkflowDependencies should receive app-window presentation through a narrow presenter port."
        )
        XCTAssertTrue(
            captureModel.contains("let lifecycle: any WorkflowLifecyclePresenting"),
            "CaptureWorkflowDependencies should receive lifecycle UI state through a narrow port."
        )
        XCTAssertFalse(
            captureModel.contains("let lifecycle: AppLifecycleModel"),
            "CaptureWorkflowDependencies must not regain a concrete AppLifecycleModel dependency."
        )
        for lifecycleConsumer in [
            captureExecution,
            captureCommands,
            captureScrolling,
            captureWindowCapture,
            captureCompletion,
            capturePresets,
            captureWindows,
            capturePermissionGate,
            captureConnectedDevice,
        ] {
            XCTAssertFalse(
                lifecycleConsumer.contains("mainWindowPresentationRequest +="),
                "Capture workflow code should request window presentation through WorkflowLifecyclePresenting."
            )
        }
        XCTAssertFalse(
            captureExecution.contains("NSApp.") || captureExecution.contains("NSWindow"),
            "CaptureWorkflowModel+Execution.swift should route app-window hide/restore mechanics through AppWindowPresenting."
        )
        XCTAssertFalse(
            captureConnectedDevice.contains("NSApp.activate"),
            "Connected-device capture should route app activation through AppWindowPresenting."
        )
        XCTAssertTrue(
            captureExecution.contains("dependencies.appWindowPresenter.hideAppWindowIfNeeded()"),
            "Capture app-window hiding should route through AppWindowPresenting."
        )
        XCTAssertTrue(
            captureExecution.contains("dependencies.appWindowPresenter.restoreAppWindowIfNeeded(token)"),
            "Capture app-window restoration should route through AppWindowPresenting."
        )
        XCTAssertTrue(
            appWindowPresenter.contains("final class LiveAppWindowPresenter: AppWindowPresenting"),
            "App-window visibility mechanics should be isolated behind the live app-window presenter."
        )
        XCTAssertTrue(
            appWindowPresenter.contains("NSApp.windows") && appWindowPresenter.contains("ScreenRulerWindowID.isScreenRulerWindow"),
            "The live app-window presenter should own NSApp window lookup and screen-ruler filtering."
        )
        XCTAssertTrue(
            appWindowPresenter.contains("func activateApp()") && appWindowPresenter.contains("NSApp.activate(ignoringOtherApps: true)"),
            "The live app-window presenter should own app activation."
        )
        XCTAssertTrue(
            captureCompletion.contains("func completeCapture("),
            "CaptureWorkflowModel should own capture completion and emit typed coordinator output."
        )
        XCTAssertTrue(
            captureCompletion.contains("func completeScreenInspectorSnip("),
            "CaptureWorkflowModel should own Screen Inspector snip completion and emit typed coordinator output."
        )
        XCTAssertTrue(
            captureCompletion.contains("CaptureWorkflowResult("),
            "Capture completion should publish typed workflow results instead of reaching into document or clipboard workflows."
        )
        XCTAssertFalse(
            captureCompletion.contains("scheduleClipboardSnipRecording"),
            "Clipboard history routing belongs to AppWorkflowCoordinator and ClipboardWorkflowModel, not CaptureWorkflowModel."
        )
        XCTAssertFalse(
            captureCompletion.contains("scheduleAutoCopy"),
            "Auto-copy routing belongs to AppWorkflowCoordinator and DocumentWorkflowModel, not CaptureWorkflowModel."
        )
        XCTAssertTrue(
            coordinator.contains("documents.installCapturedScreenshot(result)"),
            "AppWorkflowCoordinator should route completed captures into DocumentWorkflowModel."
        )
        XCTAssertTrue(
            coordinator.contains("clipboard?.scheduleClipboardSnipRecording"),
            "AppWorkflowCoordinator should route non-private completed captures into ClipboardWorkflowModel."
        )
        XCTAssertTrue(
            captureWindows.contains("func loadAvailableWindows("),
            "CaptureWorkflowModel should own window listing and thumbnail refresh."
        )
        XCTAssertTrue(
            capturePresets.contains("func commitCapturePresetName()"),
            "CaptureWorkflowModel should own capture preset policy."
        )
        for scrollingMember in [
            "func captureScrollingArea(",
            "func beginScrollingCapture(",
            "func repeatScrollingCapture(",
            "func performScrollingCapture(",
        ] {
            XCTAssertFalse(
                captureCommands.contains(scrollingMember),
                "Scrolling capture behavior belongs in CaptureWorkflowModel+Scrolling.swift, not generic command routing: \(scrollingMember)"
            )
            XCTAssertTrue(
                captureScrolling.contains(scrollingMember),
                "Expected scrolling capture member missing: \(scrollingMember)"
            )
        }
        for windowCaptureMember in [
            "func presentWindowPicker(",
            "func pickWindowOnScreen(",
            "func captureWindow(",
            "func beginWindowPickerPresentation(",
            "func replaceWindowTargetAndCapturePreset(",
            "func pickWindowOnScreenForPresetReplacement(",
            "func repeatWindowCapture(",
            "func capturePresetWindow(",
        ] {
            XCTAssertFalse(
                captureCommands.contains(windowCaptureMember),
                "Window capture behavior belongs in CaptureWorkflowModel+WindowCapture.swift, not generic command routing: \(windowCaptureMember)"
            )
            XCTAssertTrue(
                captureWindowCapture.contains(windowCaptureMember),
                "Expected window capture member missing: \(windowCaptureMember)"
            )
        }

        for permissionMember in [
            "func refreshPermissions(",
            "func requestPermission(",
            "func requestNextMissingSetupRequirement(",
            "func openPermissionSettings(",
            "func dismissPermissionSetupGuide(",
            "func revealAppForPermissionSetup(",
            "func copyAppPathForPermissionSetup(",
            "func openPermissionSettingsFromGuide(",
            "func checkPermissionSetupGuideStatus(",
            "func presentPermissionSetupGuide(",
            "func reconcileScreenRecordingPermissionDenied(",
        ] {
            XCTAssertFalse(
                appModel.contains(permissionMember) || capturePermissionGate.contains(permissionMember),
                "Permission setup/request behavior belongs to PermissionWorkflowModel, not AppModel or CaptureWorkflowModel: \(permissionMember)"
            )
            XCTAssertTrue(
                permissionWorkflow.contains(permissionMember),
                "Expected PermissionWorkflowModel permission member missing: \(permissionMember)"
            )
        }
        XCTAssertTrue(
            capturePermissionGate.contains("var windowUIMapNeedsAccessibilityAccess:"),
            "Capture may expose UI Map access status as capture-specific derived state."
        )
        XCTAssertTrue(
            capturePermissionGate.contains("func retryPendingPermissionCommandIfSatisfied(")
                && capturePermissionGate.contains("PendingCapturePermissionCommand"),
            "Capture should own typed pending capture commands instead of storing permission-owned closures."
        )
        XCTAssertFalse(
            permissionWorkflow.contains("PendingPermissionAction"),
            "Permission retries should not be hidden in closure-backed permission state."
        )

        for commandMember in [
            "func captureCurrentDisplay(",
            "func captureRegion(",
            "func captureScrollingArea(",
            "func captureFrontmostWindow(",
            "func presentWindowPicker(",
            "func repeatLastCapture(",
            "func refreshAvailableWindows(",
            "func refreshAvailableWindowsOrRequestAccess(",
            "func pickWindowOnScreen(",
            "func captureWindow(",
            "func replaceWindowTargetAndCapturePreset(",
            "func pickWindowOnScreenForPresetReplacement(",
        ] {
            XCTAssertFalse(
                appModel.contains(commandMember),
                "Capture commands belong to CaptureWorkflowModel, not AppModel: \(commandMember)"
            )
            XCTAssertTrue(
                captureCommands.contains(commandMember)
                    || captureExecution.contains(commandMember)
                    || captureScrolling.contains(commandMember)
                    || captureWindowCapture.contains(commandMember)
                    || captureWindows.contains(commandMember)
                    || capturePresets.contains(commandMember)
                    || captureCompletion.contains(commandMember),
                "Expected CaptureWorkflowModel command missing: \(commandMember)"
            )
        }

        for forbiddenCoordinatorHook in [
            "var canRepeatLastCapture:",
            "var capturePreset:",
            "var beginRegionCapture:",
            "var presentWindowPicker:",
            "var repeatLastCapture:",
            "var openDocument:",
            "var saveDocument:",
            "var floatCurrentEditorReference:",
            "var automationResultAfterCurrentEditorOutput:",
            "var refreshPermissions:",
            "var isRecordingVideo:",
            "var currentCaptureRunOptions:",
            "var currentEditorController:",
            "var automationImageExportOptions:",
            "var requestMainWindowPresentation:",
            "var presentError:",
            "var performCapture:",
        ] {
            XCTAssertFalse(
                coordinator.contains(forbiddenCoordinatorHook),
                "AppWorkflowCoordinator should not route capture execution through mutable AppModel-style closure hook \(forbiddenCoordinatorHook)"
            )
        }

        XCTAssertNil(
            coordinator.range(
                of: #"(?m)^\s*var\s+\w+\s*:\s*\([^)]*\)\s*(?:async\s*)?->"#,
                options: .regularExpression
            ),
            "AppWorkflowCoordinator should not grow mutable closure hooks; add explicit typed methods or workflow outputs instead."
        )
        XCTAssertFalse(
            appModel.contains("bindWorkflowCoordinatorActions"),
            "AppModel should not bind coordinator callback closures; coordinator routing should be explicit and workflow-owned."
        )
    }

    func testDocumentWorkflowDependsOnNarrowWorkflowPorts() throws {
        let workflowModels = try workflowSource()
        let documentModel = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Workflows/Document/DocumentWorkflowModel.swift"),
            encoding: .utf8
        )
        let documentAutomation = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Workflows/Document/DocumentWorkflowModel+Automation.swift"),
            encoding: .utf8
        )
        let documentPorts = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Workflows/Document/DocumentWorkflowPorts.swift"),
            encoding: .utf8
        )
        let documentEditorSession = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Workflows/Document/DocumentWorkflowModel+EditorSession.swift"),
            encoding: .utf8
        )
        let documentFileOperations = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Workflows/Document/DocumentWorkflowModel+FileOperations.swift"),
            encoding: .utf8
        )
        let documentHistory = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Workflows/Document/DocumentWorkflowModel+History.swift"),
            encoding: .utf8
        )
        let documentSettings = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Workflows/Document/DocumentWorkflowModel+Settings.swift"),
            encoding: .utf8
        )
        let documentPanelPresenter = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Presentation/DocumentPanelPresenter.swift"),
            encoding: .utf8
        )
        let documentWindowPresenter = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Presentation/DocumentWindowPresenter.swift"),
            encoding: .utf8
        )
        let documentPasteboardImporter = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Presentation/DocumentPasteboardImporter.swift"),
            encoding: .utf8
        )
        let documentDependenciesStart = try XCTUnwrap(documentModel.range(of: "struct DocumentWorkflowDependencies"))
        let documentDependenciesEnd = try XCTUnwrap(
            documentModel.range(
                of: "final class DocumentWorkflowModel",
                range: documentDependenciesStart.upperBound..<documentModel.endIndex
            )
        ).lowerBound
        let documentDependencies = String(documentModel[documentDependenciesStart.lowerBound..<documentDependenciesEnd])

        for expectedPort in [
            "protocol DocumentCaptureWorkflowPort",
            "protocol DocumentClipboardWorkflowPort",
            "protocol DocumentVideoWorkflowPort",
            "protocol DocumentArchiveWorkflowPort",
            "protocol DocumentPanelPresenting",
            "protocol DocumentWindowPresenting",
            "protocol DocumentPasteboardImporting",
            "protocol DocumentAutomationCoordinatorPort",
            "protocol ClipboardDocumentWorkflowPort",
            "protocol VideoDocumentWorkflowPort",
            "protocol ArchiveDocumentWorkflowPort",
        ] {
            XCTAssertTrue(
                documentPorts.contains(expectedPort),
                "Workflow cross-domain access should be expressed as narrow ports: \(expectedPort)"
            )
        }

        for expectedDependency in [
            "let lifecycle: any WorkflowLifecyclePresenting",
            "let capture: any DocumentCaptureWorkflowPort",
            "let clipboard: any DocumentClipboardWorkflowPort",
            "let video: any DocumentVideoWorkflowPort",
            "let archive: any DocumentArchiveWorkflowPort",
            "let panels: any DocumentPanelPresenting",
            "let windowPresenter: any DocumentWindowPresenting",
            "let pasteboardImporter: any DocumentPasteboardImporting",
        ] {
            XCTAssertTrue(
                documentDependencies.contains(expectedDependency),
                "DocumentWorkflowDependencies should use narrow ports: \(expectedDependency)"
            )
        }

        for forbiddenDependency in [
            "let lifecycle: AppLifecycleModel",
            "let capture: CaptureWorkflowModel",
            "let clipboard: ClipboardWorkflowModel",
            "let video: VideoWorkflowModel",
            "let archive: ArchiveWorkflowModel",
        ] {
            XCTAssertFalse(
                documentDependencies.contains(forbiddenDependency),
                "DocumentWorkflowDependencies must not regain concrete workflow coupling: \(forbiddenDependency)"
            )
        }

        for forbiddenMutablePortFragment in [
            "var pendingWindowThumbnailTask",
            "var isWorking: Bool { get set }",
            "var recoveryStore: DocumentRecoveryStore { get set }",
            "var pendingAutosaveTask",
            "var pendingRecoveryRefreshTask",
            "var pendingCaptureHistorySearchTask",
            "var pendingRecoveryWriteTasks",
            "var lastAutosavedState",
            "var currentRecoverySessionID: UUID? { get set }",
        ] {
            XCTAssertFalse(
                documentPorts.contains(forbiddenMutablePortFragment),
                "Document workflow ports should expose intentful commands, not mutable workflow internals: \(forbiddenMutablePortFragment)"
            )
        }
        for expectedCommandPort in [
            "func cancelPendingWindowThumbnailRefresh()",
            "func performDocumentWork<Result>(",
            "func prepareForArchiveClear() async",
            "func rebindRecoveryStore(_ store: DocumentRecoveryStore)",
            "func reseedRecoverySessionAfterArchiveChange()",
        ] {
            XCTAssertTrue(
                documentPorts.contains(expectedCommandPort),
                "Cross-workflow coordination should use explicit command ports: \(expectedCommandPort)"
            )
        }

        for expectedBackreference in [
            "weak var documents: (any CaptureDocumentWorkflowPort)?",
            "weak var documents: (any ClipboardDocumentWorkflowPort)?",
            "weak var documents: (any VideoDocumentWorkflowPort)?",
            "weak var documents: (any ArchiveDocumentWorkflowPort)?",
        ] {
            XCTAssertTrue(
                workflowModels.contains(expectedBackreference),
                "Workflow document backreferences should stay port-shaped: \(expectedBackreference)"
            )
        }

        XCTAssertFalse(
            workflowModels.contains("weak var documents: DocumentWorkflowModel?"),
            "Workflows must not regain direct DocumentWorkflowModel backreferences."
        )
        XCTAssertFalse(
            documentEditorSession.contains("dependencies.archive.maintenanceRequestHandler"),
            "DocumentWorkflowModel should call the archive port instead of reaching into archive closure storage."
        )
        XCTAssertTrue(
            documentEditorSession.contains("dependencies.archive.triggerArchiveMaintenance()"),
            "DocumentWorkflowModel should request archive maintenance through DocumentArchiveWorkflowPort."
        )
        XCTAssertFalse(
            documentEditorSession.contains("NSOpenPanel"),
            "DocumentWorkflowModel should use DocumentPanelPresenting instead of creating open panels directly."
        )
        XCTAssertFalse(
            documentFileOperations.contains("NSOpenPanel"),
            "Document file operations should use DocumentPanelPresenting instead of creating open panels directly."
        )
        XCTAssertFalse(
            documentSettings.contains("NSOpenPanel"),
            "Document settings should use DocumentPanelPresenting instead of creating folder selection panels directly."
        )
        XCTAssertFalse(
            documentEditorSession.contains("NSSavePanel"),
            "DocumentWorkflowModel should use DocumentPanelPresenting instead of creating save panels directly."
        )
        XCTAssertFalse(
            documentFileOperations.contains("NSSavePanel"),
            "Document file operations should use DocumentPanelPresenting instead of creating save panels directly."
        )
        XCTAssertFalse(
            documentEditorSession.contains("NSPasteboard"),
            "DocumentWorkflowModel should use DocumentPasteboardImporting instead of reaching into named pasteboards directly."
        )
        XCTAssertFalse(
            documentFileOperations.contains("NSPasteboard"),
            "Document file operations should use DocumentPasteboardImporting instead of reaching into named pasteboards directly."
        )
        XCTAssertFalse(
            documentEditorSession.contains("NSScreen.main") || documentEditorSession.contains("NSScreen.screens"),
            "DocumentWorkflowModel+EditorSession.swift should use injected screen topology for fallback screen data."
        )
        XCTAssertFalse(
            documentEditorSession.contains("NSApp.windows"),
            "DocumentWorkflowModel+EditorSession.swift should route main-window mutation through DocumentWindowPresenting."
        )
        XCTAssertFalse(
            documentEditorSession.contains("mainWindowPresentationRequest +=")
                || documentFileOperations.contains("mainWindowPresentationRequest +=")
                || documentHistory.contains("mainWindowPresentationRequest +="),
            "Document workflow code should request window presentation through WorkflowLifecyclePresenting."
        )
        XCTAssertTrue(
            documentEditorSession.contains("dependencies.windowPresenter.syncMainWindowDocumentState("),
            "Document main-window document state should route through DocumentWindowPresenting."
        )
        XCTAssertTrue(
            documentEditorSession.contains("dependencies.windowPresenter.resizeMainWindowForContent("),
            "Document main-window resizing should route through DocumentWindowPresenting."
        )
        XCTAssertTrue(
            documentWindowPresenter.contains("struct LiveDocumentWindowPresenter: DocumentWindowPresenting"),
            "AppKit main-window mutation should be isolated behind the live document window presenter."
        )
        XCTAssertTrue(
            documentWindowPresenter.contains("NSApp.windows"),
            "The live document window presenter should own AppKit main-window lookup."
        )
        XCTAssertTrue(
            documentWindowPresenter.contains("screens.mainScreen") || documentWindowPresenter.contains("screens.screens"),
            "The live document window presenter should use injected screen topology for fallback screen data."
        )
        XCTAssertTrue(
            documentFileOperations.contains("dependencies.panels.selectDocumentToOpen()"),
            "Document open presentation should route through DocumentPanelPresenting."
        )
        XCTAssertTrue(
            documentFileOperations.contains("dependencies.panels.selectImageToImport()"),
            "Document image import presentation should route through DocumentPanelPresenting."
        )
        XCTAssertTrue(
            documentFileOperations.contains("dependencies.panels.selectSaveDestination("),
            "Document save presentation should route through DocumentPanelPresenting."
        )
        XCTAssertTrue(
            documentSettings.contains("dependencies.panels.selectPresentationScenesRoot(initialDirectory: presentationScenesRootURL)"),
            "Presentation scene folder selection should route through DocumentPanelPresenting."
        )
        XCTAssertTrue(
            documentFileOperations.contains("dependencies.pasteboardImporter.imageData(fromPasteboardNamed:"),
            "Shared image imports should read named pasteboards through DocumentPasteboardImporting."
        )
        XCTAssertTrue(
            documentFileOperations.contains("dependencies.pasteboardImporter.clearPasteboard(named:"),
            "Shared image imports should clear named pasteboards through DocumentPasteboardImporting."
        )
        for fileOperationMember in [
            "func openDocumentPanel()",
            "func saveCurrentDocument()",
            "func saveDocument(_ controller: EditorController, to url: URL)",
            "func loadDocument(from url: URL)",
            "func importImage(from url: URL)",
            "enum DocumentPackageWriter",
        ] {
            XCTAssertFalse(
                documentEditorSession.contains(fileOperationMember),
                "Document file operations should stay out of DocumentWorkflowModel+EditorSession.swift: \(fileOperationMember)"
            )
            XCTAssertTrue(
                documentFileOperations.contains(fileOperationMember),
                "DocumentWorkflowModel+FileOperations.swift should own: \(fileOperationMember)"
            )
        }
        for historyMember in [
            "func handleIncompatibleRecoveryEntriesOnLaunch()",
            "func reloadRecoveryPresentationStateFromStore()",
            "func initialCaptureHistoryIndexImage(",
            "var filteredCaptureHistoryEntries:",
            "var captureHistorySearchResultsLabel:",
            "func scheduleIndexedCaptureHistorySearch()",
            "func indexCurrentCaptureIfNeeded(",
            "func currentProtectedTemporaryVideoURLs()",
            "func currentOwnedTemporaryVideoSourceURL(",
            "func cleanupTemporaryVideoSourceIfNeeded(",
        ] {
            XCTAssertFalse(
                documentEditorSession.contains(historyMember),
                "Document history and temporary-media retention should stay out of DocumentWorkflowModel+EditorSession.swift: \(historyMember)"
            )
            XCTAssertTrue(
                documentHistory.contains(historyMember),
                "DocumentWorkflowModel+History.swift should own: \(historyMember)"
            )
        }
        XCTAssertLessThanOrEqual(
            documentEditorSession.split(separator: "\n", omittingEmptySubsequences: false).count,
            700,
            "DocumentWorkflowModel+EditorSession.swift should keep shrinking instead of becoming the new AppModel."
        )
        XCTAssertLessThanOrEqual(
            documentFileOperations.split(separator: "\n", omittingEmptySubsequences: false).count,
            500,
            "DocumentWorkflowModel+FileOperations.swift should stay focused on document file I/O."
        )
        XCTAssertLessThanOrEqual(
            documentHistory.split(separator: "\n", omittingEmptySubsequences: false).count,
            220,
            "DocumentWorkflowModel+History.swift should stay focused on history/search and temporary media retention."
        )
        XCTAssertTrue(
            documentPanelPresenter.contains("struct LiveDocumentPanelPresenter: DocumentPanelPresenting"),
            "AppKit document panel construction should be isolated behind the live document panel presenter."
        )
        XCTAssertTrue(
            documentPanelPresenter.contains("NSOpenPanel"),
            "The live document panel presenter should own document and image open panels."
        )
        XCTAssertTrue(
            documentPanelPresenter.contains("NSSavePanel"),
            "The live document panel presenter should own document save panels."
        )
        XCTAssertTrue(
            documentPasteboardImporter.contains("struct LiveDocumentPasteboardImporter: DocumentPasteboardImporting"),
            "AppKit named pasteboard access should be isolated behind the live document pasteboard importer."
        )
        XCTAssertTrue(
            documentPasteboardImporter.contains("NSPasteboard"),
            "The live document pasteboard importer should own named pasteboard access."
        )
        XCTAssertTrue(
            documentModel.contains("weak var automationCoordinator: (any DocumentAutomationCoordinatorPort)?"),
            "DocumentWorkflowModel should see automation coordination through a narrow port, not concrete AppWorkflowCoordinator."
        )
        XCTAssertFalse(
            documentModel.contains("AppWorkflowCoordinator"),
            "DocumentWorkflowModel must not regain concrete coordinator coupling."
        )
        for forbiddenAutomationMethod in [
            "func openAutomationDocument(",
            "func exportCurrentAutomationDocument(",
        ] {
            XCTAssertFalse(
                documentModel.contains(forbiddenAutomationMethod),
                "Automation command handling should live in DocumentWorkflowModel+Automation.swift, not the main document state file."
            )
            XCTAssertTrue(
                documentAutomation.contains(forbiddenAutomationMethod),
                "DocumentWorkflowModel+Automation.swift should own document automation command handling."
            )
        }
        XCTAssertLessThanOrEqual(
            documentModel.split(separator: "\n", omittingEmptySubsequences: false).count,
            250,
            "DocumentWorkflowModel.swift should stay focused; split domain behavior into targeted extensions before it becomes another AppModel."
        )
    }

    func testWorkflowCoordinatorDependsOnCoordinatorPorts() throws {
        let coordinator = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Workflows/AppWorkflowCoordinator.swift"),
            encoding: .utf8
        )
        let coordinatorPorts = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Workflows/AppWorkflowCoordinatorPorts.swift"),
            encoding: .utf8
        )
        let composition = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/AppModelComposition.swift"),
            encoding: .utf8
        )
        let coordinatorWiring = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Composition/AppModelComposition+CoordinatorWiring.swift"),
            encoding: .utf8
        )
        let coordinatorFactoryStart = try XCTUnwrap(
            coordinatorWiring.range(of: "static func makeWorkflowCoordinator(")
        )
        let coordinatorFactoryEnd = try XCTUnwrap(
            coordinatorWiring.range(
                of: "static func wireWorkflowReferences(",
                range: coordinatorFactoryStart.upperBound..<coordinatorWiring.endIndex
            )
        ).lowerBound
        let coordinatorFactory = String(
            coordinatorWiring[coordinatorFactoryStart.lowerBound..<coordinatorFactoryEnd]
        )

        for expectedPort in [
            "protocol CoordinatorLifecyclePort",
            "protocol CoordinatorPermissionPort",
            "protocol CoordinatorCapturePort",
            "protocol CoordinatorDocumentPort",
            "protocol CoordinatorClipboardPort",
            "protocol CoordinatorAutomationPort",
            "protocol CoordinatorVideoPort",
            "protocol CoordinatorArchivePort",
            "protocol CoordinatorToolPort",
        ] {
            XCTAssertTrue(
                coordinatorPorts.contains(expectedPort),
                "Coordinator cross-workflow access should be expressed as narrow ports: \(expectedPort)"
            )
        }
        XCTAssertTrue(
            coordinatorPorts.contains("extension AppWorkflowCoordinator: CaptureAutomationCoordinatorPort"),
            "Capture automation should see the coordinator through the narrow capture automation port."
        )
        XCTAssertTrue(
            coordinatorPorts.contains("extension AppWorkflowCoordinator: DocumentAutomationCoordinatorPort"),
            "Document automation should see the coordinator through the narrow document automation port."
        )

        for expectedStorage in [
            "private weak var lifecycle: (any CoordinatorLifecyclePort)?",
            "private weak var permissions: (any CoordinatorPermissionPort)?",
            "private weak var capture: (any CoordinatorCapturePort)?",
            "private weak var documents: (any CoordinatorDocumentPort)?",
            "private weak var clipboard: (any CoordinatorClipboardPort)?",
            "private weak var video: (any CoordinatorVideoPort)?",
            "private weak var archive: (any CoordinatorArchivePort)?",
            "private weak var tools: (any CoordinatorToolPort)?",
            "private weak var automation: (any CoordinatorAutomationPort)?",
        ] {
            XCTAssertTrue(
                coordinator.contains(expectedStorage),
                "AppWorkflowCoordinator should store ports instead of concrete workflows: \(expectedStorage)"
            )
        }

        for forbiddenConcreteStorage in [
            "private weak var lifecycle: AppLifecycleModel?",
            "private weak var permissions: PermissionWorkflowModel?",
            "private weak var capture: CaptureWorkflowModel?",
            "private weak var documents: DocumentWorkflowModel?",
            "private weak var clipboard: ClipboardWorkflowModel?",
            "private weak var video: VideoWorkflowModel?",
            "private weak var archive: ArchiveWorkflowModel?",
            "private weak var tools: ToolWorkflowModel?",
            "private weak var automation: AutomationWorkflowModel?",
        ] {
            XCTAssertFalse(
                coordinator.contains(forbiddenConcreteStorage),
                "AppWorkflowCoordinator must not regain concrete workflow storage: \(forbiddenConcreteStorage)"
            )
        }

        for forbiddenInitializerArgument in [
            "video: VideoWorkflowModel",
            "archive: ArchiveWorkflowModel",
            "tools: ToolWorkflowModel",
        ] {
            XCTAssertFalse(
                coordinator.contains(forbiddenInitializerArgument),
                "AppWorkflowCoordinator should accept workflow ports, not concrete workflow dependencies: \(forbiddenInitializerArgument)"
            )
            XCTAssertFalse(
                coordinatorFactory.contains(forbiddenInitializerArgument),
                "AppModelComposition coordinator factory should pass ports into AppWorkflowCoordinator: \(forbiddenInitializerArgument)"
            )
        }

        for expectedCoordinatorConstructionArgument in [
            "video: videoWorkflow",
            "archive: archiveWorkflow",
            "tools: toolWorkflow",
        ] {
            XCTAssertTrue(
                composition.contains(expectedCoordinatorConstructionArgument),
                "AppModelComposition should wire all coordinator ports needed for cross-workflow commands."
            )
        }
        for expectedCoordinatorFactoryPort in [
            "video: any CoordinatorVideoPort",
            "archive: any CoordinatorArchivePort",
            "tools: any CoordinatorToolPort",
            "automation: any CoordinatorAutomationPort",
        ] {
            XCTAssertTrue(
                coordinatorFactory.contains(expectedCoordinatorFactoryPort),
                "AppModelComposition coordinator factory should remain port-shaped: \(expectedCoordinatorFactoryPort)"
            )
        }

        XCTAssertTrue(
            coordinator.contains("func handleGlobalHotKeyAction("),
            "Global hotkey routing should be owned by AppWorkflowCoordinator, not AppModel."
        )
        XCTAssertTrue(
            coordinator.contains("func resetPreferencesToDefaults("),
            "Reset-all-preferences orchestration should be owned by AppWorkflowCoordinator, not AppModel."
        )
        XCTAssertTrue(
            coordinator.contains("func activateStartupServices("),
            "Startup orchestration should be owned by AppWorkflowCoordinator through workflow ports, not AppModelRuntimeBindings."
        )
        XCTAssertTrue(
            coordinatorPorts.contains("func requestMainWindowPresentation()"),
            "Coordinator lifecycle presentation should be a command method, not direct mutable state access."
        )
        XCTAssertFalse(
            coordinatorPorts.contains("var mainWindowPresentationRequest"),
            "CoordinatorLifecyclePort should not expose AppLifecycleModel storage directly."
        )
        XCTAssertFalse(
            coordinatorPorts.contains("{ get set }"),
            "Coordinator ports should expose command methods instead of mutable workflow state setters."
        )
        XCTAssertFalse(
            coordinatorPorts.contains("var errorMessage") || coordinatorPorts.contains("var onboardingPresentationRequest"),
            "CoordinatorLifecyclePort should expose lifecycle commands instead of mutable AppLifecycleModel properties."
        )
        XCTAssertTrue(
            coordinatorPorts.contains("func refreshPermissions()")
                && coordinatorPorts.contains("func checkPermissionSetupGuideStatus()"),
            "Coordinator permission routing should command the PermissionWorkflowModel instead of capture-owned permission helpers."
        )
        XCTAssertTrue(
            coordinator.contains("case .requirementsMayNowBeSatisfied(let status):")
                && coordinator.contains("capture?.retryPendingPermissionCommandIfSatisfied(status)"),
            "Permission changes should route through typed permission output and typed capture retry commands."
        )
        XCTAssertTrue(
            coordinatorPorts.contains("func setConnectedDeviceSessionActive(_ isActive: Bool)"),
            "Connected-device session updates should route through a capture command instead of a mutable setter requirement."
        )
        XCTAssertTrue(
            coordinatorPorts.contains("func resetCapturePreferencesToDefaults()"),
            "Capture reset defaults should belong to the capture workflow through its coordinator port."
        )
        XCTAssertTrue(
            coordinatorPorts.contains("func resetDocumentPreferencesToDefaults()"),
            "Document reset defaults should belong to the document workflow through its coordinator port."
        )
        XCTAssertTrue(
            coordinatorPorts.contains("func resetClipboardPreferencesToDefaults()"),
            "Clipboard reset defaults should belong to the clipboard workflow through its coordinator port."
        )
        XCTAssertTrue(
            coordinatorPorts.contains("func resetVideoPreferencesToDefaults()"),
            "Video reset defaults should belong to the video workflow through its coordinator port."
        )
        XCTAssertTrue(
            coordinatorPorts.contains("func resetArchivePreferencesToDefaults()"),
            "Archive reset defaults should belong to the archive workflow through its coordinator port."
        )
        XCTAssertTrue(
            coordinatorPorts.contains("func resetToolPreferencesToDefaults()"),
            "Tool reset defaults should belong to the tool workflow through its coordinator port."
        )
        for expectedStartupPort in [
            "func refreshConnectedDevices()",
            "func completeScreenInspectorSnip(_ sample: ScreenInspectorSample)",
            "func handleIncompatibleRecoveryEntriesOnLaunch()",
            "func cleanupStalePackageTemporaryDirectories()",
            "func startMonitoring()",
            "func activateArchiveDirectoryAccess(_ url: URL?)",
            "func startArchiveMaintenance()",
        ] {
            XCTAssertTrue(
                coordinatorPorts.contains(expectedStartupPort),
                "Startup actions should route through typed coordinator ports: \(expectedStartupPort)"
            )
        }

        XCTAssertTrue(
            coordinator.contains("capture?.notifyPermissionsChanged()"),
            "Permission change fanout should route through CoordinatorCapturePort instead of reaching into objectWillChange."
        )
        XCTAssertTrue(
            coordinator.contains("clipboard?.notifyDocumentChanged()"),
            "Document change fanout should route through CoordinatorClipboardPort instead of reaching into objectWillChange."
        )
        XCTAssertFalse(
            coordinator.contains("objectWillChange.send()"),
            "AppWorkflowCoordinator should not reach into workflow publisher internals."
        )
    }

    func testArchiveWorkflowUsesLocationPresenterInsteadOfDirectPanel() throws {
        let archiveModel = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Workflows/Archive/ArchiveWorkflowModel.swift"),
            encoding: .utf8
        )
        let archiveWorkflow = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Workflows/Archive/ArchiveWorkflowModel+Archive.swift"),
            encoding: .utf8
        )
        let archiveLocationPresenter = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Presentation/ArchiveLocationPresenter.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            archiveModel.contains("protocol ArchiveLocationPresenting"),
            "Archive location selection should be exposed as a presenter port."
        )
        XCTAssertTrue(
            archiveModel.contains("let locationPresenter: any ArchiveLocationPresenting"),
            "ArchiveWorkflowDependencies should receive a narrow archive location presenter."
        )
        XCTAssertTrue(
            archiveModel.contains("let lifecycle: any WorkflowLifecyclePresenting"),
            "ArchiveWorkflowDependencies should receive lifecycle UI state through a narrow port."
        )
        XCTAssertFalse(
            archiveModel.contains("let lifecycle: AppLifecycleModel"),
            "ArchiveWorkflowDependencies must not regain a concrete AppLifecycleModel dependency."
        )
        XCTAssertFalse(
            archiveWorkflow.contains("NSOpenPanel"),
            "ArchiveWorkflowModel should use ArchiveLocationPresenting instead of creating open panels directly."
        )
        XCTAssertTrue(
            archiveWorkflow.contains("dependencies.locationPresenter.selectArchiveLocation(initialDirectory: directoryURL)"),
            "Archive location selection should route through ArchiveLocationPresenting."
        )
        XCTAssertTrue(
            archiveLocationPresenter.contains("struct LiveArchiveLocationPresenter: ArchiveLocationPresenting"),
            "AppKit archive location panel construction should be isolated behind the live archive location presenter."
        )
        XCTAssertTrue(
            archiveLocationPresenter.contains("NSOpenPanel"),
            "The live archive location presenter should own archive folder selection panels."
        )
    }

    func testDocumentUtilityWindowsObserveDocumentWorkflowInsteadOfAppModel() throws {
        for path in [
            "SnipSnipSnip/ContentView.swift",
            "SnipSnipSnip/Editor/LayersWindowView.swift",
            "SnipSnipSnip/Editor/UIMapWindowView.swift",
            "SnipSnipSnip/App/CaptureAutomationSettingsView.swift",
        ] {
            let contents = try String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(
                contents.contains("AppModel"),
                "\(path) should observe DocumentWorkflowModel directly instead of using the app shell."
            )
            XCTAssertTrue(
                contents.contains("DocumentWorkflowModel"),
                "\(path) should make its workflow dependency explicit."
            )
        }
    }

    func testSupportDiagnosticsUsesExplicitSnapshotInsteadOfAppModel() throws {
        let diagnostics = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/Support/SupportDiagnostics.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(
            diagnostics.contains("AppModel"),
            "Support diagnostics should build from SupportDiagnosticsSnapshot/workflow inputs instead of reaching through AppModel."
        )
        XCTAssertTrue(
            diagnostics.contains("struct SupportDiagnosticsSnapshot"),
            "Support diagnostics should expose an explicit workflow snapshot boundary."
        )
        XCTAssertTrue(
            diagnostics.contains("static func make(snapshot: SupportDiagnosticsSnapshot"),
            "SupportDiagnosticsBuilder should consume an explicit snapshot."
        )
    }

    func testCapturePresetNamingSheetObservesCaptureWorkflowInsteadOfAppModel() throws {
        let contentView = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/ContentView.swift"),
            encoding: .utf8
        )
        let sheetRange = try XCTUnwrap(
            contentView.range(of: "private struct CapturePresetNamingSheetView")
        )
        let previewRange = contentView.range(
            of: "struct ContentView_Previews",
            range: sheetRange.upperBound..<contentView.endIndex
        )
        let sheetEnd = previewRange?.lowerBound ?? contentView.endIndex
        let sheet = String(contentView[sheetRange.lowerBound..<sheetEnd])

        XCTAssertTrue(
            sheet.contains("@ObservedObject var capture: CaptureWorkflowModel"),
            "Capture preset naming should depend on the capture workflow, not the app shell."
        )
        XCTAssertFalse(
            sheet.contains("AppModel"),
            "CapturePresetNamingSheetView should not observe AppModel."
        )
    }

    func testPureCaptureMenuViewsObserveCaptureWorkflowInsteadOfAppModel() throws {
        let menu = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/MenuBarCaptureMenu.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(
            menu.contains("@ObservedObject var model: AppModel"),
            "MenuBarCaptureMenu views should depend on explicit workflows instead of observing AppModel."
        )

        for (viewName, nextMarker) in [
            ("RegionCaptureSettingsMenuContent", "struct CaptureTimerMenuContent"),
            ("CaptureTimerMenuContent", "struct CapturePresetMenuContent"),
            ("ScreenshotCaptureSettingsMenuContent", "enum ConnectedDeviceCaptureMenuMode"),
            ("ConnectedDeviceCaptureMenuContent", ""),
        ] {
            let viewRange = try XCTUnwrap(menu.range(of: "struct \(viewName)"))
            let viewEnd = nextMarker.isEmpty
                ? menu.endIndex
                : try XCTUnwrap(menu.range(of: nextMarker, range: viewRange.upperBound..<menu.endIndex)).lowerBound
            let view = String(menu[viewRange.lowerBound..<viewEnd])

            XCTAssertTrue(
                view.contains("@ObservedObject var capture: CaptureWorkflowModel"),
                "\(viewName) should observe CaptureWorkflowModel directly."
            )
            XCTAssertFalse(
                view.contains("AppModel"),
                "\(viewName) should not observe AppModel."
            )
        }
    }

    func testCapturePresetMenuUsesExplicitWorkflowDependenciesInsteadOfAppModel() throws {
        let menu = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/MenuBarCaptureMenu.swift"),
            encoding: .utf8
        )
        let viewRange = try XCTUnwrap(menu.range(of: "struct CapturePresetMenuContent"))
        let nextRange = try XCTUnwrap(menu.range(of: "struct ScreenshotCaptureSettingsMenuContent", range: viewRange.upperBound..<menu.endIndex))
        let view = String(menu[viewRange.lowerBound..<nextRange.lowerBound])

        XCTAssertTrue(view.contains("@ObservedObject var capture: CaptureWorkflowModel"))
        XCTAssertTrue(view.contains("@ObservedObject var video: VideoWorkflowModel"))
        XCTAssertTrue(view.contains("@ObservedObject var lifecycle: AppLifecycleModel"))
        XCTAssertFalse(
            view.contains("AppModel"),
            "CapturePresetMenuContent should not observe the app shell."
        )
    }

    func testAppCommandSurfacesReceiveExplicitWorkflowsInsteadOfObservingAppModel() throws {
        let app = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/SnipSnipSnipApp.swift"),
            encoding: .utf8
        )

        for commandName in [
            "CaptureCommands",
            "HelpCommands",
            "DocumentCommands",
            "PasteboardCommands",
            "EditorCommands",
            "ReferenceCommands",
        ] {
            let commandRange = try XCTUnwrap(app.range(of: "private struct \(commandName): Commands"))
            let nextCommandRange = app.range(
                of: #"(?m)^(private (struct|final class|enum) |@main)"#,
                options: .regularExpression,
                range: commandRange.upperBound..<app.endIndex
            )
            let commandEnd = nextCommandRange?.lowerBound ?? app.endIndex
            let command = String(app[commandRange.lowerBound..<commandEnd])

            XCTAssertFalse(
                command.contains("@ObservedObject var model: AppModel"),
                "\(commandName) should observe explicit workflows, not AppModel."
            )
            XCTAssertFalse(
                command.contains("model."),
                "\(commandName) should not reach through the AppModel shell for product behavior."
            )
        }
    }

    func testMenuBarStatusControllerReceivesExplicitWorkflowsInsteadOfAppModel() throws {
        let controller = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/MenuBarStatusController.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(
            controller.contains("AppModel"),
            "MenuBarStatusController should be configured from explicit workflows instead of storing the app shell."
        )
        XCTAssertTrue(
            controller.contains("func configure(\n        lifecycle: AppLifecycleModel"),
            "MenuBarStatusController should expose a workflow-based configuration surface."
        )
        XCTAssertFalse(
            controller.contains("performMenuAction(_ action: @escaping (AppModel) -> Void)"),
            "MenuBar actions should dispatch to workflow commands instead of AppModel callbacks."
        )
    }

    func testWindowCaptureQuickMenuUsesContextAndWorkflowsInsteadOfAppModel() throws {
        let quickMenu = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/WindowCaptureQuickMenu.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            quickMenu.contains("struct WindowCaptureMenuContext"),
            "Window quick capture menu should be built from an explicit value context."
        )
        XCTAssertFalse(
            quickMenu.contains("AppModel"),
            "Window quick capture menu should not depend on the app shell."
        )
        XCTAssertTrue(
            quickMenu.contains("capture: CaptureWorkflowModel"),
            "Window quick capture presenter should receive the capture workflow explicitly."
        )
    }

    func testOnboardingViewObservesWorkflowsInsteadOfAppModel() throws {
        let onboarding = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/OnboardingView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            onboarding.contains("@ObservedObject var lifecycle: AppLifecycleModel"),
            "Onboarding should observe lifecycle workflow state directly."
        )
        XCTAssertTrue(
            onboarding.contains("@ObservedObject var capture: CaptureWorkflowModel"),
            "Onboarding should observe capture workflow UI Map state directly."
        )
        XCTAssertTrue(
            onboarding.contains("@ObservedObject var permissions: PermissionWorkflowModel"),
            "Onboarding should observe permission workflow state directly."
        )
        XCTAssertTrue(
            onboarding.contains("@ObservedObject var clipboard: ClipboardWorkflowModel"),
            "Onboarding should receive the clipboard workflow directly for the opt-in choice."
        )
        XCTAssertFalse(
            onboarding.contains("AppModel"),
            "OnboardingView should not observe or depend on the app shell."
        )
        XCTAssertFalse(
            onboarding.contains("NSWorkspace.shared"),
            "OnboardingView should use view/presenter URL opening instead of direct workspace access."
        )
    }

    func testDesignLanguageGovernanceIsCanonicalAndAgentReferenced() throws {
        let designURL = repositoryRoot.appendingPathComponent("Docs/DesignLanguage.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: designURL.path))

        let design = try String(contentsOf: designURL, encoding: .utf8)
        let agents = try String(
            contentsOf: repositoryRoot.appendingPathComponent("AGENTS.md"),
            encoding: .utf8
        )

        XCTAssertTrue(agents.contains("Docs/DesignLanguage.md"))
        XCTAssertTrue(agents.localizedCaseInsensitiveContains("before changing user-visible SwiftUI or AppKit UI"))
        XCTAssertTrue(agents.contains("same change"))

        for requiredRule in [
            "## Principles",
            "## Accessibility Behavior",
            "## Custom Surface Exception Registry",
            "## Prohibited Patterns",
            "## UI Review Checklist",
            "Reduce Transparency",
            "Increase Contrast",
            "Differentiate Without Color",
            "Reduced Motion",
            "VoiceOver",
            "Normal text must reach 4.5:1 contrast",
            "meaningful icons, control boundaries, and selected states must reach 3:1",
        ] {
            XCTAssertTrue(design.contains(requiredRule), "Design language is missing required rule: \(requiredRule)")
        }
    }

    func testNativeDesignMigrationRemovesGenericGlassInfrastructure() throws {
        let files = try productionSwiftFiles()

        for forbiddenFragment in [
            "sssGlassSurface",
            "sssGlassAction",
            "SSSChromeButtonStyle",
            "SSSChromeIconButtonStyle",
            "SSSGlassSurfaceModifier",
            "SSSGlassActionModifier",
            "GlassEffectContainer",
        ] {
            for sourceFile in files {
                let contents = try String(contentsOf: sourceFile, encoding: .utf8)
                XCTAssertFalse(
                    contents.contains(forbiddenFragment),
                    "Removed generic styling \(forbiddenFragment) returned in \(relativePath(for: sourceFile))."
                )
            }
        }

        try assertFragment(
            ".glassEffect(",
            in: files,
            isOnlyUsedIn: ["SnipSnipSnip/Support/FloatingOverlaySupport.swift"]
        )

        try assertFragment(
            ".background(Color.black",
            in: files,
            isOnlyUsedIn: [
                "SnipSnipSnip/App/FloatingReferenceController.swift",
                "SnipSnipSnip/App/ScreenInspectorController.swift",
                "SnipSnipSnip/Capture/ConnectedDevicePreviewWindowController.swift",
                "SnipSnipSnip/Video/VideoEditorView.swift",
            ]
        )
        try assertFragment(
            ".fill(Color.black",
            in: files,
            isOnlyUsedIn: [
                "SnipSnipSnip/Editor/EditorView.swift",
                "SnipSnipSnip/Video/VideoEditorView.swift",
            ]
        )

        let design = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Docs/DesignLanguage.md"),
            encoding: .utf8
        )
        for documentedException in [
            "FloatingReferenceController.swift",
            "ScreenInspectorController.swift",
            "ConnectedDevicePreviewWindowController.swift",
            "Editor/EditorView.swift",
            "Video/VideoEditorView.swift",
        ] {
            XCTAssertTrue(design.contains(documentedException), "Fixed-dark exception is not documented: \(documentedException)")
        }

        let floatingOverlay = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("SnipSnipSnip/Support/FloatingOverlaySupport.swift"),
            encoding: .utf8
        )
        for accessibilityAdaptation in [
            "accessibilityReduceTransparency",
            "colorSchemeContrast",
            "accessibilityReduceMotion",
        ] {
            XCTAssertTrue(
                floatingOverlay.contains(accessibilityAdaptation),
                "Floating overlays must adapt to \(accessibilityAdaptation)."
            )
        }
        XCTAssertTrue(
            floatingOverlay.contains(".allowsHitTesting(false)"),
            "Floating-overlay decoration must not intercept HUD controls."
        )
    }

    func testOnboardingAndGuideQuickStartUseAdaptiveNativeStructure() throws {
        let onboarding = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/OnboardingView.swift"),
            encoding: .utf8
        )
        let quickStart = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/Guide/UI/GuideQuickStartView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(onboarding.contains("NavigationSplitView"))
        XCTAssertTrue(onboarding.contains("Form"))
        XCTAssertTrue(quickStart.contains("Form"))
        XCTAssertTrue(quickStart.contains("Picker("))

        for forbiddenFragment in ["LinearGradient", "RadialGradient", ".blur(", "Color(red:", ".foregroundStyle(.white"] {
            XCTAssertFalse(onboarding.contains(forbiddenFragment), "Onboarding contains legacy decoration: \(forbiddenFragment)")
            XCTAssertFalse(quickStart.contains(forbiddenFragment), "Guide Quick Start contains legacy decoration: \(forbiddenFragment)")
        }
    }

    func testEditorsUseStableCommandRowsAndInspectorWithoutAppModelDependency() throws {
        let content = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/ContentView.swift"),
            encoding: .utf8
        )
        let editor = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/Editor/EditorView.swift"),
            encoding: .utf8
        )
        let guide = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/Guide/UI/GuideEditorView.swift"),
            encoding: .utf8
        )
        let video = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/Video/VideoEditorView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(content.contains("appToolbarContent: some ToolbarContent"))
        XCTAssertTrue(content.contains(".toolbar(removing: .title)"))
        XCTAssertTrue(content.contains("private var captureHeader: some View"))
        XCTAssertTrue(content.contains("private var captureHeaderActions: some View"))
        XCTAssertFalse(content.contains("ToolbarItem(id: \"capture-region\""))
        XCTAssertTrue(editor.contains("struct EditorCommandBar: View"))
        XCTAssertTrue(editor.contains("ScrollView(.horizontal, showsIndicators: false)"))
        XCTAssertTrue(editor.contains("toolButtons(Self.shapeTools)"))
        XCTAssertTrue(editor.contains("toolButtons(Self.drawingTools)"))
        XCTAssertTrue(editor.contains("struct EditorCommandGroup<Content: View>: View"))
        XCTAssertTrue(editor.contains("EditorCommandGroup(\"Selection tools\")"))
        XCTAssertTrue(editor.contains("EditorCommandGroup(\"History\")"))
        XCTAssertTrue(editor.contains("EditorCommandGroup(\"Zoom\")"))
        XCTAssertTrue(editor.contains("EditorCommandGroup(\"Output\")"))
        XCTAssertTrue(editor.contains("EditorDirectToolButtonStyle"))
        XCTAssertFalse(editor.contains("toolMenu(title:"))
        XCTAssertTrue(editor.contains(".inspector(isPresented:"))
        XCTAssertTrue(editor.contains(".inspectorColumnWidth(min: 280, ideal: 320, max: 380)"))
        XCTAssertTrue(guide.contains("struct GuideEditorToolbarContent: ToolbarContent"))
        XCTAssertTrue(video.contains("struct VideoEditorToolbarContent: ToolbarContent"))
        XCTAssertFalse(content.contains("AppModel"))
        XCTAssertFalse(editor.contains("AppModel"))
        XCTAssertFalse(guide.contains("AppModel"))
        XCTAssertFalse(video.contains("AppModel"))

        let productionSources = try productionSwiftFiles()
        for sourceFile in productionSources {
            let source = try String(contentsOf: sourceFile, encoding: .utf8)
            XCTAssertFalse(
                source.contains("ToolbarItemGroup"),
                "Labeled toolbar commands must not collapse into a segmented rectangular group in \(relativePath(for: sourceFile))."
            )
        }

        let layers = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/Editor/LayersWindowView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(layers.contains("layerCommandBar"))
        XCTAssertFalse(layers.contains("ToolbarItem("))
    }

    func testProductionSourceKeepsCapabilitiesAndPermissionsBehindPlatformBoundaries() throws {
        let files = try productionSwiftFiles()

        try assertFragment(
            "BuildTargetCapabilityProvider()",
            in: files,
            isOnlyUsedIn: [
                "SnipSnipSnip/Platform/Environment/AppEnvironment.swift",
                "SnipSnipSnip/Platform/Capabilities/AppCapabilities.swift",
                "SnipSnipSnip/Support/BuildTargetFeatureFlags.swift",
            ]
        )
        try assertFragment(
            "currentSnapshot()",
            in: files,
            isOnlyUsedIn: [
                "SnipSnipSnip/Platform/Capabilities/AppCapabilities.swift",
            ]
        )
        try assertFragment(
            "CapturePermissionStatus.current()",
            in: files,
            isOnlyUsedIn: [
                "SnipSnipSnip/Capture/ScreenCapturePermissions.swift",
            ]
        )
        try assertFragment(
            "ScreenCapturePermissions.",
            in: files,
            isOnlyUsedIn: [
                "SnipSnipSnip/Capture/ScreenCapturePermissions.swift",
                "SnipSnipSnip/Platform/Environment/CapturePermissionService.swift",
            ]
        )
        try assertFragment(
            "SCShareableContent.getExcludingDesktopWindows",
            in: files,
            isOnlyUsedIn: [
                "SnipSnipSnip/Capture/ScreenCapturePermissions.swift",
                "SnipSnipSnip/Platform/System/LiveDesktopPreviewSource.swift",
                "SnipSnipSnip/Platform/System/ScreenCapturePlatform.swift",
                "SnipSnipSnip/Platform/System/ScreenRecordingPlatform.swift",
            ]
        )
        try assertFragment(
            "SCScreenshotManager.captureScreenshot",
            in: files,
            isOnlyUsedIn: [
                "SnipSnipSnip/Platform/System/ScreenCapturePlatform.swift",
            ]
        )
        try assertFragment(
            "SCStream",
            in: files,
            isOnlyUsedIn: [
                "SnipSnipSnip/Platform/System/LiveDesktopPreviewSource.swift",
                "SnipSnipSnip/Platform/System/ScreenRecordingPlatform.swift",
            ]
        )
        try assertFragment(
            "SCRecordingOutput",
            in: files,
            isOnlyUsedIn: [
                "SnipSnipSnip/Platform/System/ScreenRecordingPlatform.swift",
            ]
        )
        try assertFragment(
            "AXIsProcessTrusted",
            in: files,
            isOnlyUsedIn: [
                "SnipSnipSnip/Capture/ScreenCapturePermissions.swift",
                "SnipSnipSnip/Platform/System/AccessibilityPlatform.swift",
            ]
        )
        try assertFragment(
            "AXUIElement",
            in: files,
            isOnlyUsedIn: [
                "SnipSnipSnip/Platform/System/AccessibilityPlatform.swift",
            ]
        )
        try assertFragment(
            "AXUIElementCopyElementAtPosition",
            in: files,
            isOnlyUsedIn: [
                "SnipSnipSnip/Platform/System/AccessibilityPlatform.swift",
            ]
        )
        try assertFragment(
            "AVAudioApplication.requestRecordPermission",
            in: files,
            isOnlyUsedIn: [
                "SnipSnipSnip/Platform/System/ScreenRecordingPlatform.swift",
            ]
        )
        try assertFragment(
            "AVCaptureDevice",
            in: files,
            isOnlyUsedIn: [
                "SnipSnipSnip/Platform/System/ConnectedDevicePlatform.swift",
            ]
        )
        try assertFragment(
            "AVCaptureSession",
            in: files,
            isOnlyUsedIn: [
                "SnipSnipSnip/Platform/System/ConnectedDevicePlatform.swift",
            ]
        )
        try assertFragment(
            "AVCaptureVideoPreviewLayer",
            in: files,
            isOnlyUsedIn: [
                "SnipSnipSnip/Platform/System/ConnectedDevicePlatform.swift",
            ]
        )
        try assertFragment(
            "IOServiceGetMatchingServices",
            in: files,
            isOnlyUsedIn: [
                "SnipSnipSnip/Platform/System/ConnectedDevicePlatform.swift",
            ]
        )
        try assertFragment(
            "Thread.sleep",
            in: files,
            isOnlyUsedIn: [
                "SnipSnipSnip/Platform/System/AccessibilityPlatform.swift",
            ]
        )
        try assertFragment(
            "AppAutomationService(host: self)",
            in: files,
            isOnlyUsedIn: []
        )
        try assertFragment(
            "AutomationOutputService(port: self",
            in: files,
            isOnlyUsedIn: []
        )
    }

    func testDocumentSearchHelpersRequireExplicitUIMapSearchDecision() throws {
        let files = try productionSwiftFiles()

        try assertFragment(
            "includeUIMapSearchText: Bool =",
            in: files,
            isOnlyUsedIn: []
        )
        try assertFragment(
            "FeatureFlags.uiMap",
            in: files,
            isOnlyUsedIn: []
        )
    }

    func testClipboardWorkflowOwnsClipboardItemPasteboardWrites() throws {
        let appModelClipboardURL = repositoryRoot.appendingPathComponent("SnipSnipSnip/App/AppModel+Clipboard.swift")
        let clipboardModel = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Workflows/Clipboard/ClipboardWorkflowModel.swift"),
            encoding: .utf8
        )
        let clipboardWorkflow = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Workflows/Clipboard/ClipboardWorkflowModel+Clipboard.swift"),
            encoding: .utf8
        )
        let clipboardIgnoredAppPresenter = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Presentation/ClipboardIgnoredAppPresenter.swift"),
            encoding: .utf8
        )
        let clipboardManagerPresenter = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Presentation/ClipboardManagerPresenter.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: appModelClipboardURL.path),
            "AppModel+Clipboard.swift should stay deleted; clipboard item behavior belongs to ClipboardWorkflowModel."
        )
        XCTAssertFalse(
            clipboardWorkflow.contains("NSPasteboard.general"),
            "Clipboard item copy actions should route through ClipboardWorkflowModel and injected PasteboardServicing."
        )
        XCTAssertFalse(
            clipboardWorkflow.contains("NSOpenPanel"),
            "ClipboardWorkflowModel should use ClipboardIgnoredAppPresenting instead of creating app selection panels directly."
        )
        XCTAssertTrue(
            clipboardModel.contains("final class ClipboardWorkflowModel"),
            "Clipboard workflow should remain the owner of clipboard item behavior."
        )
        XCTAssertTrue(
            clipboardModel.contains("private func writeItemToPasteboard"),
            "Clipboard item pasteboard writes should stay in ClipboardWorkflowModel."
        )
        XCTAssertTrue(
            clipboardModel.contains("any PasteboardServicing"),
            "ClipboardWorkflowModel should use the pasteboard port instead of the global pasteboard."
        )
        XCTAssertTrue(
            clipboardModel.contains("protocol ClipboardIgnoredAppPresenting"),
            "Clipboard ignored-app selection should be exposed as a presenter port."
        )
        XCTAssertTrue(
            clipboardModel.contains("protocol ClipboardManagerPresenting"),
            "Clipboard manager window ownership should be exposed as a presenter port."
        )
        XCTAssertTrue(
            clipboardModel.contains("let ignoredAppPresenter: any ClipboardIgnoredAppPresenting"),
            "ClipboardWorkflowDependencies should receive a narrow ignored-app presenter."
        )
        XCTAssertTrue(
            clipboardModel.contains("let managerPresenter: any ClipboardManagerPresenting"),
            "ClipboardWorkflowDependencies should receive a narrow clipboard manager presenter."
        )
        XCTAssertFalse(
            clipboardModel.contains("managerWindowController"),
            "ClipboardWorkflowModel should not own AppKit window-controller storage."
        )
        XCTAssertTrue(
            clipboardWorkflow.contains("dependencies.ignoredAppPresenter.selectIgnoredClipboardApp()"),
            "Clipboard ignored-app selection should route through ClipboardIgnoredAppPresenting."
        )
        XCTAssertTrue(
            clipboardWorkflow.contains("dependencies.managerPresenter.showClipboardManager("),
            "Clipboard manager presentation should route through ClipboardManagerPresenting."
        )
        XCTAssertFalse(
            clipboardWorkflow.contains("activatePreviousApplicationForPaste"),
            "Clipboard History should not attempt to activate another app or synthesize a paste."
        )
        XCTAssertFalse(
            clipboardWorkflow.contains("ClipboardManagerWindowController("),
            "ClipboardWorkflowModel should not construct the clipboard manager window controller."
        )
        XCTAssertTrue(
            clipboardIgnoredAppPresenter.contains("struct LiveClipboardIgnoredAppPresenter: ClipboardIgnoredAppPresenting"),
            "AppKit clipboard ignored-app panel construction should be isolated behind the live clipboard presenter."
        )
        XCTAssertTrue(
            clipboardIgnoredAppPresenter.contains("NSOpenPanel"),
            "The live clipboard ignored-app presenter should own app selection panels."
        )
        XCTAssertTrue(
            clipboardManagerPresenter.contains("final class LiveClipboardManagerPresenter: ClipboardManagerPresenting"),
            "AppKit clipboard manager window ownership should be isolated behind the live clipboard manager presenter."
        )
        XCTAssertTrue(
            clipboardManagerPresenter.contains("ClipboardManagerWindowController"),
            "The live clipboard manager presenter should own the clipboard manager window controller."
        )
    }

    func testRegionSelectionOverlayCanPresentInsideOtherAppsFullScreenSpaces() throws {
        let regionSelectionOverlay = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/Capture/RegionSelectionOverlay.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            regionSelectionOverlay.contains("private final class RegionSelectionWindow: NSPanel"),
            "Region selection should use a panel so it can participate in full-screen Spaces as transient capture UI."
        )
        XCTAssertTrue(
            regionSelectionOverlay.contains("styleMask: [.borderless, .nonactivatingPanel]"),
            "Region selection should not activate SnipSnipSnip before it appears over another app's full-screen Space."
        )
        XCTAssertTrue(
            regionSelectionOverlay.contains("isFloatingPanel = true")
                && regionSelectionOverlay.contains("hidesOnDeactivate = false")
                && regionSelectionOverlay.contains("collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]"),
            "Region selection should stay visible across Spaces, including Safari or video full screen."
        )
        XCTAssertFalse(
            regionSelectionOverlay.contains("NSApp.activate"),
            "Region selection should not eagerly activate the app; activation can be deferred until another app exits full screen."
        )
    }

    func testVideoAndConnectedDeviceBehaviorStayOutOfAppModelExtensions() throws {
        let deletedExtensionPaths = [
            "SnipSnipSnip/App/AppModel+VideoRecording.swift",
            "SnipSnipSnip/App/AppModel+ConnectedDeviceCapture.swift",
        ]
        for path in deletedExtensionPaths {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: repositoryRoot.appendingPathComponent(path).path),
                "\(path) should stay deleted; behavior belongs to workflow owners."
            )
        }

        let videoWorkflow = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Workflows/Video/VideoWorkflowModel+Recording.swift"),
            encoding: .utf8
        )
        let videoPorts = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Workflows/Video/VideoWorkflowPorts.swift"),
            encoding: .utf8
        )
        let videoModel = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Workflows/Video/VideoWorkflowModel.swift"),
            encoding: .utf8
        )
        let videoDependenciesStart = try XCTUnwrap(videoModel.range(of: "struct VideoWorkflowDependencies"))
        let videoDependenciesEnd = try XCTUnwrap(
            videoModel.range(
                of: "final class VideoWorkflowModel",
                range: videoDependenciesStart.upperBound..<videoModel.endIndex
            )
        ).lowerBound
        let videoDependencies = String(videoModel[videoDependenciesStart.lowerBound..<videoDependenciesEnd])
        let connectedDeviceWorkflow = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Workflows/Capture/CaptureWorkflowModel+ConnectedDevice.swift"),
            encoding: .utf8
        )
        let appWindowPresenter = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Presentation/AppWindowPresenter.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            videoWorkflow.contains("extension VideoWorkflowModel"),
            "Video recording behavior should be owned by VideoWorkflowModel."
        )
        XCTAssertTrue(
            videoPorts.contains("protocol VideoCaptureWorkflowPort"),
            "Video recording should depend on a narrow capture port instead of concrete CaptureWorkflowModel."
        )
        XCTAssertTrue(
            videoDependencies.contains("let capture: any VideoCaptureWorkflowPort"),
            "VideoWorkflowDependencies should receive the capture port."
        )
        for forbiddenMutableCapturePortFragment in [
            "var windowPickerMode",
            "var isShowingWindowPicker",
            "var isWorking: Bool { get set }",
            "var captureService: any ScreenCaptureServiceType",
        ] {
            XCTAssertFalse(
                videoPorts.contains(forbiddenMutableCapturePortFragment),
                "VideoCaptureWorkflowPort should expose capture commands, not mutable capture internals: \(forbiddenMutableCapturePortFragment)"
            )
        }
        for expectedCaptureCommand in [
            "func beginVideoWindowSelection()",
            "func dismissWindowPicker()",
            "func desktopSnapshotForVideoSelection() async throws -> DesktopCompositeSnapshot",
            "func videoWindowSelectionSnapshot(fallbackWindows: [CaptureWindowSummary]) async throws -> (windows: [CaptureWindowSummary], snapshot: DesktopCompositeSnapshot)",
            "func performVideoWork<Result>(",
        ] {
            XCTAssertTrue(
                videoPorts.contains(expectedCaptureCommand),
                "Video should coordinate with capture through intentful commands: \(expectedCaptureCommand)"
            )
        }
        XCTAssertFalse(
            videoDependencies.contains("let capture: CaptureWorkflowModel"),
            "VideoWorkflowDependencies must not regain a concrete CaptureWorkflowModel dependency."
        )
        XCTAssertTrue(
            videoDependencies.contains("let appWindowPresenter: any AppWindowPresenting"),
            "VideoWorkflowDependencies should receive app-window presentation through a narrow presenter port."
        )
        XCTAssertTrue(
            videoDependencies.contains("let lifecycle: any WorkflowLifecyclePresenting"),
            "VideoWorkflowDependencies should receive lifecycle UI state through a narrow port."
        )
        XCTAssertFalse(
            videoDependencies.contains("let lifecycle: AppLifecycleModel"),
            "VideoWorkflowDependencies must not regain a concrete AppLifecycleModel dependency."
        )
        XCTAssertFalse(
            videoWorkflow.contains("mainWindowPresentationRequest +="),
            "VideoWorkflowModel+Recording.swift should request window presentation through WorkflowLifecyclePresenting."
        )
        XCTAssertFalse(
            videoWorkflow.contains("NSApp.") || videoWorkflow.contains("NSWindow"),
            "VideoWorkflowModel+Recording.swift should route app-window hide/restore mechanics through AppWindowPresenting."
        )
        XCTAssertTrue(
            videoWorkflow.contains("AppWindowVisibilityToken"),
            "Video active-recording state should store an opaque app-window visibility token, not NSWindow."
        )
        XCTAssertTrue(
            appWindowPresenter.contains("func restoreAppWindowIfNeeded(_ token: AppWindowVisibilityToken?)"),
            "The live app-window presenter should own restoring hidden app windows."
        )
        XCTAssertTrue(
            connectedDeviceWorkflow.contains("extension CaptureWorkflowModel"),
            "Connected-device capture behavior should be owned by CaptureWorkflowModel."
        )
    }

    func testClipboardMonitoringAndManagerUsePlatformPorts() throws {
        let clipboardMonitor = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/Clipboard/ClipboardMonitor.swift"),
            encoding: .utf8
        )
        let clipboardManager = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/Clipboard/ClipboardManagerWindowController.swift"),
            encoding: .utf8
        )

        for (fileName, contents) in [
            ("ClipboardMonitor.swift", clipboardMonitor),
            ("ClipboardManagerWindowController.swift", clipboardManager),
        ] {
            XCTAssertFalse(
                contents.contains("NSPasteboard.general"),
                "\(fileName) should use PasteboardServicing instead of the global pasteboard."
            )
            XCTAssertFalse(
                contents.contains("NSWorkspace.shared"),
                "\(fileName) should use WorkspaceServicing instead of the global workspace."
            )
            XCTAssertFalse(
                contents.contains("NSRunningApplication"),
                "\(fileName) should store app-owned workspace snapshots instead of AppKit running application objects."
            )
        }

        XCTAssertTrue(
            clipboardMonitor.contains("any PasteboardServicing"),
            "ClipboardMonitor should depend on the pasteboard port."
        )
        XCTAssertTrue(
            clipboardMonitor.contains("any WorkspaceServicing"),
            "ClipboardMonitor should depend on the workspace port for source app lookup."
        )
        XCTAssertTrue(
            clipboardManager.contains("any WorkspaceServicing"),
            "ClipboardManagerWindowController should use the workspace port for focus restoration."
        )
    }

    func testAutomationCommandHandlingBelongsToWorkflowPorts() throws {
        let appModelAutomationHostURL = repositoryRoot.appendingPathComponent("SnipSnipSnip/Automation/AppModel+AutomationHost.swift")
        let appModel = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/AppModel.swift"),
            encoding: .utf8
        )
        let appModelAutomationURL = repositoryRoot.appendingPathComponent("SnipSnipSnip/App/AppModel+Automation.swift")
        let workflows = try workflowSource()
        let appleScriptBridge = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/Automation/AutomationAppleScriptCommands.swift"),
            encoding: .utf8
        )
        let coordinator = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/App/Workflows/AppWorkflowCoordinator.swift"),
            encoding: .utf8
        )
        let appIntentSources = try productionSwiftFiles()
            .filter { relativePath(for: $0).hasPrefix("SnipSnipSnip/Automation/AppIntents/") }
            .sorted { relativePath(for: $0) < relativePath(for: $1) }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: appModelAutomationHostURL.path),
            "AppModel+AutomationHost.swift should not come back; automation must route through workflow ports and AppWorkflowCoordinator."
        )
        XCTAssertFalse(
            appModel.contains("CaptureWorkflowAutomationHost") || appModel.contains("DocumentWorkflowAutomationHost"),
            "AppModel should not conform to workflow automation host protocols."
        )
        XCTAssertFalse(
            appModel.contains(".automationHost = self"),
            "Workflows should not keep weak AppModel automation-host callbacks."
        )
        XCTAssertFalse(
            workflows.contains("automationHost"),
            "Automation workflows should use AppWorkflowCoordinator instead of broad host callbacks."
        )
        XCTAssertFalse(
            workflows.contains("CaptureWorkflowAutomationHost") || workflows.contains("DocumentWorkflowAutomationHost"),
            "Workflow automation host protocols should stay deleted."
        )
        XCTAssertFalse(
            appleScriptBridge.contains("AppModel"),
            "AppleScript automation should depend on AutomationWorkflowModel/AppAutomationService, not the app shell."
        )
        XCTAssertTrue(
            appleScriptBridge.contains("configure(automation: AutomationWorkflowModel, automationService: any AutomationService)"),
            "AppleScript automation should be configured with explicit automation boundaries."
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: appModelAutomationURL.path),
            "AppModel+Automation.swift should stay deleted; automation command handling belongs to workflow ports."
        )
        XCTAssertTrue(
            workflows.contains("final class AutomationWorkflowModel: AutomationHost, AutomationOutputPort"),
            "AutomationWorkflowModel should be the concrete automation host/output boundary."
        )
        XCTAssertTrue(
            workflows.contains("final class CaptureWorkflowModel: ObservableObject, AutomationStatusPort, CaptureAutomationPort"),
            "CaptureWorkflowModel should own capture automation behavior."
        )
        XCTAssertTrue(
            workflows.contains("final class DocumentWorkflowModel: ObservableObject, DocumentAutomationPort"),
            "DocumentWorkflowModel should own document automation behavior."
        )
        XCTAssertTrue(
            coordinator.contains("final class AppWorkflowCoordinator"),
            "AppWorkflowCoordinator should be the explicit cross-workflow wiring point."
        )
        XCTAssertTrue(
            appModel.contains("let workflowCoordinator: AppWorkflowCoordinator"),
            "AppModel should compose the explicit workflow coordinator."
        )
        XCTAssertTrue(
            appIntentSources.contains("AutomationRequest"),
            "App Intents should translate into AutomationRequest instead of executing feature workflows directly."
        )
        XCTAssertTrue(
            appIntentSources.contains("AutomationIntentClient"),
            "App Intents should call automation through the intent client boundary."
        )
        for forbiddenFragment in [
            "AppModel",
            "CaptureWorkflowModel",
            "DocumentWorkflowModel",
            "AppWorkflowCoordinator",
            "EditorController",
            "ScreenCaptureService",
            "NSApp"
        ] {
            XCTAssertFalse(
                appIntentSources.contains(forbiddenFragment),
                "App Intents should stay behind AutomationService and must not depend on \(forbiddenFragment)."
            )
        }
    }

    func testDocumentPackageUsesFileSystemPortForPackageIO() throws {
        let documentPackage = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/Document/SSSDocument.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(
            documentPackage.contains("FileManager.default"),
            "SSSDocumentPackage should use FileSystemServicing so document workflow tests can fake package I/O."
        )
        XCTAssertFalse(
            documentPackage.contains("Data(contentsOf:"),
            "SSSDocumentPackage should read package data through FileSystemServicing."
        )
        XCTAssertTrue(
            documentPackage.contains("files: any FileSystemServicing"),
            "SSSDocumentPackage public helpers should accept an explicit file service."
        )
        XCTAssertTrue(
            documentPackage.contains("files.writeData"),
            "SSSDocumentPackage should write package data through FileSystemServicing."
        )
    }

    func testVideoDocumentPackageUsesFileSystemPortForPackageIO() throws {
        let videoDocumentPackage = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/Video/SSSVideoDocument.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(
            videoDocumentPackage.contains("FileManager.default"),
            "SSSVideoDocumentPackage should use FileSystemServicing so video document workflow tests can fake package I/O."
        )
        XCTAssertFalse(
            videoDocumentPackage.contains("Data(contentsOf:"),
            "SSSVideoDocumentPackage should read package data through FileSystemServicing."
        )
        XCTAssertFalse(
            videoDocumentPackage.contains(".write(to:"),
            "SSSVideoDocumentPackage should write package data through FileSystemServicing."
        )
        XCTAssertTrue(
            videoDocumentPackage.contains("files: any FileSystemServicing"),
            "SSSVideoDocumentPackage public helpers should accept an explicit file service."
        )
        XCTAssertTrue(
            videoDocumentPackage.contains("files.copyItem"),
            "SSSVideoDocumentPackage should copy media through FileSystemServicing."
        )
        XCTAssertTrue(
            videoDocumentPackage.contains("files.readData"),
            "SSSVideoDocumentPackage should read package data through FileSystemServicing."
        )
        XCTAssertTrue(
            videoDocumentPackage.contains("files.writeData"),
            "SSSVideoDocumentPackage should write package data through FileSystemServicing."
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "AppArchitecturePlatformTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeImage() -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return context.makeImage()!
    }

    private func capabilities(
        _ enabledCapabilities: Set<AppCapability>,
        target: BuildTarget = .dev
    ) -> AppCapabilitySnapshot {
        AppCapabilitySnapshot(buildTarget: target, enabledCapabilities: enabledCapabilities)
    }

    private func makePermissionClient(
        screenRecordingStatus: Bool = false,
        accessibilityStatus: Bool = false,
        verificationResult: Bool = true,
        recorder: PermissionClientRecorder = PermissionClientRecorder(),
        appName: String = "SnipSnipSnip",
        appPath: String = "/Applications/SnipSnipSnip.app",
        failureDetector: @escaping @Sendable (Error) -> Bool = { _ in false }
    ) -> CapturePermissionSystemClient {
        CapturePermissionSystemClient(
            screenRecordingStatus: {
                screenRecordingStatus
            },
            accessibilityStatus: {
                accessibilityStatus
            },
            screenRecordingAccessVerifier: {
                verificationResult
            },
            screenRecordingAccessRequester: {
                recorder.recordScreenRecordingRequest()
                return true
            },
            accessibilityAccessRequester: {
                recorder.recordAccessibilityRequest()
                return true
            },
            systemSettingsOpener: { requirement in
                recorder.recordSettingsOpen(for: requirement)
            },
            currentAppName: {
                appName
            },
            currentAppPath: {
                appPath
            },
            revealCurrentAppInFinder: {
                recorder.recordReveal()
            },
            copyCurrentAppPathToPasteboard: {
                recorder.recordCopyPath()
            },
            screenRecordingPermissionFailureDetector: failureDetector
        )
    }

    private func productionSwiftFiles() throws -> [URL] {
        let sourceRoot = repositoryRoot.appendingPathComponent("SnipSnipSnip", isDirectory: true)
        let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var files: [URL] = []
        while let file = enumerator?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            files.append(file)
        }
        return files
    }

    private func workflowSource() throws -> String {
        let files = try productionSwiftFiles()
            .filter { relativePath(for: $0).hasPrefix("SnipSnipSnip/App/Workflows/") }
            .sorted { relativePath(for: $0) < relativePath(for: $1) }

        return try files.map { file in
            try String(contentsOf: file, encoding: .utf8)
        }
        .joined(separator: "\n")
    }

    private func assertFragment(
        _ fragment: String,
        in files: [URL],
        isOnlyUsedIn allowedFiles: Set<String>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for sourceFile in files {
            let relativePath = self.relativePath(for: sourceFile)
            let contents = try String(contentsOf: sourceFile, encoding: .utf8)
            guard contents.contains(fragment) else { continue }

            XCTAssertTrue(
                allowedFiles.contains(relativePath),
                "\(fragment) should stay behind the platform boundary, but was found in \(relativePath).",
                file: file,
                line: line
            )
        }
    }

    private func relativePath(for file: URL) -> String {
        let rootPath = repositoryRoot.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else {
            return filePath
        }
        return String(filePath.dropFirst(rootPath.count + 1))
    }
}

private struct SentinelPermissionError: Error {}

private final class PermissionClientRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var screenRecordingRequests = 0
    private var accessibilityRequests = 0
    private var openedSettings: [CapturePermissionRequirement] = []
    private var reveals = 0
    private var copyPathRequests = 0

    var screenRecordingRequestCount: Int {
        withLock { screenRecordingRequests }
    }

    var accessibilityRequestCount: Int {
        withLock { accessibilityRequests }
    }

    var openedSettingsRequirementIDs: [String] {
        withLock { openedSettings.map(\.id) }
    }

    var revealCount: Int {
        withLock { reveals }
    }

    var copyPathCount: Int {
        withLock { copyPathRequests }
    }

    func recordScreenRecordingRequest() {
        withLock { screenRecordingRequests += 1 }
    }

    func recordAccessibilityRequest() {
        withLock { accessibilityRequests += 1 }
    }

    func recordSettingsOpen(for requirement: CapturePermissionRequirement) {
        withLock { openedSettings.append(requirement) }
    }

    func recordReveal() {
        withLock { reveals += 1 }
    }

    func recordCopyPath() {
        withLock { copyPathRequests += 1 }
    }

    private func withLock<Result>(_ body: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class CapabilityProviderSpy: @unchecked Sendable, AppCapabilityProvider {
    private let lock = NSLock()
    private let snapshotValue: AppCapabilitySnapshot
    private var targets: [BuildTarget] = []

    init(snapshot: AppCapabilitySnapshot) {
        self.snapshotValue = snapshot
    }

    var requestedTargets: [BuildTarget] {
        lock.lock()
        defer { lock.unlock() }
        return targets
    }

    func snapshot(for target: BuildTarget) -> AppCapabilitySnapshot {
        lock.lock()
        targets.append(target)
        lock.unlock()
        return snapshotValue
    }
}
