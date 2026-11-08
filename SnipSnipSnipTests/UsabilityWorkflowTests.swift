import AppKit
import SwiftUI
import XCTest
@testable import SnipSnipSnip

@MainActor
final class GuideUsabilityTests: XCTestCase {
    func testShareRequiresCurrentSessionAndContentEvenBeforeObserversRun() throws {
        let fixture = try UsabilityWorkflowFixture()
        defer { fixture.cleanUp() }
        let documents = fixture.model.documents
        let first = fixture.installGuide()
        let exportedVersion = first.contentVersion
        let output = fixture.root.appendingPathComponent("guide.pdf")
        XCTAssertTrue(documents.acceptGuideExport([output], version: exportedVersion))
        first.selection = [first.project.steps[4].id]
        first.searchQuery = "Step"
        XCTAssertEqual(documents.lastGuideExportURLs, [output], "Browsing does not change exported content")

        first.updateCaption(stepID: first.project.steps[4].id, caption: "Revised instruction")
        XCTAssertTrue(documents.lastGuideExportURLs.isEmpty, "Share must reject old output synchronously")
        XCTAssertFalse(documents.acceptGuideExport([output], version: exportedVersion), "Late completion must reject an older revision")
        first.undo()
        XCTAssertTrue(documents.lastGuideExportURLs.isEmpty)

        let currentVersion = first.contentVersion
        XCTAssertTrue(documents.acceptGuideExport([output], version: currentVersion))
        // Reopening the same project is still a different editing session.
        let reopened = GuideEditorController(document: first.editableDocument())
        documents.installGuideController(reopened, documentURL: nil, savedProject: nil)
        XCTAssertTrue(documents.lastGuideExportURLs.isEmpty)
        XCTAssertFalse(documents.acceptGuideExport([output], version: currentVersion))
        documents.discardCurrentDocument()
        XCTAssertFalse(documents.acceptGuideExport([output], version: reopened.contentVersion))
    }

    func testAdvancedEditsAndLogoReplacementInvalidateExport() throws {
        let fixture = try UsabilityWorkflowFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.installGuide()
        let documents = fixture.model.documents
        let output = fixture.root.appendingPathComponent("guide.pdf")
        XCTAssertTrue(documents.acceptGuideExport([output], version: controller.contentVersion))
        controller.replaceLogoWithoutCommand(makeCoordinateImage(width: 8, height: 8))
        XCTAssertTrue(documents.lastGuideExportURLs.isEmpty)
        XCTAssertTrue(documents.acceptGuideExport([output], version: controller.contentVersion))
        controller.replaceLogoWithoutCommand(makeCoordinateImage(width: 16, height: 16))
        XCTAssertTrue(documents.lastGuideExportURLs.isEmpty, "Replacing the same logo asset path changes output")
        XCTAssertTrue(documents.acceptGuideExport([output], version: controller.contentVersion))
        controller.beginAdvancedEdit(capabilities: testCapabilities)
        controller.advancedEditorController?.updateCropRect(CGRect(x: 1, y: 1, width: 10, height: 10))
        controller.commitAdvancedEdit()
        XCTAssertTrue(documents.lastGuideExportURLs.isEmpty)
    }

    func testSaveAndSaveAsKeepSelectionSearchUndoAndRebaseMedia() async throws {
        let fixture = try UsabilityWorkflowFixture()
        defer { fixture.cleanUp() }
        let source = fixture.root.appendingPathComponent("source.mp4")
        try Data("source video".utf8).write(to: source)
        let controller = fixture.installGuide(mediaURL: source)
        let documents = fixture.model.documents
        let lastID = controller.project.steps[4].id
        let selected: Set<UUID> = [controller.project.steps[3].id, lastID]
        controller.selection = selected
        controller.searchQuery = "Step"
        controller.updateCaption(stepID: lastID, caption: "Revised Step 5")
        let firstURL = fixture.root.appendingPathComponent("First.sssguide")
        let firstSaved = await documents.saveGuideDocument(controller, to: firstURL)
        XCTAssertTrue(firstSaved)
        XCTAssertTrue(documents.guideEditorController === controller)
        XCTAssertFalse(documents.hasUnsavedChanges)
        XCTAssertEqual(controller.selection, selected)
        XCTAssertEqual(controller.searchQuery, "Step")
        XCTAssertTrue(controller.canUndo)
        try FileManager.default.removeItem(at: source)

        let secondURL = fixture.root.appendingPathComponent("Second.sssguide")
        let secondSaved = await documents.saveGuideDocument(controller, to: secondURL)
        XCTAssertTrue(secondSaved)
        let media = try XCTUnwrap(controller.mediaSegmentURLs.values.first)
        XCTAssertTrue(media.path.hasPrefix(secondURL.path + "/"))
        XCTAssertEqual(try Data(contentsOf: media), Data("source video".utf8))
        XCTAssertEqual(try SSSGuideDocumentPackage.load(from: secondURL).project.steps[4].caption, "Revised Step 5")
        controller.undo()
        XCTAssertEqual(controller.project.steps[4].caption, "Step 5")
        XCTAssertEqual(controller.selection, selected)
        XCTAssertEqual(controller.searchQuery, "Step")
        controller.redo()
        controller.updateCaption(stepID: lastID, caption: "After Save")
        controller.undo()
        XCTAssertEqual(controller.project.steps[4].caption, "Revised Step 5", "Typing after Save must not coalesce across the saved state")
    }

    func testSaveFailureStaysVisibleUntilSuccessfulRetryWithoutLosingEdits() async throws {
        let fixture = try UsabilityWorkflowFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.installGuide()
        let documents = fixture.model.documents
        controller.updateCaption(stepID: controller.project.steps[0].id, caption: "Keep this change")
        let obstruction = fixture.root.appendingPathComponent("not-a-directory")
        try Data().write(to: obstruction)
        let failed = await documents.saveGuideDocument(controller, to: obstruction.appendingPathComponent("Guide.sssguide"))
        XCTAssertFalse(failed)
        XCTAssertNotNil(controller.saveFailure)
        XCTAssertTrue(documents.hasUnsavedChanges)
        XCTAssertTrue(documents.guideEditorController === controller)
        controller.selection = [controller.project.steps[4].id]
        controller.updateCaption(stepID: controller.project.steps[4].id, caption: "Another change")
        documents.scheduleGuideAutosave()
        XCTAssertNil(documents.pendingGuideAutosaveTask, "A failure should not enter an automatic retry loop")
        XCTAssertNotNil(controller.saveFailure)
        let destination = fixture.root.appendingPathComponent("Recovered.sssguide")
        let saved = await documents.saveGuideDocument(controller, to: destination)
        XCTAssertTrue(saved)
        XCTAssertNil(controller.saveFailure)
        XCTAssertTrue(controller.canUndo)
        XCTAssertFalse(documents.hasUnsavedChanges)
        let loaded = try SSSGuideDocumentPackage.load(from: destination)
        XCTAssertEqual(loaded.project.steps[0].caption, "Keep this change")
        XCTAssertEqual(loaded.project.steps[4].caption, "Another change")
    }

    func testEditsDuringSaveStayDirtyAndKeepTheirUndoHistory() async throws {
        let fixture = try UsabilityWorkflowFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.installGuide()
        let documents = fixture.model.documents
        let writer = SuspendedGuideWriter()
        documents.guideDocumentWriter = writer
        let destination = fixture.root.appendingPathComponent("Guide.sssguide")
        let saving = Task { await documents.saveGuideDocument(controller, to: destination) }
        await waitUntil { await writer.gate.isWaiting }
        controller.updateCaption(stepID: controller.project.steps[4].id, caption: "Typed during Save")
        await writer.gate.open()
        let saved = await saving.value
        XCTAssertTrue(saved)
        XCTAssertEqual(controller.project.steps[4].caption, "Typed during Save")
        XCTAssertTrue(controller.canUndo)
        XCTAssertTrue(documents.hasUnsavedChanges)
        XCTAssertEqual(try SSSGuideDocumentPackage.load(from: destination).project.steps[4].caption, "Step 5")
        XCTAssertNotNil(documents.pendingGuideAutosaveTask, "The newer edits need a subsequent save")
    }

    func testSaveCompletionCannotReplaceAnotherGuide() async throws {
        let fixture = try UsabilityWorkflowFixture()
        defer { fixture.cleanUp() }
        let first = fixture.installGuide()
        let documents = fixture.model.documents
        let writer = SuspendedGuideWriter()
        documents.guideDocumentWriter = writer
        let saving = Task { await documents.saveGuideDocument(first, to: fixture.root.appendingPathComponent("First.sssguide")) }
        await waitUntil { await writer.gate.isWaiting }
        let second = fixture.installGuide()
        await writer.gate.open()
        let saved = await saving.value
        XCTAssertFalse(saved)
        XCTAssertTrue(documents.guideEditorController === second)
        XCTAssertNil(documents.currentDocumentURL)
        XCTAssertNil(second.saveFailure)
        XCTAssertFalse(first.isSaving)
    }

    func testFilteredReorderIsGuardedAndClearSearchRestoresUndoableReorder() throws {
        let fixture = try UsabilityWorkflowFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.installGuide()
        let order = controller.project.steps.map(\.id)
        controller.searchQuery = "5"
        controller.selection = [order[4]]
        controller.reorder(from: IndexSet(integer: 0), to: 2)
        controller.moveSelection(by: -1)
        XCTAssertEqual(controller.project.steps.map(\.id), order)
        XCTAssertFalse(controller.canUndo)
        controller.searchQuery = ""
        controller.reorder(from: IndexSet(integer: 4), to: 0)
        XCTAssertEqual(controller.project.steps.first?.id, order[4])
        controller.undo()
        XCTAssertEqual(controller.project.steps.map(\.id), order)
    }
}

@MainActor
final class ScreenshotCompletionTests: XCTestCase {
    func testBackToCaptureRetainsLatestEditableScreenshotInRecentSnips() async throws {
        let fixture = try UsabilityWorkflowFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.installScreenshot()
        controller.updateCropRect(CGRect(x: 3, y: 4, width: 30, height: 20))
        let session = controller.documentSession
        let documents = fixture.model.documents
        let returned = await documents.keepScreenshotAndReturnToCapture(controller)
        XCTAssertTrue(returned)
        XCTAssertNil(documents.editorController)
        XCTAssertFalse(documents.isShowingUnsavedChangesPrompt)
        let entry = try XCTUnwrap(documents.recoveryStore.pendingRecoveryEntries().first)
        XCTAssertTrue(entry.hasUnsavedChanges, "Returning does not pretend an editable document was saved")
        XCTAssertEqual(try documents.recoveryStore.restoreDocument(from: entry).session, session)
    }

    func testBackToCaptureAlsoRetainsASavedScreenshotWithoutMarkingItDirty() async throws {
        let fixture = try UsabilityWorkflowFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.installScreenshot()
        let documents = fixture.model.documents
        documents.currentDocumentURL = fixture.root.appendingPathComponent("Saved.sss")
        documents.savedEditorAutosaveState = AutosaveState(controller: controller, documentURL: documents.currentDocumentURL)
        documents.updateDocumentChangeTracking()
        XCTAssertFalse(documents.hasUnsavedChanges)
        let returned = await documents.keepScreenshotAndReturnToCapture(controller)
        XCTAssertTrue(returned)
        let entry = try XCTUnwrap(documents.recoveryStore.pendingRecoveryEntries().first)
        XCTAssertFalse(entry.hasUnsavedChanges)
    }

    func testPrivateScreenshotStillAsksForSaveDiscardOrCancel() throws {
        let fixture = try UsabilityWorkflowFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.installScreenshot(isPrivate: true)
        fixture.model.documents.returnToCapture()
        XCTAssertTrue(fixture.model.documents.isShowingUnsavedChangesPrompt)
        XCTAssertTrue(fixture.model.documents.editorController === controller)
        XCTAssertTrue(fixture.model.documents.recoveryStore.allHistoryEntries().isEmpty)
        fixture.model.documents.cancelPendingEditorAction()
        XCTAssertTrue(fixture.model.documents.editorController === controller)
    }

    func testFailedRetentionKeepsScreenshotOpen() async throws {
        let fixture = try UsabilityWorkflowFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.installScreenshot()
        // Make a valid session's storage unavailable after it has been opened.
        try FileManager.default.removeItem(at: fixture.recoveryRoot)
        try Data().write(to: fixture.recoveryRoot)
        let returned = await fixture.model.documents.keepScreenshotAndReturnToCapture(controller)
        XCTAssertFalse(returned)
        XCTAssertTrue(fixture.model.documents.editorController === controller)
        XCTAssertNotNil(fixture.model.lifecycle.errorMessage)
    }

    func testAnEditDuringRetentionKeepsNewerWorkOpen() async throws {
        let fixture = try UsabilityWorkflowFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.installScreenshot()
        let documents = fixture.model.documents
        let gate = UsabilityTestGate()
        documents.enqueueRecoveryOperation { await gate.wait() }
        let returning = Task { await documents.keepScreenshotAndReturnToCapture(controller) }
        await waitUntil { documents.pendingRecoveryWriteTasks.count == 2 }
        controller.updateCropRect(CGRect(x: 2, y: 2, width: 20, height: 20))
        await gate.open()
        let returned = await returning.value
        XCTAssertFalse(returned)
        XCTAssertTrue(documents.editorController === controller)
        XCTAssertEqual(controller.documentSession.currentSnapshot.cropRect, CGRect(x: 2, y: 2, width: 20, height: 20))
    }
}

@MainActor
final class UsabilityLayoutTests: XCTestCase {
    func testScreenshotExitAndOutputStayVisibleOnSmallWorkAreas() async throws {
        let fixture = try UsabilityWorkflowFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.installScreenshot()
        for width: CGFloat in [1024, 800] {
            for mode: EditorWorkspaceMode in [.edit, .presentation] {
                controller.workspaceMode = mode
                let view = NSHostingView(rootView: EditorCommandBar(
                    controller: controller, isInspectorPresented: .constant(false), onBack: {},
                    onFloatReference: { _ in }, onExportPNG: { _ in }, onExportJPEG: { _ in }, onExportPDF: { _ in },
                    onCopy: { _ in }, onShare: { _ in }, onShowLayers: {}, onShowUIMap: {},
                    dragOutPayloadProvider: { _ in nil }, onDiscard: {}))
                let window = HostedViewTestSupport.host(view, size: CGSize(width: width, height: 170))
                defer { window.close() }
                try await Task.sleep(for: .milliseconds(150))
                view.layoutSubtreeIfNeeded()
                let bounds = window.convertToScreen(view.convert(view.bounds, to: nil))
                for identifier in ["editor.backToCapture", "editor.output.copy.current", "editor.output.export.current", "editor.output.share.current"] {
                    let element = try XCTUnwrap(HostedViewTestSupport.find(identifier, in: view))
                    XCTAssertTrue(bounds.contains(element.accessibilityFrame()), "\(identifier) must remain visible at \(width) points in \(mode)")
                }
                add(try HostedViewTestSupport.attachment(of: view, name: "Screenshot commands \(width) \(mode)"))
            }
        }
    }

    func testGuideSaveFailureExposesBothRecoveryActions() async throws {
        let fixture = try UsabilityWorkflowFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.installGuide()
        controller.setSaveFailure("The destination is unavailable.")
        let view = NSHostingView(rootView: GuideEditorView(controller: controller, capabilities: testCapabilities,
            recentSnips: [], onAddRecentSnip: { _ in }, savedThemes: [], onSaveTheme: { _ in }, onSetDefaultBranding: { _, _ in }))
        let window = HostedViewTestSupport.host(view, size: CGSize(width: 1024, height: 530))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        view.layoutSubtreeIfNeeded()
        let bounds = window.convertToScreen(view.convert(view.bounds, to: nil))
        for identifier in ["guide.save.retry", "guide.saveAs"] {
            let element = try XCTUnwrap(HostedViewTestSupport.find(identifier, in: view))
            XCTAssertTrue(bounds.contains(element.accessibilityFrame()))
            XCTAssertTrue(element.isAccessibilityEnabled())
        }
        add(try HostedViewTestSupport.attachment(of: view, name: "Guide save failure 1024x530"))
    }
}

@MainActor
private struct UsabilityWorkflowFixture {
    let root: URL
    let recoveryRoot: URL
    let defaults: UserDefaults
    let suite: String
    let model: AppModel

    init() throws {
        suite = "UsabilityWorkflowTests.\(UUID().uuidString)"
        defaults = makeDefaults(named: suite)
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        recoveryRoot = root.appendingPathComponent("Recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let environment = AppEnvironment(defaults: defaults, permissions: TestCapturePermissionService())
        model = retainForTestLifetime(AppModel(defaults: defaults, environment: environment,
            recoveryStore: DocumentRecoveryStore(baseURL: recoveryRoot),
            shouldCheckCompatibilityOnLaunch: false, shouldStartArchiveMaintenance: false))
    }

    func installGuide(mediaURL: URL? = nil) -> GuideEditorController {
        let image = makeCoordinateImage(width: 32, height: 24)
        var project = GuideProject(source: .displays(.current))
        project.steps = (1...5).map { GuideStep(sequence: $0, eventKind: .manual, caption: "Step \($0)",
            session: GuideStepSession(sourceCoordinateRect: CGRect(x: 0, y: 0, width: 32, height: 24), sourcePixelSize: CGSize(width: 32, height: 24))) }
        var media: [UUID: URL] = [:]
        if let mediaURL {
            let segment = GuideTimelineSegment(asset: "source.mp4", startedAt: Date(), duration: 1,
                sourceCoordinateRect: CGRect(x: 0, y: 0, width: 32, height: 24))
            project.timeline.segments = [segment]
            media[segment.id] = mediaURL
        }
        let controller = GuideEditorController(document: EditableGuideDocument(project: project,
            stepImages: Dictionary(uniqueKeysWithValues: project.steps.map { ($0.id, image) }),
            previewImage: nil, logoImage: nil, mediaSegmentURLs: media))
        model.documents.installGuideController(controller, documentURL: nil, savedProject: nil)
        return controller
    }

    func installScreenshot(isPrivate: Bool = false) -> EditorController {
        let controller = EditorController(capture: makeCapturedScreenshot(), defaults: defaults,
            capabilities: testCapabilities, isPrivateDocument: isPrivate)
        model.documents.installEditorController(controller, documentURL: nil, savedSession: nil,
            shouldCreateRecoverySession: !isPrivate)
        return controller
    }

    func cleanUp() {
        model.documents.pendingGuideAutosaveTask?.cancel()
        model.documents.pendingAutosaveTask?.cancel()
        model.documents.pendingRecoveryRefreshTask?.cancel()
        model.documents.pendingRecoveryWriteTasks.values.forEach { $0.cancel() }
        model.documents.currentRecoverySessionID = nil
        model.documents.discardCurrentDocument()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

private actor UsabilityTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    var isWaiting: Bool { continuation != nil }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor SuspendedGuideWriter: GuideDocumentWriting {
    let gate = UsabilityTestGate()
    private let writer = GuideDocumentWriter()

    func save(_ document: EditableGuideDocument, to url: URL, files: any FileSystemServicing) async throws -> EditableGuideDocument {
        await gate.wait()
        return try await writer.save(document, to: url, files: files)
    }
}
