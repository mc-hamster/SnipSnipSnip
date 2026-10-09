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
        assertPixel(samplePixel(in: rendered, topLeftX: 20, topLeftY: 16), isCloseTo: pixelSample(for: .redactionFill), tolerance: 4)
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

    func testConflictingActionPromptDoesNotPromiseRecoveryForPrivateGuide() {
        let privatePrompt = GuideConflictingActionPrompt(action: "opening another document", isPrivate: true)
        XCTAssertEqual(privatePrompt.confirmationTitle, "Stop & Open Guide")
        XCTAssertTrue(privatePrompt.detail.contains("not written to recovery"))
        XCTAssertTrue(privatePrompt.detail.contains("save or export"))
        let ordinaryPrompt = GuideConflictingActionPrompt(action: "opening another document", isPrivate: false)
        XCTAssertEqual(ordinaryPrompt.confirmationTitle, "Stop & Continue")
        XCTAssertTrue(ordinaryPrompt.detail.contains("kept for recovery"))
    }

#if !APP_STORE_BUILD
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
