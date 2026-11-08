import AppKit
import Combine
import XCTest
@testable import SnipSnipSnip

@MainActor
final class PrivateImageClipboardTests: XCTestCase {
    func testPrivateEditorCopyStaysExcludedWhenMonitoringStartsLater() async throws {
        let fixture = PrivateClipboardFixture()
        defer { fixture.cleanUp() }
        let monitor = ClipboardMonitor(store: fixture.history, pasteboard: fixture.pasteboard,
            workspace: TestWorkspaceService(), snapshotResolver: { captured in captured.pngData.map { .imageData($0) } })
        defer { monitor.stop() }
        let controller = fixture.installScreenshot(isPrivate: true)
        var copied: Bool?
        controller.copyAnnotatedImage(appearance: .plain, pasteboard: fixture.pasteboard) { copied = $0 }
        await waitUntil { copied != nil }
        XCTAssertEqual(copied, true)
        XCTAssertTrue(fixture.pasteboard.typeNames.contains(ClipboardPasteboardReader.concealedTypeName))
        let reads = fixture.pasteboard.contentReadCount
        var preferences = ClipboardPreferences.default
        preferences.isEnabled = true

        monitor.start(preferences: preferences)
        XCTAssertEqual(fixture.pasteboard.contentReadCount, reads, "A private copy must be filtered before any payload read")
        XCTAssertTrue(fixture.history.items.isEmpty)

        try ImageExporter.copyToClipboard(makeCoordinateImage(width: 8, height: 6), pasteboard: fixture.pasteboard)
        XCTAssertFalse(fixture.pasteboard.typeNames.contains(ClipboardPasteboardReader.concealedTypeName))
        monitor.update(preferences: preferences)
        await waitUntil { !fixture.history.items.isEmpty }
        XCTAssertEqual(fixture.history.items.count, 1, "Ordinary copies remain available to history")
    }

    func testPrivatePNGAndMarkerUseOnePreparedItemAndWriteFailureIsReported() throws {
        let pasteboard = TestPasteboardService()
        let png = try ImageExporter.pngData(for: makeCoordinateImage(width: 8, height: 6))
        let initialChangeCount = pasteboard.changeCount
        try ImageExporter.copyPNGDataToClipboard(png, isPrivate: true, pasteboard: pasteboard)
        XCTAssertEqual(pasteboard.changeCount, initialChangeCount + 2, "Clear then publish one item containing both representations")
        XCTAssertEqual(pasteboard.data(forType: .png), png)
        XCTAssertEqual(pasteboard.data(forType: .init(ClipboardPasteboardReader.concealedTypeName)), Data())
        pasteboard.failNextSnapshotWrite()
        XCTAssertThrowsError(try ImageExporter.copyPNGDataToClipboard(png, isPrivate: true, pasteboard: pasteboard)) {
            guard case ImageExportError.clipboardUnavailable = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertFalse(pasteboard.typeNames.contains(NSPasteboard.PasteboardType.png.rawValue))
    }

    func testPrivacyChangesSupersedeAnInFlightCopyWithTheSamePixels() async {
        let activity = ScreenshotOutputActivity()
        let gate = DeferredBoolVerifier()
        var privateKey = ScreenshotCopyRequestKey(contentRevision: 1, appearance: .plain, outputSize: .original)
        var deliveries: [Bool] = []
        activity.copy(key: privateKey, render: { _ = await gate.value(); return Data() },
            deliver: { _ in deliveries.append(false) }, didSucceed: {}, didFail: { _ in }, completion: nil)
        await gate.waitForRequest()
        privateKey.isPrivate = true
        activity.copy(key: privateKey, render: { Data() },
            deliver: { _ in deliveries.append(true) }, didSucceed: {}, didFail: { _ in }, completion: nil)
        await gate.resume(returning: true)
        await waitUntil { !activity.isCopying }
        XCTAssertEqual(deliveries, [true])
    }

    func testAutomationAndPresetPrivateCopiesCarryConcealment() async throws {
        for usesPreset in [false, true] {
            let fixture = PrivateClipboardFixture()
            defer { fixture.cleanUp() }
            if usesPreset {
                var context = CaptureCompletionContext.standalone
                context.workflowPreset = CapturePreset(name: "Private Copy", target: .fullscreen,
                    options: CaptureRunOptions(), outcome: .copyToClipboard)
                context.workflowPresetRunID = UUID()
                try fixture.model.capture.completeCapture(makeCapturedScreenshot(), request: .fullscreen,
                    isPrivateCapture: true, shouldAttemptUIMapCapture: false, completionContext: context)
                await waitUntil { fixture.pasteboard.typeNames.contains(NSPasteboard.PasteboardType.png.rawValue) }
            } else {
                _ = fixture.installScreenshot(isPrivate: true)
                let output = AutomationOutputService(port: fixture.model.automation, pasteboard: fixture.pasteboard)
                let results = try await output.write(.copyRenderedImage)
                XCTAssertEqual(results.map(\.kind), [.copiedClipboard])
            }
            XCTAssertNotNil(fixture.pasteboard.data(forType: .png))
            XCTAssertTrue(fixture.pasteboard.typeNames.contains(ClipboardPasteboardReader.concealedTypeName))
            XCTAssertTrue(fixture.history.items.isEmpty)
        }
    }

    func testConcealedCompositionAndOverlayPasteBecomePrivateBeforePublishingPixels() async throws {
        for overlays in [false, true] {
            let fixture = PrivateClipboardFixture()
            defer { fixture.cleanUp() }
            let controller = fixture.installScreenshot()
            let pasteboard = try imagePasteboard(marker: ClipboardPasteboardReader.concealedTypeName)
            defer { pasteboard.releaseGlobally() }
            var privacyAtInsertion: [Bool] = []
            let observer = controller.$snapshot.dropFirst().sink { snapshot in
                if !snapshot.annotations.isEmpty || (snapshot.composition?.items.count ?? 0) > 1 {
                    privacyAtInsertion.append(controller.isPrivateDocument)
                }
            }
            defer { observer.cancel() }

            if overlays { XCTAssertTrue(controller.addImageOverlayFromPasteboard(pasteboard: pasteboard)) }
            else { fixture.model.documents.pasteImageIntoCurrentComposition(pasteboard: pasteboard) }

            XCTAssertTrue(controller.isPrivateDocument)
            XCTAssertFalse(privacyAtInsertion.isEmpty)
            XCTAssertTrue(privacyAtInsertion.allSatisfy { $0 })
            XCTAssertNil(fixture.model.documents.currentRecoverySessionID)
            XCTAssertNil(fixture.model.documents.pendingAutosaveTask)
            XCTAssertTrue(fixture.model.documents.recoveryStore.allHistoryEntries().isEmpty)
            controller.undo()
            XCTAssertTrue(controller.isPrivateDocument, "Removing pasted private pixels never removes privacy provenance")
            await fixture.model.documents.prepareForArchiveClear()
        }
    }

    func testOnlyConcealedImagesTaintNewDocumentsAndFailedPasteDoesNotTaint() throws {
        for marker in [ClipboardPasteboardReader.concealedTypeName, "org.nspasteboard.TransientType", ClipboardPasteboardReader.autoGeneratedTypeName] {
            let fixture = PrivateClipboardFixture()
            defer { fixture.cleanUp() }
            let pasteboard = try imagePasteboard(marker: marker)
            defer { pasteboard.releaseGlobally() }
            let created = fixture.model.documents.createDocumentFromClipboard(completionRole: .standalone,
                options: options, pasteboard: pasteboard)
            XCTAssertTrue(created)
            let controller = try XCTUnwrap(fixture.model.documents.editorController)
            XCTAssertEqual(controller.isPrivateDocument, marker == ClipboardPasteboardReader.concealedTypeName)
            if controller.isPrivateDocument { XCTAssertNil(fixture.model.documents.currentRecoverySessionID) }
        }
        let fixture = PrivateClipboardFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.installScreenshot()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setData(Data(), forType: .init(ClipboardPasteboardReader.concealedTypeName))
        pasteboard.setString("No image", forType: .string)
        XCTAssertFalse(controller.addImageOverlayFromPasteboard(pasteboard: pasteboard))
        fixture.model.documents.pasteImageIntoCurrentComposition(pasteboard: pasteboard)
        XCTAssertFalse(fixture.model.documents.createDocumentFromClipboard(completionRole: .standalone,
            options: options, pasteboard: pasteboard))
        XCTAssertFalse(controller.isPrivateDocument)
        XCTAssertTrue(fixture.model.documents.editorController === controller)
    }

    func testNamedConcealedImportPreservesCancelledEditorAndTaintsOnlyAcceptedDocument() async throws {
        let fixture = PrivateClipboardFixture()
        defer { fixture.cleanUp() }
        let original = fixture.installScreenshot()
        let pasteboard = try imagePasteboard(marker: ClipboardPasteboardReader.concealedTypeName)
        defer { pasteboard.releaseGlobally() }
        fixture.model.documents.importImageFromPasteboard(named: pasteboard.name.rawValue, sourceName: "Private shared image")
        XCTAssertTrue(fixture.model.documents.isShowingUnsavedChangesPrompt)
        fixture.model.documents.cancelPendingEditorAction()
        XCTAssertTrue(fixture.model.documents.editorController === original)
        XCTAssertFalse(original.isPrivateDocument)
        XCTAssertNotNil(pasteboard.data(forType: .png))

        fixture.model.documents.importImageFromPasteboard(named: pasteboard.name.rawValue, sourceName: "Private shared image")
        fixture.model.documents.discardChangesAndContinue()
        await waitUntil {
            guard let current = fixture.model.documents.editorController else { return false }
            return current !== original
        }
        let imported = try XCTUnwrap(fixture.model.documents.editorController)
        XCTAssertTrue(imported.isPrivateDocument)
        XCTAssertNil(fixture.model.documents.currentRecoverySessionID)
        XCTAssertNil(pasteboard.data(forType: .png))
    }

    private var options: CaptureOneShotOptions {
        CaptureOneShotOptions(captureDelay: .immediate, includesCursor: false, privateCapture: false, windowUIMapEnabled: false)
    }

    private func imagePasteboard(marker: String) throws -> NSPasteboard {
        let pasteboard = NSPasteboard.withUniqueName()
        let item = NSPasteboardItem()
        item.setData(try ImageExporter.pngData(for: makeCoordinateImage(width: 12, height: 8)), forType: .png)
        item.setData(Data(), forType: .init(marker))
        XCTAssertTrue(pasteboard.writeObjects([item]))
        return pasteboard
    }
}

@MainActor
private struct PrivateClipboardFixture {
    let name: String
    let root: URL
    let defaults: UserDefaults
    let pasteboard = TestPasteboardService()
    let history: ClipboardHistoryStore
    let model: AppModel

    init() {
        name = "PrivateImageClipboardTests.\(UUID())"
        root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defaults = makeDefaults(named: name)
        history = ClipboardHistoryStore(baseURL: root.appendingPathComponent("Clipboard"), keyProvider: TestClipboardEncryptionKeyProvider())
        model = retainForTestLifetime(AppModel(defaults: defaults,
            environment: makePasteboardTestEnvironment(defaults: defaults, pasteboard: pasteboard),
            recoveryStore: DocumentRecoveryStore(baseURL: root.appendingPathComponent("Recovery")),
            clipboardHistoryStore: history, shouldCheckCompatibilityOnLaunch: false, shouldStartArchiveMaintenance: false))
    }

    func installScreenshot(isPrivate: Bool = false) -> EditorController {
        let controller = EditorController(capture: makeCapturedScreenshot(), defaults: defaults,
            capabilities: testCapabilities, isPrivateDocument: isPrivate)
        model.documents.installEditorController(controller, documentURL: nil, savedSession: nil)
        return controller
    }

    func cleanUp() {
        model.clipboard.monitor.stop()
        model.documents.pendingRecoveryWriteTasks.values.forEach { $0.cancel() }
        model.documents.currentRecoverySessionID = nil
        model.documents.discardCurrentDocument()
        model.documents.resetEditorSessionState()
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: root)
    }
}
