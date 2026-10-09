import AVFoundation
import CoreGraphics
import Foundation
import UniformTypeIdentifiers
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

    func testUndoLibrarySwitchRestoresTheOriginalSavedBaseline() async throws {
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
        await waitUntil(timeoutNanoseconds: 5_000_000_000) { fixture.documents.editorController === original }

        XCTAssertTrue(fixture.documents.editorController === original)
        XCTAssertEqual(fixture.documents.savedEditorAutosaveState, savedState)
        XCTAssertTrue(fixture.documents.hasUnsavedChanges)
        XCTAssertTrue(fixture.documents.shouldAutosave(for: original))
    }

    func testPrivateScreenshotExitRequiresExplicitCancelOrDiscardWithoutRecovery() async throws {
        for discards in [false, true] {
            let fixture = try SaveConsistencyFixture()
            defer { fixture.cleanUp() }
            let controller = fixture.installScreenshot(isPrivate: true)
            let exit = Task { await fixture.documents.prepareForApplicationExit() }
            await waitUntil { fixture.documents.isShowingUnsavedChangesPrompt }
            XCTAssertTrue(fixture.documents.isShowingUnsavedChangesPrompt)

            if discards { fixture.documents.discardChangesAndContinue() }
            else { fixture.documents.cancelPendingEditorAction() }

            let prepared = await exit.value
            XCTAssertEqual(prepared, discards)
            XCTAssertEqual(fixture.documents.editorController === controller, !discards)
            XCTAssertTrue(fixture.documents.recoveryStore.allHistoryEntries().isEmpty)
            XCTAssertNil(fixture.documents.currentRecoverySessionID)
        }
    }

    func testPrivateScreenshotExitWaitsForSuccessfulExplicitSave() async throws {
        for fails in [false, true] {
            let fixture = try SaveConsistencyFixture()
            defer { fixture.cleanUp() }
            let directory = fixture.root.appendingPathComponent("Destination")
            if fails { try Data("blocked directory".utf8).write(to: directory) }
            else { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
            let destination = directory.appendingPathComponent("Private.sss")
            let controller = fixture.installScreenshot(documentURL: destination, isPrivate: true)
            controller.addAnnotation(Annotation.makeText(at: CGPoint(x: 5, y: 5)).updatingText("Private unsaved edit"))
            fixture.documents.editableRedactionSaveConfirmationHandler = { .saveEditable }
            let exit = Task { await fixture.documents.prepareForApplicationExit() }
            await waitUntil { fixture.documents.isShowingUnsavedChangesPrompt }
            XCTAssertTrue(fixture.documents.isShowingUnsavedChangesPrompt)

            fixture.documents.confirmSaveBeforeContinuing()

            let prepared = await exit.value
            XCTAssertEqual(prepared, !fails)
            XCTAssertTrue(fixture.documents.editorController === controller)
            XCTAssertEqual(fixture.documents.hasUnsavedChanges, fails)
            XCTAssertTrue(fixture.documents.recoveryStore.allHistoryEntries().isEmpty)
            if !fails { XCTAssertTrue(try SSSDocumentPackage.load(from: destination).isPrivate) }
        }
    }

    func testHistorySwitchKeepsCurrentEditorWhenItsCheckpointFails() async throws {
        let fixture = try SaveConsistencyFixture()
        defer { fixture.cleanUp() }
        let target = try fixture.makeHistoryEntry()
        let original = fixture.installScreenshot()
        original.addAnnotation(Annotation.makeText(at: CGPoint(x: 5, y: 5)).updatingText("Keep these edits"))
        try fixture.blockCurrentRecoverySession()

        fixture.documents.restoreHistoryEntry(target)
        await waitUntil(timeoutNanoseconds: 5_000_000_000) { fixture.model.lifecycle.errorMessage != nil }

        XCTAssertNotNil(fixture.model.lifecycle.errorMessage)
        XCTAssertTrue(fixture.documents.editorController === original)
        XCTAssertTrue(fixture.documents.hasUnsavedChanges)
        XCTAssertNil(fixture.documents.previousLibrarySwitchSnapshot)
    }

    func testHistorySwitchInstallsTargetOnlyAfterKeepingCurrentScreenshot() async throws {
        let fixture = try SaveConsistencyFixture()
        defer { fixture.cleanUp() }
        let target = try fixture.makeHistoryEntry()
        let original = fixture.installScreenshot()
        original.addAnnotation(Annotation.makeText(at: CGPoint(x: 5, y: 5)).updatingText("Retained edit"))

        fixture.documents.restoreHistoryEntry(target)
        XCTAssertTrue(fixture.documents.editorController === original, "Navigation waits for durable recovery")
        await waitUntil(timeoutNanoseconds: 5_000_000_000) { fixture.documents.editorController !== original }

        XCTAssertFalse(fixture.documents.editorController === original)
        let previous = try XCTUnwrap(fixture.documents.previousLibrarySwitchSnapshot)
        XCTAssertTrue(previous.controller === original)
        let sessionID = try XCTUnwrap(previous.recoverySessionID)
        let saved = try XCTUnwrap(fixture.documents.recoveryStore.historyEntries(for: sessionID).first)
        let manifest = try String(contentsOf: saved.packageURL.appendingPathComponent("document.json"), encoding: .utf8)
        XCTAssertTrue(manifest.contains("Retained edit"))
    }

    func testUndoHistorySwitchRetainsCurrentEditorAndUndoWhenCheckpointFails() async throws {
        let fixture = try SaveConsistencyFixture()
        defer { fixture.cleanUp() }
        let previous = fixture.installScreenshot()
        let previousSnapshot = LibrarySwitchSnapshot(controller: previous, documentURL: nil,
            savedSession: nil, savedAutosaveState: nil, recoverySessionID: nil)
        let current = fixture.installScreenshot()
        fixture.documents.previousLibrarySwitchSnapshot = previousSnapshot
        try fixture.blockCurrentRecoverySession()

        fixture.documents.undoLastLibrarySwitch()
        await waitUntil(timeoutNanoseconds: 5_000_000_000) { fixture.model.lifecycle.errorMessage != nil }

        XCTAssertNotNil(fixture.model.lifecycle.errorMessage)
        XCTAssertTrue(fixture.documents.editorController === current)
        XCTAssertTrue(fixture.documents.previousLibrarySwitchSnapshot?.controller === previous)
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
        let recording = try await VideoTestMedia.make(in: fixture.root, duration: 6, width: 64, height: 48)
        let controller = VideoEditorController(recording: recording, posterImage: makeCoordinateImage(width: 64, height: 48))
        fixture.documents.installVideoController(controller, documentURL: nil, savedSession: nil)
        let savedSession = controller.documentSession
        fixture.capture.beforeWork = { controller.updateTrimStart(2) }
        let destination = fixture.root.appendingPathComponent("Video.sssvideo")

        let saved = await fixture.documents.saveVideoDocument(controller, to: destination)

        XCTAssertTrue(saved, fixture.model.lifecycle.errorMessage ?? "Save returned false")
        XCTAssertTrue(fixture.documents.videoEditorController === controller)
        XCTAssertEqual(fixture.documents.savedVideoSession, savedSession)
        XCTAssertEqual(fixture.documents.videoEditorController?.documentSession.trimStartSeconds, 2)
        XCTAssertTrue(fixture.documents.hasUnsavedChanges)
        XCTAssertEqual(try SSSVideoDocumentPackage.load(from: destination).session, savedSession)
    }

    func testVideoSaveAndSaveAsPreserveUndoReviewStateAndRebaseSourceMedia() async throws {
        let fixture = try SaveConsistencyFixture()
        defer { fixture.cleanUp() }
        var recording = try await VideoTestMedia.make(in: fixture.root, duration: 6, width: 64, height: 48)
        let temporarySource = TemporaryVideoMediaManager.recordingOutputURL()
        try FileManager.default.copyItem(at: recording.sourceURL, to: temporarySource)
        defer { try? FileManager.default.removeItem(at: temporarySource) }
        recording.sourceURL = temporarySource
        let controller = VideoEditorController(recording: recording)
        fixture.documents.installVideoController(controller, documentURL: nil, savedSession: nil)
        controller.addZoom()
        let selectedZoom = controller.selectedZoomID
        controller.isPolishing = true
        controller.inspectorSection = .zooms
        let manager = UndoManager()
        manager.groupsByEvent = false
        controller.undoManager = manager
        manager.beginUndoGrouping()
        controller.updateTrimStart(1)
        manager.endUndoGrouping()
        controller.scrub(to: 4)

        var previousSavedMedia: URL?
        for name in ["First", "Save As"] {
            await waitUntil(timeoutNanoseconds: 5_000_000_000) {
                !controller.isPreparingPreview && controller.posterImage != nil
            }
            XCTAssertNotNil(controller.posterImage, controller.previewError ?? "The media fixture must prepare a poster before Save")
            let destination = fixture.root.appendingPathComponent("\(name).sssvideo")
            let savedSession = controller.documentSession

            let saved = await fixture.documents.saveVideoDocument(controller, to: destination)

            XCTAssertTrue(saved, fixture.model.lifecycle.errorMessage ?? "Save returned false")
            XCTAssertTrue(fixture.documents.videoEditorController === controller)
            XCTAssertTrue(controller.undoManager === manager)
            XCTAssertTrue(manager.canUndo)
            XCTAssertEqual(controller.selectedZoomID, selectedZoom)
            XCTAssertEqual(controller.inspectorSection, .zooms)
            XCTAssertTrue(controller.isPolishing)
            XCTAssertEqual(controller.currentTimeSeconds, 4, accuracy: 0.001)
            let savedMedia = destination.appendingPathComponent(SSSVideoDocumentPackage.mediaFilename)
            XCTAssertEqual(controller.recording.sourceURL, savedMedia)
            XCTAssertEqual((controller.player.currentItem?.asset as? AVURLAsset)?.url, savedMedia)
            XCTAssertTrue(FileManager.default.fileExists(atPath: savedMedia.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: temporarySource.path))
            if let previousSavedMedia {
                XCTAssertTrue(FileManager.default.fileExists(atPath: previousSavedMedia.path), "Save As preserves the earlier editable file")
            }
            XCTAssertEqual(fixture.documents.savedVideoSession, savedSession)
            manager.undo()
            XCTAssertEqual(controller.session.trimStartSeconds, 0)
            XCTAssertTrue(fixture.documents.hasUnsavedChanges)
            manager.redo()
            XCTAssertEqual(controller.session.trimStartSeconds, 1)
            XCTAssertFalse(fixture.documents.hasUnsavedChanges)
            previousSavedMedia = savedMedia
        }
    }
}

@MainActor
final class GuideExitConsistencyTests: XCTestCase {
    func testUnsavedGuideExitRequiresCancelOrExplicitDiscard() async throws {
        for isPrivate in [false, true] {
            for discards in [false, true] {
                let fixture = try SaveConsistencyFixture()
                defer { fixture.cleanUp() }
                let controller = fixture.installGuide(isPrivate: isPrivate)
                let exit = Task { await fixture.documents.prepareForApplicationExit() }
                await waitUntil { fixture.documents.isShowingUnsavedChangesPrompt }
                XCTAssertTrue(fixture.documents.isShowingUnsavedChangesPrompt)

                if discards { fixture.documents.discardChangesAndContinue() }
                else { fixture.documents.cancelPendingEditorAction() }

                let prepared = await exit.value
                XCTAssertEqual(prepared, discards)
                XCTAssertEqual(fixture.documents.guideEditorController === controller, !discards)
                XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryURL(for: controller).path))
            }
        }
    }

    func testUnsavedGuideExitWaitsForExplicitSaveOrCancelledDestination() async throws {
        for isPrivate in [false, true] {
            for cancelsDestination in [false, true] {
                let fixture = try SaveConsistencyFixture()
                defer { fixture.cleanUp() }
                let controller = fixture.installGuide(isPrivate: isPrivate)
                let destination = fixture.root.appendingPathComponent("Explicit.sssguide")
                fixture.panels.saveURL = cancelsDestination ? nil : destination
                let exit = Task { await fixture.documents.prepareForApplicationExit() }
                await waitUntil { fixture.documents.isShowingUnsavedChangesPrompt }
                XCTAssertTrue(fixture.documents.isShowingUnsavedChangesPrompt)

                fixture.documents.confirmSaveBeforeContinuing()

                let prepared = await exit.value
                XCTAssertEqual(prepared, !cancelsDestination)
                XCTAssertTrue(fixture.documents.guideEditorController === controller)
                XCTAssertEqual(fixture.documents.hasUnsavedChanges, cancelsDestination)
                XCTAssertEqual(fixture.panels.saveCount, 1)
                XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryURL(for: controller).path))
                if !cancelsDestination {
                    XCTAssertEqual(try SSSGuideDocumentPackage.load(from: destination).project.isPrivate, isPrivate)
                }
            }
        }
    }

    func testSavedGuideExitFlushesPendingAutosaveBeforeQuitting() async throws {
        let fixture = try SaveConsistencyFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.installGuide()
        let destination = fixture.root.appendingPathComponent("Saved.sssguide")
        let initiallySaved = await fixture.documents.saveGuideDocument(controller, to: destination)
        XCTAssertTrue(initiallySaved)
        controller.updateCaption(stepID: controller.project.steps[0].id, caption: "Latest pending edit")
        fixture.documents.scheduleGuideAutosave()
        XCTAssertNotNil(fixture.documents.pendingGuideAutosaveTask)

        let prepared = await fixture.documents.prepareForApplicationExit()

        XCTAssertTrue(prepared)
        XCTAssertFalse(fixture.documents.hasUnsavedChanges)
        XCTAssertNil(fixture.documents.pendingGuideAutosaveTask)
        XCTAssertFalse(fixture.documents.isShowingUnsavedChangesPrompt)
        XCTAssertEqual(try SSSGuideDocumentPackage.load(from: destination).project.steps[0].caption, "Latest pending edit")
    }

    func testSavedPrivateGuideExitKeepsItsExplicitUnsavedDecision() async throws {
        let fixture = try SaveConsistencyFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.installGuide(isPrivate: true)
        let destination = fixture.root.appendingPathComponent("Private.sssguide")
        let saved = await fixture.documents.saveGuideDocument(controller, to: destination)
        XCTAssertTrue(saved)
        controller.updateCaption(stepID: controller.project.steps[0].id, caption: "Private later edit")
        fixture.documents.scheduleGuideAutosave()

        let exit = Task { await fixture.documents.prepareForApplicationExit() }
        await waitUntil { fixture.documents.isShowingUnsavedChangesPrompt }
        fixture.documents.cancelPendingEditorAction()

        let prepared = await exit.value
        XCTAssertFalse(prepared)
        XCTAssertTrue(fixture.documents.guideEditorController === controller)
        XCTAssertTrue(fixture.documents.hasUnsavedChanges)
        XCTAssertEqual(try SSSGuideDocumentPackage.load(from: destination).project.steps[0].caption, "Step 1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryURL(for: controller).path))
    }

    func testGuideExitSaveFailureLeavesTheDirtyGuideOpen() async throws {
        let fixture = try SaveConsistencyFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.installGuide()
        let destination = fixture.root.appendingPathComponent("Saved.sssguide")
        let saved = await fixture.documents.saveGuideDocument(controller, to: destination)
        XCTAssertTrue(saved)
        controller.updateCaption(stepID: controller.project.steps[0].id, caption: "Must survive failed exit save")
        fixture.documents.guideDocumentWriter = FailingGuideExitWriter()

        let prepared = await fixture.documents.prepareForApplicationExit()

        XCTAssertFalse(prepared)
        XCTAssertTrue(fixture.documents.guideEditorController === controller)
        XCTAssertTrue(fixture.documents.hasUnsavedChanges)
        XCTAssertNotNil(controller.saveFailure)
        XCTAssertEqual(try SSSGuideDocumentPackage.load(from: destination).project.steps[0].caption, "Step 1")
    }

    func testGuideExitKeepsEditsMadeDuringItsSaveOpen() async throws {
        let fixture = try SaveConsistencyFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.installGuide()
        let destination = fixture.root.appendingPathComponent("Saved.sssguide")
        let saved = await fixture.documents.saveGuideDocument(controller, to: destination)
        XCTAssertTrue(saved)
        controller.updateCaption(stepID: controller.project.steps[0].id, caption: "At exit request")
        let writer = DelayedGuideExitWriter()
        fixture.documents.guideDocumentWriter = writer
        let exit = Task { await fixture.documents.prepareForApplicationExit() }
        await writer.barrier.waitForRequest()
        controller.updateCaption(stepID: controller.project.steps[0].id, caption: "Edited while exiting")
        await writer.barrier.resume(returning: true)

        let prepared = await exit.value
        XCTAssertFalse(prepared)
        XCTAssertTrue(fixture.documents.guideEditorController === controller)
        XCTAssertTrue(fixture.documents.hasUnsavedChanges)
        XCTAssertEqual(controller.project.steps[0].caption, "Edited while exiting")
        XCTAssertEqual(try SSSGuideDocumentPackage.load(from: destination).project.steps[0].caption, "At exit request")
    }

    func testGuideExitWaitsForAnActiveSaveAndRejectsConcurrentEdits() async throws {
        for editsDuringExit in [false, true] {
            let fixture = try SaveConsistencyFixture()
            defer { fixture.cleanUp() }
            let controller = fixture.installGuide()
            let destination = fixture.root.appendingPathComponent("Saved.sssguide")
            let saved = await fixture.documents.saveGuideDocument(controller, to: destination)
            XCTAssertTrue(saved)
            controller.updateCaption(stepID: controller.project.steps[0].id, caption: "Active save")
            let writer = DelayedGuideExitWriter()
            fixture.documents.guideDocumentWriter = writer
            let saving = Task { await fixture.documents.persistGuide(controller, to: destination) }
            await writer.barrier.waitForRequest()
            let exit = Task { await fixture.documents.prepareForApplicationExit() }
            await waitUntil { !fixture.documents.guideSaveCompletionWaiters.isEmpty }
            XCTAssertFalse(fixture.documents.guideSaveCompletionWaiters.isEmpty)
            if editsDuringExit {
                controller.updateCaption(stepID: controller.project.steps[0].id, caption: "Changed during active save")
            }
            await writer.barrier.resume(returning: true)

            let didSave = await saving.value
            let prepared = await exit.value
            XCTAssertTrue(didSave)
            XCTAssertEqual(prepared, !editsDuringExit)
            XCTAssertEqual(fixture.documents.hasUnsavedChanges, editsDuringExit)
            XCTAssertTrue(fixture.documents.guideSaveCompletionWaiters.isEmpty)
            XCTAssertEqual(try SSSGuideDocumentPackage.load(from: destination).project.steps[0].caption, "Active save")
        }
    }

    private func recoveryURL(for controller: GuideEditorController) -> URL {
        GuideRecoveryStore().rootURL.appendingPathComponent(controller.project.id.uuidString.lowercased()).appendingPathExtension("sssguide")
    }
}

private struct FailingGuideExitWriter: GuideDocumentWriting {
    func save(_ document: EditableGuideDocument, to url: URL, files: any FileSystemServicing) async throws -> EditableGuideDocument {
        throw CocoaError(.fileWriteOutOfSpace)
    }
}

private actor DelayedGuideExitWriter: GuideDocumentWriting {
    let barrier = DeferredBoolVerifier()
    private let writer = GuideDocumentWriter()
    func save(_ document: EditableGuideDocument, to url: URL, files: any FileSystemServicing) async throws -> EditableGuideDocument {
        _ = await barrier.value()
        return try await writer.save(document, to: url, files: files)
    }
}

@MainActor
private final class SaveConsistencyPanels: DocumentPanelPresenting {
    var saveURL: URL?
    var saveCount = 0
    func selectDocumentToOpen() -> URL? { nil }
    func selectImageToImport() -> URL? { nil }
    func selectPresentationScenesRoot(initialDirectory: URL) -> URL? { nil }
    func selectSaveDestination(suggestedFilename: String, contentType: UTType) async -> URL? {
        saveCount += 1
        return saveURL
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

    func performDocumentWork<Result>(message: String, _ operation: nonisolated(nonsending) () async throws -> Result) async rethrows -> Result {
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
    let panels = SaveConsistencyPanels()

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
            panels: panels, windowPresenter: TestDocumentWindowPresenter(), pasteboardImporter: ports.pasteboardImporter,
            floatingReferenceCoordinator: ports.floatingReferenceCoordinator,
            historyPreviewCoordinator: ports.historyPreviewCoordinator, textRecognitionCoordinator: ports.textRecognitionCoordinator),
            recoveryStore: recovery, videoRecoveryStore: VideoRecoveryStore(rootURL: root.appendingPathComponent("VideoRecovery")),
            incompatibleDocumentCoordinator: model.documents.incompatibleDocumentCoordinator,
            preferenceStore: model.documents.preferenceStore, pendingRecoverySession: nil,
            allCaptureHistoryEntries: [], recentSnipEntries: [], recycleBinEntries: [])
    }

    func installScreenshot(documentURL: URL? = nil, isPrivate: Bool = false) -> EditorController {
        let controller = EditorController(capture: makeCapturedScreenshot(), defaults: defaults,
            capabilities: testCapabilities, isPrivateDocument: isPrivate)
        documents.installEditorController(controller, documentURL: documentURL,
            savedSession: documentURL == nil ? nil : controller.documentSession, shouldCreateRecoverySession: false)
        return controller
    }

    func installGuide(isPrivate: Bool = false) -> GuideEditorController {
        let image = makeCoordinateImage(width: 32, height: 24)
        var project = GuideProject(source: .displays(.current), isPrivate: isPrivate)
        let step = GuideStep(sequence: 1, eventKind: .manual, caption: "Step 1",
            session: GuideStepSession(sourceCoordinateRect: CGRect(x: 0, y: 0, width: 32, height: 24),
                                      sourcePixelSize: CGSize(width: 32, height: 24)))
        project.steps = [step]
        let controller = GuideEditorController(document: EditableGuideDocument(project: project,
            stepImages: [step.id: image], previewImage: nil, logoImage: nil, mediaSegmentURLs: [:]))
        documents.installGuideController(controller, documentURL: nil, savedProject: nil)
        return controller
    }

    func makeHistoryEntry() throws -> DocumentHistoryEntry {
        let store = documents.recoveryStore
        let sessionID = try store.createSession(title: "History target", sourceDocumentURL: nil)
        let document = makeEditableDocument()
        try store.saveCheckpoint(sessionID: sessionID, title: "History target", sourceDocumentURL: nil,
            label: "Capture", document: document, previewImage: document.capture.image,
            pendingRecovery: false, hasUnsavedChanges: true, includeUIMapSearchText: false)
        return try XCTUnwrap(store.historyEntries(for: sessionID).first)
    }

    func blockCurrentRecoverySession() throws {
        let sessionID = UUID()
        let sessions = documents.recoveryStore.archiveURL.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data("blocked session directory".utf8).write(to: sessions.appendingPathComponent(sessionID.uuidString))
        documents.currentRecoverySessionID = sessionID
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
