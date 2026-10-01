import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SnipSnipSnip

@MainActor
final class TransactionalIntakeTests: XCTestCase {
    func testCancelledCompositionExportDestinationReleasesActivityWithoutChangingSession() async throws {
        let fixture = try TransactionalIntakeFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.installScreenshot()
        try controller.appendCaptureToComposition(makeCapturedScreenshot(sourceName: "Second"), isPrivate: true)
        XCTAssertTrue(controller.hasComposition)
        let session = controller.documentSession
        let viewport = controller.viewport

        fixture.documents.exportAnnotatedImage(as: .png, appearance: .plain)
        XCTAssertTrue(controller.outputActivity.isExporting, "Reserve the action before the destination chooser opens")
        XCTAssertFalse(controller.outputActivity.showsExportProgress, "Destination selection is not rendering")
        fixture.documents.exportAnnotatedImage(as: .png, appearance: .plain)
        await waitUntil { !controller.outputActivity.isExporting }

        XCTAssertEqual(fixture.panels.saveCount, 1, "Repeated activation must not open another destination chooser")
        XCTAssertFalse(controller.outputActivity.isExporting)
        XCTAssertFalse(controller.outputActivity.showsExportProgress)
        XCTAssertNil(fixture.documents.pendingCompositionExportTask)
        XCTAssertNil(fixture.documents.activeCompositionExportID)
        XCTAssertTrue(fixture.documents.editorController === controller)
        XCTAssertEqual(controller.documentSession, session)
        XCTAssertEqual(controller.viewport, viewport)
        XCTAssertTrue(controller.canUndo)
    }

    func testAcceptedCompositionExportWritesPNGAndReleasesActivityWithoutChangingSession() async throws {
        let fixture = try TransactionalIntakeFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.installScreenshot()
        try controller.appendCaptureToComposition(makeCapturedScreenshot(sourceName: "Second"), isPrivate: true)
        let session = controller.documentSession
        let viewport = controller.viewport
        let preflight = try CompositionOutputExporter.preflight(
            controller.compositionOutputInput(appearance: .plain), format: .png)
        let destination = fixture.root.appendingPathComponent("Combined.png")
        fixture.panels.saveURL = destination

        fixture.documents.exportAnnotatedImage(as: .png, appearance: .plain)
        XCTAssertTrue(controller.outputActivity.isExporting)
        await waitUntil(timeoutNanoseconds: 5_000_000_000) { !controller.outputActivity.isExporting }

        XCTAssertEqual(fixture.panels.saveCount, 1)
        XCTAssertFalse(controller.outputActivity.isExporting)
        XCTAssertFalse(controller.outputActivity.showsExportProgress)
        XCTAssertNil(fixture.documents.pendingCompositionExportTask)
        XCTAssertNil(fixture.documents.activeCompositionExportID)
        XCTAssertNil(fixture.model.lifecycle.errorMessage)
        XCTAssertEqual(controller.documentSession, session)
        XCTAssertEqual(controller.viewport, viewport)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(destination as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, Int(preflight.estimatedPixelSize.width.rounded(.up)))
        XCTAssertEqual(image.height, Int(preflight.estimatedPixelSize.height.rounded(.up)))
        XCTAssertEqual(controller.notice?.action, .reveal(destination))
        XCTAssertTrue(fixture.revealRecorder.selections.isEmpty)
    }

    func testCancelledOpenAndImportNeverAskToDiscardCurrentScreenshot() throws {
        let fixture = try TransactionalIntakeFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.installScreenshot()
        let session = controller.documentSession
        let viewport = controller.viewport

        fixture.documents.openDocumentPanel()
        fixture.documents.importImagePanel()

        XCTAssertEqual(fixture.panels.openCount, 1)
        XCTAssertEqual(fixture.panels.importCount, 1)
        XCTAssertFalse(fixture.documents.isShowingUnsavedChangesPrompt)
        XCTAssertNil(fixture.documents.pendingEditorAction)
        XCTAssertTrue(fixture.documents.editorController === controller)
        XCTAssertEqual(controller.documentSession, session)
        XCTAssertEqual(controller.viewport, viewport)
        XCTAssertTrue(controller.canUndo)
    }

    func testInvalidExternalCandidatesKeepSelectionViewportAndUndoBeforeAnyUnsavedPrompt() throws {
        let fixture = try TransactionalIntakeFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.installScreenshot()
        let session = controller.documentSession
        let viewport = controller.viewport

        for fileExtension in ["png", "sss", "sssvideo", "sssguide"] {
            let candidate = fixture.root.appendingPathComponent("Invalid.\(fileExtension)")
            try Data("unreadable candidate".utf8).write(to: candidate)
            fixture.documents.openExternalFile(at: candidate)
            XCTAssertFalse(fixture.documents.isShowingUnsavedChangesPrompt, fileExtension)
            XCTAssertNil(fixture.documents.pendingEditorAction, fileExtension)
            XCTAssertTrue(fixture.documents.editorController === controller, fileExtension)
            XCTAssertEqual(controller.documentSession, session, fileExtension)
            XCTAssertEqual(controller.viewport, viewport, fileExtension)
            XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
        }
    }

    func testUnsupportedCandidateDoesNotTrashFilesOrRunStartupCompatibilityHandling() throws {
        let fixture = try TransactionalIntakeFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.installScreenshot()
        let candidate = fixture.root.appendingPathComponent("Future.sss")
        try SSSDocumentPackage.save(document: controller.editableDocument,
            previewImage: controller.capture.image, to: candidate)
        let manifestURL = candidate.appendingPathComponent(SSSDocumentPackage.manifestFilename)
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        manifest["formatVersion"] = SSSDocumentPackage.formatVersion + 1
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let session = controller.documentSession

        fixture.documents.openDocument(at: candidate)

        XCTAssertFalse(fixture.documents.isShowingUnsavedChangesPrompt)
        XCTAssertTrue(fixture.documents.editorController === controller)
        XCTAssertEqual(controller.documentSession, session)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        XCTAssertEqual(fixture.compatibilityCalls.count, 0)
        XCTAssertNotNil(fixture.model.lifecycle.errorMessage)
    }

    func testCancellingUnsavedDecisionForValidImportKeepsCurrentSession() throws {
        let fixture = try TransactionalIntakeFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.installScreenshot()
        let session = controller.documentSession
        let viewport = controller.viewport
        let candidate = fixture.root.appendingPathComponent("Replacement.png")
        try ImageExporter.pngData(for: makeCoordinateImage(width: 12, height: 9)).write(to: candidate)
        fixture.panels.importURL = candidate

        fixture.documents.importImagePanel()
        XCTAssertTrue(fixture.documents.isShowingUnsavedChangesPrompt)
        XCTAssertTrue(fixture.documents.editorController === controller)
        fixture.documents.cancelPendingEditorAction()

        XCTAssertNil(fixture.documents.pendingEditorAction)
        XCTAssertTrue(fixture.documents.editorController === controller)
        XCTAssertEqual(controller.documentSession, session)
        XCTAssertEqual(controller.viewport, viewport)
        XCTAssertTrue(controller.canUndo)
    }

    func testAcceptedOpenInstallsAlreadyValidatedCandidateWithoutReopeningFile() async throws {
        let fixture = try TransactionalIntakeFixture()
        defer { fixture.cleanUp() }
        let original = fixture.installScreenshot()
        let replacement = EditorController(capture: makeCapturedScreenshot(sourceName: "Replacement"),
            defaults: fixture.defaults, capabilities: testCapabilities)
        let candidate = fixture.root.appendingPathComponent("Replacement.sss")
        try SSSDocumentPackage.save(document: replacement.editableDocument,
            previewImage: replacement.capture.image, to: candidate)
        fixture.panels.openURL = candidate

        fixture.documents.openDocumentPanel()
        XCTAssertTrue(fixture.documents.isShowingUnsavedChangesPrompt)
        XCTAssertTrue(fixture.documents.editorController === original)
        // The approved candidate has already been fully loaded. A missing file
        // after approval must not leave a discarded editor with no replacement.
        try FileManager.default.removeItem(at: candidate)
        fixture.documents.discardChangesAndContinue()
        await waitUntil { fixture.documents.editorController != nil }

        let installed = try XCTUnwrap(fixture.documents.editorController)
        XCTAssertFalse(installed === original)
        XCTAssertEqual(installed.capture.sourceName, "Replacement")
        XCTAssertEqual(installed.documentSession, replacement.documentSession)
        XCTAssertEqual(fixture.documents.currentDocumentURL, candidate)
    }

    func testCancellingGuideExportDirectoryKeepsSettingsVersionSelectionAndUndo() throws {
        let fixture = try TransactionalIntakeFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.installGuide()
        controller.updateCaption(stepID: controller.project.steps[0].id, caption: "Keep this edit")
        let project = controller.project
        let version = controller.contentVersion
        let selection = controller.selection

        fixture.documents.exportCurrentGuide(formats: [.stepImages, .zip], showProgressWindow: false)

        XCTAssertEqual(fixture.panels.exportCount, 1)
        XCTAssertEqual(controller.project, project)
        XCTAssertEqual(controller.contentVersion, version)
        XCTAssertEqual(controller.selection, selection)
        XCTAssertTrue(controller.canUndo)
        XCTAssertFalse(fixture.documents.guideExportIsActive)
        controller.undo()
        XCTAssertEqual(controller.project.steps[0].caption, "Step 1")
        XCTAssertFalse(controller.canUndo, "A cancelled export must add no Undo command")
    }

    func testSavingWhileReopeningCurrentFileKeepsSavedEditsInsteadOfOlderPreparedCandidate() async throws {
        let fixture = try TransactionalIntakeFixture()
        defer { fixture.cleanUp() }
        let controller = EditorController(capture: makeCapturedScreenshot(), defaults: fixture.defaults,
            capabilities: testCapabilities)
        let url = fixture.root.appendingPathComponent("Current.sss")
        try SSSDocumentPackage.save(document: controller.editableDocument,
            previewImage: controller.capture.image, to: url)
        fixture.documents.installEditorController(controller, documentURL: url,
            savedSession: controller.documentSession, shouldCreateRecoverySession: false)
        controller.updateCropRect(CGRect(x: 3, y: 4, width: 20, height: 20))
        fixture.documents.updateDocumentChangeTracking()
        let editedSession = controller.documentSession

        fixture.documents.openDocument(at: url)
        XCTAssertTrue(fixture.documents.isShowingUnsavedChangesPrompt)
        fixture.documents.confirmSaveBeforeContinuing()
        await waitUntil { !fixture.documents.hasUnsavedChanges }

        XCTAssertFalse(fixture.documents.hasUnsavedChanges)
        XCTAssertTrue(fixture.documents.editorController === controller)
        XCTAssertEqual(controller.documentSession, editedSession)
        XCTAssertEqual(try SSSDocumentPackage.load(from: url).session, editedSession)
        XCTAssertTrue(controller.canUndo)
    }

    func testAcceptedGuideExportCommitsFormatsAsOneUndoableChangeAndExportsThoseFormats() async throws {
        let fixture = try TransactionalIntakeFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.installGuide()
        let previousFormats = controller.project.exportSettings.formats
        fixture.panels.exportURL = fixture.root

        fixture.documents.exportCurrentGuide(formats: [.stepImages], showProgressWindow: false)
        XCTAssertEqual(controller.project.exportSettings.formats, [.stepImages])
        XCTAssertTrue(controller.canUndo)
        await waitUntil(timeoutNanoseconds: 5_000_000_000) { !fixture.documents.guideExportIsActive }
        XCTAssertFalse(fixture.documents.guideExportIsActive)
        XCTAssertEqual(fixture.documents.lastGuideExportURLs.count, 1)
        let output = try XCTUnwrap(fixture.documents.lastGuideExportURLs.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(fixture.revealRecorder.selections.isEmpty, "Export completion must keep focus in the editor")
        fixture.documents.revealGuideExports()
        XCTAssertEqual(fixture.revealRecorder.selections, [[output]])

        controller.undo()
        XCTAssertEqual(controller.project.exportSettings.formats, previousFormats)
        XCTAssertFalse(controller.canUndo, "The entire format choice is one command")
        XCTAssertTrue(fixture.documents.lastGuideExportURLs.isEmpty)
        fixture.documents.revealGuideExports()
        XCTAssertEqual(fixture.revealRecorder.selections.count, 1, "Reveal must reject stale output")
    }

    func testGuideSetupAndTargetCancellationPreserveSavedPreferencesAndSource() throws {
        let fixture = try TransactionalIntakeFixture(permissionsGranted: false)
        defer { fixture.cleanUp() }
        let guide = fixture.model.guide
        let store = fixture.model.environment.preferenceStores.guide
        let originalPreferences = guide.capturePreferences
        let originalSourceKind = guide.selectedSourceKind
        let originalLastSource = store.loadLastSource()
        let originalOnboardingVersion = store.loadOnboardingVersion()
        var proposedPreferences = originalPreferences
        proposedPreferences.framesPerSecond = 60
        proposedPreferences.showsCursorInSteps.toggle()
        proposedPreferences.hidesDesktopIcons.toggle()
        proposedPreferences.aiCaptionRefinement.toggle()
        proposedPreferences.masksSecureFields.toggle()
        proposedPreferences.menuBarIncludedForDisplays.toggle()
        proposedPreferences = GuideCaptureSetupIntent(output: .stepsOnly,
            audio: .none, showsStepNumbers: false, showsActionTargets: false).applying(to: proposedPreferences)
        let proposed = GuideCaptureSetupDraft(preferences: proposedPreferences, sourceKind: "region")
        guide.presentQuickStart()

        // Permission preflight fails before target selection starts. Even Start
        // must keep defaults unchanged until a target and capture succeed.
        guide.beginSelectedSourceSelection(setup: proposed)
        XCTAssertEqual(guide.captureSetupDraft, proposed)
        guide.cancelTargetSelection()
        XCTAssertTrue(guide.isShowingQuickStart)
        XCTAssertEqual(guide.captureSetupDraft, proposed, "Returning to setup retains only its temporary choices")
        guide.cancelQuickStart()

        XCTAssertNil(guide.captureSetupDraft)
        XCTAssertFalse(guide.isShowingQuickStart)
        XCTAssertEqual(guide.capturePreferences, originalPreferences)
        XCTAssertEqual(store.loadCapturePreferences(), originalPreferences)
        XCTAssertEqual(guide.selectedSourceKind, originalSourceKind)
        XCTAssertEqual(store.loadLastSource(), originalLastSource)
        XCTAssertEqual(store.loadOnboardingVersion(), originalOnboardingVersion)
    }

    func testInteractiveRegionGuideAutomationStartsWithFreshSetupInsteadOfStaleTargetDraft() async throws {
        let fixture = try TransactionalIntakeFixture(permissionsGranted: false)
        defer { fixture.cleanUp() }
        let guide = fixture.model.guide
        let preferences = guide.capturePreferences
        var abandonedPreferences = preferences
        abandonedPreferences.framesPerSecond = 60
        abandonedPreferences.showsCursorInSteps.toggle()
        guide.presentQuickStart()
        guide.beginSelectedSourceSelection(setup: GuideCaptureSetupDraft(
            preferences: abandonedPreferences, sourceKind: "window"))
        XCTAssertEqual(guide.captureSetupDraft?.preferences, abandonedPreferences)
        // The prior sheet can disappear without accepting its temporary draft.
        guide.isShowingQuickStart = false
        fixture.permissionState.isGranted = true
        let request = AutomationRequest(source: AutomationSource(kind: .internalCommand),
            command: .guide(.start(.region)), interactionPolicy: .requireUserSelection)

        let result = await guide.guideAutomation(.start(.region), request: request)

        XCTAssertEqual(result.status, .succeeded)
        guard case .guide(let summary)? = result.payload else {
            return XCTFail("Expected the existing interactive Guide response")
        }
        XCTAssertEqual(summary.state, "selectionRequired")
        XCTAssertEqual(summary.source, "region")
        XCTAssertTrue(guide.isShowingQuickStart)
        XCTAssertEqual(guide.captureSetupDraft, GuideCaptureSetupDraft(preferences: preferences, sourceKind: "region"))
        XCTAssertEqual(guide.capturePreferences, preferences)
        XCTAssertFalse(guide.isActive, "Region automation must still wait for target selection")
        guide.cancelQuickStart()
    }
}

@MainActor
private final class TransactionalIntakePanels: DocumentPanelPresenting {
    var openURL: URL?
    var importURL: URL?
    var exportURL: URL?
    var saveURL: URL?
    var openCount = 0
    var importCount = 0
    var exportCount = 0
    var saveCount = 0
    func selectDocumentToOpen() -> URL? { openCount += 1; return openURL }
    func selectImageToImport() -> URL? { importCount += 1; return importURL }
    func selectPresentationScenesRoot(initialDirectory: URL) -> URL? { nil }
    func selectSaveDestination(suggestedFilename: String, contentType: UTType) async -> URL? { saveCount += 1; return saveURL }
    func selectExportDirectory() -> URL? { exportCount += 1; return exportURL }
}

@MainActor
private final class TransactionalCompatibilityCalls {
    var count = 0
}

nonisolated private final class TransactionalRevealRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSelections: [[URL]] = []
    var selections: [[URL]] { lock.withLock { storedSelections } }
    func record(_ urls: [URL]) { lock.withLock { storedSelections.append(urls) } }
}

nonisolated private final class TransactionalPermissionState: @unchecked Sendable {
    private let lock = NSLock()
    private var granted: Bool
    init(isGranted: Bool) { granted = isGranted }
    var isGranted: Bool {
        get { lock.withLock { granted } }
        set { lock.withLock { granted = newValue } }
    }
}

@MainActor
private struct TransactionalIntakeFixture {
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let model: AppModel
    let documents: DocumentWorkflowModel
    let panels: TransactionalIntakePanels
    let compatibilityCalls: TransactionalCompatibilityCalls
    let revealRecorder: TransactionalRevealRecorder
    let permissionState: TransactionalPermissionState

    init(permissionsGranted: Bool = true) throws {
        suite = "TransactionalIntakeTests.\(UUID().uuidString)"
        defaults = makeDefaults(named: suite)
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let permissionState = TransactionalPermissionState(isGranted: permissionsGranted)
        self.permissionState = permissionState
        let permissions = TestCapturePermissionService(
            statusProvider: { CapturePermissionStatus(hasScreenRecording: permissionState.isGranted, hasAccessibility: permissionState.isGranted) },
            canRequestHandler: { _ in false })
        let revealRecorder = TransactionalRevealRecorder()
        self.revealRecorder = revealRecorder
        let live = AppSystemServices.live(permissions: permissions)
        let services = AppSystemServices(files: live.files,
            workspace: TestWorkspaceService(revealedURLs: { revealRecorder.record($0) }),
            screens: live.screens, mouse: live.mouse, windowFocus: live.windowFocus, bundle: live.bundle,
            pasteboard: live.pasteboard, clock: live.clock, ids: live.ids, scheduler: live.scheduler,
            permissions: permissions, accessibility: live.accessibility,
            screenCapturePlatform: live.screenCapturePlatform, screenRecordingPlatform: live.screenRecordingPlatform,
            connectedDevicePlatform: live.connectedDevicePlatform)
        let environment = AppEnvironment(defaults: defaults, buildTarget: .dev, permissions: permissions,
            systemServices: services)
        let recovery = DocumentRecoveryStore(baseURL: root.appendingPathComponent("Recovery"))
        let compatibilityCalls = TransactionalCompatibilityCalls()
        let compatibility = IncompatibleDocumentCoordinator(confirmationHandler: { _ in
            compatibilityCalls.count += 1
            return false
        }, trashHandler: { _ in compatibilityCalls.count += 1 },
            cancellationNoticeHandler: { _ in compatibilityCalls.count += 1 },
            terminationHandler: { compatibilityCalls.count += 1 })
        self.compatibilityCalls = compatibilityCalls
        model = retainForTestLifetime(AppModel(defaults: defaults, environment: environment,
            compositionOverrides: AppModelCompositionOverrides(recoveryStore: recovery,
                incompatibleDocumentCoordinator: compatibility),
            shouldCheckCompatibilityOnLaunch: false, shouldStartArchiveMaintenance: false))
        let ports = model.documents.dependencies
        panels = TransactionalIntakePanels()
        documents = DocumentWorkflowModel(dependencies: DocumentWorkflowDependencies(
            capabilities: ports.capabilities, systemServices: ports.systemServices,
            lifecycle: ports.lifecycle, capture: ports.capture, clipboard: ports.clipboard,
            video: ports.video, archive: ports.archive, panels: panels,
            windowPresenter: ports.windowPresenter, pasteboardImporter: ports.pasteboardImporter,
            floatingReferenceCoordinator: ports.floatingReferenceCoordinator,
            historyPreviewCoordinator: ports.historyPreviewCoordinator,
            textRecognitionCoordinator: ports.textRecognitionCoordinator),
            recoveryStore: recovery,
            videoRecoveryStore: VideoRecoveryStore(rootURL: root.appendingPathComponent("VideoRecovery")),
            incompatibleDocumentCoordinator: compatibility,
            preferenceStore: environment.preferenceStores.editor,
            pendingRecoverySession: nil, allCaptureHistoryEntries: [], recentSnipEntries: [], recycleBinEntries: [])
    }

    func installScreenshot() -> EditorController {
        let controller = EditorController(capture: makeCapturedScreenshot(), defaults: defaults,
            capabilities: testCapabilities, isPrivateDocument: true)
        let annotation = Annotation.makeText(at: CGPoint(x: 20, y: 20)).updatingText("Keep me")
        controller.addAnnotation(annotation)
        controller.updateViewportCanvasSize(CGSize(width: 500, height: 350))
        controller.zoomIn()
        documents.installEditorController(controller, documentURL: nil, savedSession: nil,
            shouldCreateRecoverySession: false)
        return controller
    }

    func installGuide() -> GuideEditorController {
        let image = makeCoordinateImage(width: 32, height: 24)
        var project = GuideProject(source: .displays(.current), isPrivate: true)
        let step = GuideStep(sequence: 1, eventKind: .manual, caption: "Step 1",
            session: GuideStepSession(sourceCoordinateRect: CGRect(x: 0, y: 0, width: 32, height: 24),
                sourcePixelSize: CGSize(width: 32, height: 24)))
        project.steps = [step]
        let controller = GuideEditorController(document: EditableGuideDocument(project: project,
            stepImages: [step.id: image], previewImage: nil, logoImage: nil, mediaSegmentURLs: [:]))
        documents.installGuideController(controller, documentURL: nil, savedProject: nil)
        return controller
    }

    func cleanUp() {
        for workflow in [documents, model.documents] {
            workflow.resetGuideExportState()
            workflow.pendingCompositionExportTask?.cancel()
            workflow.activeCompositionExportID = nil
            workflow.pendingGuideAutosaveTask?.cancel()
            workflow.pendingAutosaveTask?.cancel()
            workflow.pendingRecoveryRefreshTask?.cancel()
            workflow.pendingRecoveryWriteTasks.values.forEach { $0.cancel() }
            workflow.currentRecoverySessionID = nil
            workflow.discardCurrentDocument()
        }
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}
