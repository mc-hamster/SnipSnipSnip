import CoreGraphics
import Foundation
import XCTest
@testable import SnipSnipSnip

@MainActor
final class DocumentSaveConsistencyTests: XCTestCase {
    func testScreenshotSaveKeepsEditsMadeAfterTheWriteSnapshotDirty() async throws {
        let fixture = try SaveConsistencyFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.installScreenshot()
        let savedSession = controller.documentSession
        fixture.capture.beforeWork = {
            controller.addAnnotation(Annotation.makeText(at: CGPoint(x: 5, y: 5)).updatingText("Edited while saving"))
        }
        let destination = fixture.root.appendingPathComponent("Saved.sss")

        let saved = await fixture.documents.saveDocument(controller, to: destination)

        XCTAssertTrue(saved)
        XCTAssertEqual(fixture.documents.savedDocumentSession, savedSession)
        XCTAssertNotEqual(controller.documentSession, savedSession)
        XCTAssertTrue(fixture.documents.hasUnsavedChanges)
        XCTAssertTrue(fixture.documents.shouldAutosave(for: controller))
        let manifest = try String(contentsOf: destination.appendingPathComponent("document.json"), encoding: .utf8)
        XCTAssertFalse(manifest.contains("Edited while saving"), "The saved baseline must describe the bytes actually written")
    }

    func testSaveCompletionCannotRelabelAReplacementEditor() async throws {
        let fixture = try SaveConsistencyFixture()
        defer { fixture.cleanUp() }
        let first = fixture.installScreenshot()
        let replacement = EditorController(capture: makeCapturedScreenshot(sourceName: "Replacement"),
                                           defaults: fixture.defaults, capabilities: testCapabilities)
        let replacementURL = fixture.root.appendingPathComponent("Replacement.sss")
        fixture.capture.beforeWork = {
            fixture.documents.installEditorController(replacement, documentURL: replacementURL,
                savedSession: replacement.documentSession, shouldCreateRecoverySession: false)
        }

        let saved = await fixture.documents.saveDocument(first, to: fixture.root.appendingPathComponent("First.sss"))

        XCTAssertFalse(saved, "An old Save-and-Continue must not replace the new editor")
        XCTAssertTrue(fixture.documents.editorController === replacement)
        XCTAssertEqual(fixture.documents.currentDocumentURL, replacementURL)
        XCTAssertEqual(fixture.documents.savedDocumentSession, replacement.documentSession)
        XCTAssertFalse(fixture.documents.hasUnsavedChanges)
    }

    func testSaveAndContinueDoesNotDiscardEditsMadeDuringSaving() async throws {
        let fixture = try SaveConsistencyFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.installScreenshot(documentURL: fixture.root.appendingPathComponent("Current.sss"))
        controller.addAnnotation(Annotation.makeText(at: CGPoint(x: 5, y: 5)).updatingText("First edit"))
        fixture.capture.beforeWork = {
            controller.addAnnotation(Annotation.makeText(at: CGPoint(x: 8, y: 8)).updatingText("Later edit"))
        }
        var continued = false
        var cancelled = false
        fixture.documents.pendingEditorAction = { continued = true }
        fixture.documents.pendingEditorCancellation = { cancelled = true }

        fixture.documents.confirmSaveBeforeContinuing()
        await waitUntil(timeoutNanoseconds: 5_000_000_000) { continued || cancelled }

        XCTAssertTrue(cancelled)
        XCTAssertFalse(continued)
        XCTAssertTrue(fixture.documents.editorController === controller)
        XCTAssertTrue(fixture.documents.hasUnsavedChanges)
    }

    func testUndoLibrarySwitchRestoresTheOriginalSavedBaseline() throws {
        let fixture = try SaveConsistencyFixture()
        defer { fixture.cleanUp() }
        let originalURL = fixture.root.appendingPathComponent("Original.sss")
        let original = fixture.installScreenshot(documentURL: originalURL)
        let savedSession = original.documentSession
        let savedState = fixture.documents.savedEditorAutosaveState
        original.addAnnotation(Annotation.makeText(at: CGPoint(x: 5, y: 5)).updatingText("Unsaved change"))
        let previous = LibrarySwitchSnapshot(controller: original, documentURL: originalURL,
            savedSession: savedSession, savedAutosaveState: savedState, recoverySessionID: nil)
        _ = fixture.installScreenshot()
        fixture.documents.previousLibrarySwitchSnapshot = previous

        fixture.documents.undoLastLibrarySwitch()

        XCTAssertTrue(fixture.documents.editorController === original)
        XCTAssertEqual(fixture.documents.savedEditorAutosaveState, savedState)
        XCTAssertTrue(fixture.documents.hasUnsavedChanges)
        XCTAssertTrue(fixture.documents.shouldAutosave(for: original))
    }

    func testExitDoesNotSucceedWhenAnUnsavedScreenshotHasNoWritableRecoverySession() async throws {
        let fixture = try SaveConsistencyFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.installScreenshot()
        let blockedDirectory = fixture.root.appendingPathComponent("Not a directory")
        try Data("blocked".utf8).write(to: blockedDirectory)
        fixture.documents.recoveryStore = DocumentRecoveryStore(baseURL: blockedDirectory)

        let prepared = await fixture.documents.prepareForApplicationExit()

        XCTAssertFalse(prepared)
        XCTAssertTrue(fixture.documents.editorController === controller)
        XCTAssertTrue(fixture.documents.hasUnsavedChanges)
        XCTAssertNil(fixture.documents.currentRecoverySessionID)
    }

    func testLateVideoRecoveryKeepsANewlyOpenedScreenshot() async throws {
        let fixture = try SaveConsistencyFixture()
        defer { fixture.cleanUp() }
        let recording = try fixture.makeRecording()
        try fixture.documents.videoRecoveryStore.save(EditableVideoDocument(
            recording: recording, session: VideoEditorSession(trimStartSeconds: 0, trimEndSeconds: 10, posterTimeSeconds: 0)))

        fixture.documents.recoverLastVideoSession()
        let replacement = fixture.installScreenshot()
        await waitUntil(timeoutNanoseconds: 5_000_000_000) { !fixture.documents.isRecoveringVideo }

        XCTAssertFalse(fixture.documents.isRecoveringVideo)
        XCTAssertTrue(fixture.documents.editorController === replacement)
        XCTAssertNil(fixture.documents.videoEditorController)
        XCTAssertTrue(fixture.documents.videoRecoveryStore.hasRecovery())
    }

    func testVideoSaveKeepsNewerEditsAgainstTheFrozenSavedSession() async throws {
        let fixture = try SaveConsistencyFixture()
        defer { fixture.cleanUp() }
        let controller = VideoEditorController(recording: try fixture.makeRecording())
        fixture.documents.installVideoController(controller, documentURL: nil, savedSession: nil)
        let savedSession = controller.documentSession
        fixture.capture.beforeWork = { controller.updateTrimStart(2) }
        let destination = fixture.root.appendingPathComponent("Video.sssvideo")

        let saved = await fixture.documents.saveVideoDocument(controller, to: destination)

        XCTAssertTrue(saved)
        XCTAssertEqual(fixture.documents.savedVideoSession, savedSession)
        XCTAssertEqual(fixture.documents.videoEditorController?.documentSession.trimStartSeconds, 2)
        XCTAssertTrue(fixture.documents.hasUnsavedChanges)
        XCTAssertEqual(try SSSVideoDocumentPackage.load(from: destination).session, savedSession)
    }
}

@MainActor
private final class SaveConsistencyCapturePort: DocumentCaptureWorkflowPort {
    let base: any DocumentCaptureWorkflowPort
    var beforeWork: (() -> Void)?
    init(base: any DocumentCaptureWorkflowPort) { self.base = base }
    var screenshotFilenameTemplate: String { base.screenshotFilenameTemplate }
    var screenshotDragOutFormat: ImageExportFormat { base.screenshotDragOutFormat }
    var screenshotJPEGQuality: CGFloat { base.screenshotJPEGQuality }
    var uiMapEnabled: Bool { base.uiMapEnabled }
    var isInteractiveCaptureAutosaveSuspended: Bool { base.isInteractiveCaptureAutosaveSuspended }
    func cancelPendingWindowThumbnailRefresh() { base.cancelPendingWindowThumbnailRefresh() }

    func performDocumentWork<Result>(message: String, _ operation: () async throws -> Result) async rethrows -> Result {
        // The real workflow has already frozen the write payload at this seam.
        let update = beforeWork
        beforeWork = nil
        update?()
        return try await base.performDocumentWork(message: message, operation)
    }
}

@MainActor
private struct SaveConsistencyFixture {
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let model: AppModel
    let documents: DocumentWorkflowModel
    let capture: SaveConsistencyCapturePort

    init() throws {
        suite = "DocumentSaveConsistencyTests.\(UUID())"
        defaults = makeDefaults(named: suite)
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let recovery = DocumentRecoveryStore(baseURL: root.appendingPathComponent("Recovery"))
        model = retainForTestLifetime(AppModel(defaults: defaults, recoveryStore: recovery,
            shouldCheckCompatibilityOnLaunch: false, shouldStartArchiveMaintenance: false))
        let ports = model.documents.dependencies
        capture = SaveConsistencyCapturePort(base: ports.capture)
        documents = DocumentWorkflowModel(dependencies: DocumentWorkflowDependencies(
            capabilities: ports.capabilities, systemServices: ports.systemServices, lifecycle: ports.lifecycle,
            capture: capture, clipboard: ports.clipboard, video: ports.video, archive: ports.archive,
            panels: ports.panels, windowPresenter: TestDocumentWindowPresenter(), pasteboardImporter: ports.pasteboardImporter,
            floatingReferenceCoordinator: ports.floatingReferenceCoordinator,
            historyPreviewCoordinator: ports.historyPreviewCoordinator, textRecognitionCoordinator: ports.textRecognitionCoordinator),
            recoveryStore: recovery, videoRecoveryStore: VideoRecoveryStore(rootURL: root.appendingPathComponent("VideoRecovery")),
            incompatibleDocumentCoordinator: model.documents.incompatibleDocumentCoordinator,
            preferenceStore: model.documents.preferenceStore, pendingRecoverySession: nil,
            allCaptureHistoryEntries: [], recentSnipEntries: [], recycleBinEntries: [])
    }

    func installScreenshot(documentURL: URL? = nil) -> EditorController {
        let controller = EditorController(capture: makeCapturedScreenshot(), defaults: defaults, capabilities: testCapabilities)
        documents.installEditorController(controller, documentURL: documentURL,
            savedSession: documentURL == nil ? nil : controller.documentSession, shouldCreateRecoverySession: false)
        return controller
    }

    func makeRecording() throws -> CapturedVideoRecording {
        let source = root.appendingPathComponent("source.mp4")
        try Data("video fixture".utf8).write(to: source)
        return CapturedVideoRecording(sourceURL: source, kind: .region, sourceName: "Test Video",
            bounds: CGRect(x: 0, y: 0, width: 64, height: 48), recordedAt: Date(), duration: 10,
            preferences: VideoRecordingPreferences(quality: .compact, frameRate: .fifteen,
                recordsSystemAudio: false, recordsMicrophone: false, showsCursor: false, showsMouseClicks: false))
    }

    func cleanUp() {
        for workflow in [documents, model.documents] {
            workflow.currentRecoverySessionID = nil
            workflow.discardCurrentDocument()
            workflow.resetEditorSessionState()
        }
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}
