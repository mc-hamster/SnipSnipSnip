import AppKit
import XCTest
@testable import SnipSnipSnip

@MainActor
final class GuideWorkflowAuditTests: XCTestCase {
    func testDuplicateStepPreservesAdvancedRedactionAcrossUndoRedoAndSave() throws {
        let image = makeCoordinateImage(width: 60, height: 40)
        let snapshot = makeEditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: 60, height: 40),
            annotations: [Annotation.makeSolidRedaction(in: CGRect(x: 10, y: 8, width: 24, height: 16))])
        let advanced = makeEditableDocument(capture: makeCapturedScreenshot(image: image),
            session: makeEditorDocumentSession(initialSnapshot: snapshot))
        let controller = emptyGuideEditor()
        controller.addImportedImage(image, advancedEdit: advanced)
        let originalID = try XCTUnwrap(controller.selectedStep?.id)

        controller.duplicateSelected()
        let duplicateID = try XCTUnwrap(controller.selectedStep?.id)
        XCTAssertNotEqual(duplicateID, originalID)
        XCTAssertEqual(controller.advancedEdits[duplicateID]?.session.currentSnapshot, snapshot)
        XCTAssertNotNil(controller.selectedStep?.session.annotationSessionAsset)

        controller.undo()
        XCTAssertNil(controller.advancedEdits[duplicateID])
        XCTAssertNotNil(controller.advancedEdits[originalID])
        controller.redo()
        XCTAssertEqual(controller.advancedEdits[duplicateID]?.session.currentSnapshot, snapshot)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GuideDuplicate-\(UUID()).sssguide")
        defer { try? FileManager.default.removeItem(at: url) }
        try SSSGuideDocumentPackage.save(document: controller.editableDocument(), to: url)
        let saved = try SSSGuideDocumentPackage.load(from: url)
        let savedEdit = try XCTUnwrap(saved.advancedEdits[duplicateID])
        let rendered = try XCTUnwrap(ScreenshotPresentationRenderer.render(baseImage: try XCTUnwrap(saved.stepImages[duplicateID]), snapshot: savedEdit.session.currentSnapshot))
        let pixel = samplePixel(in: rendered, topLeftX: 20, topLeftY: 16)
        let redaction = pixelSample(for: .redactionFill)
        XCTAssertEqual(Double(pixel.red), Double(redaction.red), accuracy: 4)
        XCTAssertEqual(Double(pixel.green), Double(redaction.green), accuracy: 4)
        XCTAssertEqual(Double(pixel.blue), Double(redaction.blue), accuracy: 4)
    }

    func testImportedAdvancedEditBelongsToAddStepUndoCommand() throws {
        let image = makeCoordinateImage(width: 60, height: 40)
        let advanced = makeEditableDocument(capture: makeCapturedScreenshot(image: image))
        let controller = emptyGuideEditor()
        controller.addImportedImage(image, advancedEdit: advanced)
        let id = try XCTUnwrap(controller.selectedStep?.id)
        XCTAssertNotNil(controller.advancedEdits[id])
        controller.undo()
        XCTAssertTrue(controller.project.steps.isEmpty)
        XCTAssertTrue(controller.advancedEdits.isEmpty)
        controller.redo()
        XCTAssertEqual(controller.project.steps.first?.id, id)
        XCTAssertNotNil(controller.project.steps.first?.session.annotationSessionAsset)
        XCTAssertEqual(controller.advancedEdits[id]?.session, advanced.session)
    }

    func testDuplicateMultipleStepsIsOneUndoableActionWithStableOrderAndIDs() throws {
        let controller = emptyGuideEditor()
        let image = makeCoordinateImage(width: 60, height: 40)
        for caption in ["First", "Middle", "Last"] { controller.addImportedImage(image, caption: caption) }
        let originalIDs = controller.project.steps.map(\.id)
        controller.selection = [originalIDs[0], originalIDs[2]]
        controller.duplicateSelected()
        let duplicatedIDs = controller.project.steps.map(\.id)
        XCTAssertEqual(controller.project.steps.map(\.caption), ["First", "First (Copy)", "Middle", "Last", "Last (Copy)"])
        controller.undo()
        XCTAssertEqual(controller.project.steps.map(\.id), originalIDs)
        controller.redo()
        XCTAssertEqual(controller.project.steps.map(\.id), duplicatedIDs)
        XCTAssertEqual(controller.selection, [duplicatedIDs[1], duplicatedIDs[4]])
    }

    func testConcurrentGuideFinalizationWaitsForOneResultAndPresentsItOnce() async throws {
        let finalization = GuideFinalizationCoordinator()
        let document = emptyGuideEditor().editableDocument()
        let context = GuideExitContext(isPrivate: true, hasSteps: true)
        var calls = 0
        var continuation: CheckedContinuation<EditableGuideDocument?, Error>?
        let operation: @MainActor () async throws -> EditableGuideDocument? = {
            calls += 1
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        let first = Task { try await finalization.finish(context: context, using: operation) }
        await waitUntil { continuation != nil }
        let second = Task { try await finalization.finish(using: operation) }
        await Task.yield()
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(finalization.isFinishing)
        try XCTUnwrap(continuation).resume(returning: document)
        let firstDocument = try await first.value
        let secondDocument = try await second.value
        XCTAssertEqual(firstDocument.document.project.id, document.project.id)
        XCTAssertEqual(secondDocument.document.project.id, document.project.id)
        XCTAssertTrue(finalization.isFinishing, "Finishing remains active until the result is handled")
        XCTAssertEqual(finalization.exitContext, context)
        XCTAssertTrue(finalization.shouldPresent(firstDocument))
        XCTAssertFalse(finalization.shouldPresent(secondDocument))
        finalization.complete(firstDocument)
        XCTAssertFalse(finalization.isFinishing)
        XCTAssertNil(finalization.exitContext)
    }

    func testMissingFinalizedGuideIsAnErrorAndAllowsRetry() async throws {
        let finalization = GuideFinalizationCoordinator()
        do {
            _ = try await finalization.finish { nil }
            XCTFail("A missing result must not allow an early exit")
        } catch let error as AutomationExecutionError {
            XCTAssertEqual(error.code, .noActiveGuide)
        }
        XCTAssertFalse(finalization.isFinishing)
        let document = emptyGuideEditor().editableDocument()
        let retried = try await finalization.finish { document }
        XCTAssertEqual(retried.document.project.id, document.project.id)
        finalization.complete(retried)
        XCTAssertFalse(finalization.isFinishing)
    }

    func testDiscardDuringFinalizationSuppressesEveryWaitingPresentationAndResetsForNextGuide() async throws {
        let finalization = GuideFinalizationCoordinator()
        let document = emptyGuideEditor().editableDocument()
        var continuation: CheckedContinuation<EditableGuideDocument?, Error>?
        let finishing = Task {
            try await finalization.finish {
                try await withCheckedThrowingContinuation { continuation = $0 }
            }
        }
        await waitUntil { continuation != nil }
        let discard = try XCTUnwrap(finalization.discardCurrentResult())
        try XCTUnwrap(continuation).resume(returning: document)
        let stoppedResult = try await finishing.value
        let discardedResult = try await discard.value
        XCTAssertTrue(stoppedResult === discardedResult)
        XCTAssertTrue(stoppedResult.wasDiscarded)
        XCTAssertFalse(finalization.shouldPresent(stoppedResult), "Stop/Export must not publish a discarded Guide")
        XCTAssertFalse(finalization.shouldPresent(discardedResult))
        finalization.complete(discardedResult)

        let nextDocument = emptyGuideEditor().editableDocument()
        let next = try await finalization.finish { nextDocument }
        finalization.complete(discardedResult)
        XCTAssertTrue(finalization.isFinishing, "Cleanup for the discarded result must not clear a newer attempt")
        XCTAssertFalse(next.wasDiscarded)
        XCTAssertTrue(finalization.shouldPresent(next))
        finalization.complete(next)
        XCTAssertFalse(finalization.isFinishing)
    }

    func testConflictingActionPromptDoesNotPromiseRecoveryForPrivateGuide() {
        let privatePrompt = GuideConflictingActionPrompt(action: "opening another document", isPrivate: true)
        XCTAssertEqual(privatePrompt.confirmationTitle, "Stop & Open Guide")
        XCTAssertTrue(privatePrompt.detail.contains("not written to recovery"))
        XCTAssertTrue(privatePrompt.detail.contains("save or export"))
        let ordinaryPrompt = GuideConflictingActionPrompt(action: "opening another document", isPrivate: false)
        XCTAssertEqual(ordinaryPrompt.confirmationTitle, "Stop & Continue")
        XCTAssertTrue(ordinaryPrompt.detail.contains("kept for recovery"))
    }

    func testGuideAutomationSourceSummaryUsesCaptureSourceKind() {
        let frame = CGRect(x: 0, y: 0, width: 60, height: 40)
        let cases: [(GuideCaptureSource, GuideAutomationTarget)] = [
            (.window(id: 1, ownerPID: 42, name: "Window", frame: frame), .window),
            (.app(processID: 42, bundleIdentifier: nil, name: "App", initialFrame: frame), .app),
            (.region(frame), .region), (.displays(.current), .display),
            (.displays(.all), .display), (.displays(.selected([1])), .display),
        ]
        for (source, expected) in cases { XCTAssertEqual(source.automationTarget, expected) }
    }

    func testGuideExportCleanupPreservesSimilarlyNamedUserFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GuideCleanup-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let userFile = directory.appendingPathComponent("CleanupTest.backup.tmp.pdf")
        let ownedTemporaryFile = directory.appendingPathComponent("CleanupTest.\(UUID()).tmp.pdf")
        let sentinel = Data("existing user backup".utf8)
        for url in [userFile, ownedTemporaryFile] {
            try sentinel.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-172_800)], ofItemAtPath: url.path)
        }
        let controller = emptyGuideEditor()
        controller.addImportedImage(makeCoordinateImage(width: 60, height: 40))
        var document = controller.editableDocument()
        document.project.exportSettings.filenameTemplate = "CleanupTest"
        _ = try await GuideExporter.export(document: document, format: .pdf, directory: directory)
        XCTAssertEqual(try Data(contentsOf: userFile), sentinel)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedTemporaryFile.path))
    }

#if !APP_STORE_BUILD
    func testGuideAutomationRefreshesWindowTargetsOnlyAfterPermissionPreflight() async {
        for target in [GuideAutomationTarget.window, .app] {
            for hasAccess in [false, true] {
                let name = "GuideAudit.liveTargets.\(UUID())"
                let defaults = makeDefaults(named: name)
                defer { defaults.removePersistentDomain(forName: name) }
                let service = TestCapturePermissionService(status: CapturePermissionStatus(hasScreenRecording: hasAccess, hasAccessibility: hasAccess))
                let base = AppSystemServices.live(permissions: service)
                let services = AppSystemServices(files: base.files, workspace: base.workspace, screens: base.screens,
                    mouse: base.mouse, windowFocus: base.windowFocus, bundle: base.bundle, pasteboard: base.pasteboard,
                    clock: base.clock, ids: base.ids, scheduler: base.scheduler, permissions: service,
                    accessibility: TestGuideAccessibility(isTrusted: false), screenCapturePlatform: base.screenCapturePlatform,
                    screenRecordingPlatform: base.screenRecordingPlatform, connectedDevicePlatform: base.connectedDevicePlatform)
                let lifecycle = TestWorkflowLifecyclePresenter()
                let permissions = PermissionWorkflowModel(dependencies: PermissionWorkflowDependencies(capabilities: testCapabilities,
                    permissions: service, scheduler: SystemScheduler(), lifecycle: lifecycle))
                let capture = GuideAuditCapturePort()
                capture.availableWindows = [makeCaptureWindow(id: 7)]
                let model = GuideWorkflowModel(dependencies: GuideWorkflowDependencies(capabilities: testCapabilities,
                    systemServices: services, appWindowPresenter: GuideAuditWindowPresenter(), permissions: permissions,
                    lifecycle: lifecycle, capture: capture, video: GuideAuditVideoPort()),
                    preferenceStore: GuidePreferenceStore(storage: defaults),
                    recoveryStore: GuideRecoveryStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(name)))
                let request = AutomationRequest(source: AutomationSource(kind: .commandLine), command: .guide(.start(target)), interactionPolicy: .never)
                let result = await model.guideAutomation(.start(target), request: request)
                let expectedCode: AutomationErrorCode = hasAccess ? .targetUnavailable : .permissionDenied
                XCTAssertEqual(result.error?.code, expectedCode)
                XCTAssertEqual(capture.targetDiscoveryCount, hasAccess ? 1 : 0)
                XCTAssertNil(permissions.activePermissionRequest)
                XCTAssertNil(permissions.permissionSetupGuide)
            }
        }
    }

    func testInteractiveRegionAutomationKeepsPrivateRequestUntilCancelledOrReplaced() async {
        let name = "GuideAudit.privateSetup.\(UUID())"
        let defaults = makeDefaults(named: name)
        let model = AppModel(defaults: defaults,
            environment: AppEnvironment(defaults: defaults, buildTarget: .dev, permissions: TestCapturePermissionService()),
            recoveryStore: DocumentRecoveryStore(baseURL: FileManager.default.temporaryDirectory.appendingPathComponent(name)),
            shouldCheckCompatibilityOnLaunch: false, shouldStartArchiveMaintenance: false)
        defer { model.guide.cancelQuickStart(); defaults.removePersistentDomain(forName: name) }
        let privateRequest = regionRequest(isPrivate: true)
        let result = await model.guide.guideAutomation(.start(.region), request: privateRequest)
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertTrue(model.guide.captureSetupIsPrivate)
        XCTAssertFalse(model.capture.privateCaptureEnabled)
        model.guide.cancelTargetSelection()
        XCTAssertTrue(model.guide.captureSetupIsPrivate, "Returning to the same setup keeps its privacy")
        model.guide.cancelQuickStart()
        XCTAssertFalse(model.guide.captureSetupIsPrivate)
        _ = await model.guide.guideAutomation(.start(.region), request: privateRequest)
        _ = await model.guide.guideAutomation(.start(.region), request: regionRequest(isPrivate: false))
        XCTAssertFalse(model.guide.captureSetupIsPrivate, "A replacement request must not inherit the old private latch")
        model.capture.updatePrivateCaptureEnabled(true)
        XCTAssertTrue(model.guide.captureSetupIsPrivate, "Current global privacy still applies")
        model.guide.resetGuidePreferencesToDefaults()
        model.capture.updatePrivateCaptureEnabled(false)
        XCTAssertFalse(model.guide.captureSetupIsPrivate)
    }

    func testPrivateRegionSetupDoesNotCreatePermissionRestartCheckpoint() async {
        let name = "GuideAudit.privateRestart.\(UUID())"
        let defaults = makeDefaults(named: name)
        let status = GuideAuditPermissionState()
        let service = TestCapturePermissionService(statusProvider: { status.current() })
        let model = AppModel(defaults: defaults,
            environment: AppEnvironment(defaults: defaults, buildTarget: .dev, permissions: service),
            recoveryStore: DocumentRecoveryStore(baseURL: FileManager.default.temporaryDirectory.appendingPathComponent(name)),
            shouldCheckCompatibilityOnLaunch: false, shouldStartArchiveMaintenance: false)
        defer { model.guide.cancelQuickStart(); defaults.removePersistentDomain(forName: name) }
        _ = await model.guide.guideAutomation(.start(.region), request: regionRequest(isPrivate: true))
        status.set(CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: false))
        model.guide.beginSelectedSourceSelection()
        XCTAssertNotNil(model.permissions.permissionContinuation)
        XCTAssertTrue(model.guide.captureSetupIsPrivate)
        XCTAssertNil(PermissionRestartStore(defaults: defaults).load())
        model.guide.cancelQuickStart()
        XCTAssertNil(model.permissions.permissionContinuation)
        XCTAssertFalse(model.guide.captureSetupIsPrivate)
    }

    func testCancelledGuideTargetDiscoveryCannotReopenSetup() async throws {
        let name = "GuideAudit.cancelledTarget.\(UUID())"
        let defaults = makeDefaults(named: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let service = TestCapturePermissionService()
        let lifecycle = TestWorkflowLifecyclePresenter()
        let permissions = PermissionWorkflowModel(dependencies: PermissionWorkflowDependencies(
            capabilities: testCapabilities, permissions: service, scheduler: SystemScheduler(), lifecycle: lifecycle))
        let capture = GuideAuditCapturePort()
        let presenter = GuideAuditWindowPresenter()
        let model = GuideWorkflowModel(dependencies: GuideWorkflowDependencies(capabilities: testCapabilities,
            systemServices: AppSystemServices.live(permissions: service), appWindowPresenter: presenter,
            permissions: permissions, lifecycle: lifecycle, capture: capture, video: GuideAuditVideoPort()),
            preferenceStore: GuidePreferenceStore(storage: defaults),
            recoveryStore: GuideRecoveryStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(name)))
        _ = await model.guideAutomation(.start(.region), request: regionRequest(isPrivate: true))
        model.beginSelectedSourceSelection()
        await waitUntil { capture.continuation != nil }
        let continuation = try XCTUnwrap(capture.continuation)
        model.cancelQuickStart()
        continuation.resume(throwing: ScreenCaptureError.noDisplays)
        capture.continuation = nil
        await waitUntil { presenter.restoreCount == 1 }
        XCTAssertEqual(presenter.restoreCount, 1)
        XCTAssertFalse(model.isShowingQuickStart)
        XCTAssertNil(model.targetPickerKind)
        XCTAssertFalse(model.captureSetupIsPrivate)
    }
#endif

    private func regionRequest(isPrivate: Bool) -> AutomationRequest {
        AutomationRequest(source: AutomationSource(kind: .commandLine), command: .guide(.start(.region)),
            interactionPolicy: .promptIfNeeded, privacy: AutomationPrivacyOptions(privateCapture: isPrivate))
    }

    private func emptyGuideEditor() -> GuideEditorController {
        GuideEditorController(document: EditableGuideDocument(project: GuideProject(source: .displays(.current)),
            stepImages: [:], previewImage: nil, logoImage: nil, mediaSegmentURLs: [:]))
    }
}

private final class GuideAuditPermissionState: @unchecked Sendable {
    private let lock = NSLock()
    private var status = CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: true)
    func current() -> CapturePermissionStatus { lock.withLock { status } }
    func set(_ status: CapturePermissionStatus) { lock.withLock { self.status = status } }
}

@MainActor
private final class GuideAuditCapturePort: GuideCaptureWorkflowPort {
    var availableWindows: [CaptureWindowSummary] = []
    var regionCapturePreferences = RegionCapturePreferences()
    var isWorking = false
    var isConnectedDeviceSessionActive = false
    var privateCaptureEnabled = false
    var guideHotKeyCode: UInt16 = 0
    var targetDiscoveryCount = 0
    func availableGuideTargetWindows() async throws -> [CaptureWindowSummary] {
        targetDiscoveryCount += 1
        return []
    }
    var continuation: CheckedContinuation<(windows: [CaptureWindowSummary], snapshot: DesktopCompositeSnapshot), Error>?
    func videoWindowSelectionSnapshot() async throws -> (windows: [CaptureWindowSummary], snapshot: DesktopCompositeSnapshot) {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
}

@MainActor
private final class GuideAuditVideoPort: GuideVideoWorkflowPort { var blocksNewCapture = false }

@MainActor
private final class GuideAuditWindowPresenter: AppWindowPresenting {
    var restoreCount = 0
    func hideAppWindowIfNeeded(for context: WorkflowPresentationContext) -> AppWindowVisibilityToken? { nil }
    func restoreAppWindowIfNeeded(_ token: AppWindowVisibilityToken?) { restoreCount += 1 }
    func keepAppWindowHidden(_ token: AppWindowVisibilityToken?) {}
    func promoteToRegularApp() {}
    func demoteToAccessoryIfPossible() {}
    func activateApp() {}
}
