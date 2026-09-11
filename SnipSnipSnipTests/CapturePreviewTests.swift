import AppKit
import ImageIO
import SwiftUI
import XCTest
@testable import SnipSnipSnip

@MainActor
final class CapturePreviewTests: XCTestCase {
    func testOnlyOrdinaryInteractiveScreenshotsUsePreview() {
        XCTAssertTrue(eligible(result()))
        XCTAssertFalse(eligible(result(allowsPreview: false)))
        XCTAssertFalse(eligible(result(isPrivate: true)))
        XCTAssertFalse(eligible(result(kind: .connectedDevice)))
        XCTAssertFalse(eligible(result(role: .comparisonBefore)))
        XCTAssertFalse(eligible(result(role: .step)))
        XCTAssertFalse(eligible(result(role: .collectionItem)))
        XCTAssertFalse(eligible(result(), disposition: .appended))
        XCTAssertFalse(eligible(result(), disposition: .replaced))
        XCTAssertFalse(eligible(result(), disposition: .unattachedRecent))
        XCTAssertFalse(CapturePreviewPolicy.shouldPresent(result: result(), disposition: .newDocument, isEnabled: false))
    }

    func testPreviewAndManualCopyDefaultsRespectStoredChoices() {
        let name = "CapturePreviewTests.preferences.\(UUID())"
        let defaults = makeDefaults(named: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let editor = EditorPreferenceStore(storage: defaults)
        let clipboard = ClipboardPreferenceStore(storage: defaults)
        XCTAssertFalse(editor.loadShowsCapturePreview())
        XCTAssertFalse(clipboard.loadAutoCopyEnabled())
        editor.saveShowsCapturePreview(true)
        clipboard.saveAutoCopyEnabled(true)
        XCTAssertTrue(EditorPreferenceStore(storage: defaults).loadShowsCapturePreview())
        XCTAssertTrue(ClipboardPreferenceStore(storage: defaults).loadAutoCopyEnabled())
        editor.saveShowsCapturePreview(false)
        XCTAssertFalse(EditorPreferenceStore(storage: defaults).loadShowsCapturePreview())
    }

    func testRedactionDefaultsToSolidButKeepsStoredMode() {
        let name = "CapturePreviewTests.redaction.\(UUID())"
        let defaults = makeDefaults(named: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = EditorController(capture: makeCapturedScreenshot(), defaults: defaults, capabilities: testCapabilities)
        XCTAssertEqual(controller.currentRedactionMode, .solid)
        controller.updateRedactionMode(.pixelate)
        let restored = EditorController(capture: makeCapturedScreenshot(), defaults: defaults, capabilities: testCapabilities)
        XCTAssertEqual(restored.currentRedactionMode, .pixelate)
        restored.activateToolbarTool(.redact)
        XCTAssertEqual(restored.activeTool, .redact)
        XCTAssertEqual(restored.currentRedactionMode, .solid)
    }

    func testCopyWaitsForCompletionAndCanRetryFailure() {
        var pending: ((Bool) -> Void)?
        var requests = 0
        let model = CapturePreviewModel(autoCopyEnabled: false, copy: {
            requests += 1
            pending = $0
        }, edit: {}, export: {}, drag: { nil })
        model.copyScreenshot()
        XCTAssertTrue(model.isCopying)
        XCTAssertFalse(model.message.contains("Ready to paste"))
        model.copyScreenshot()
        XCTAssertEqual(requests, 1)
        pending?(false)
        XCTAssertFalse(model.isCopying)
        XCTAssertTrue(model.hasError)
        model.copyScreenshot()
        pending?(true)
        XCTAssertEqual(requests, 2)
        XCTAssertFalse(model.isCopying)
        XCTAssertFalse(model.hasError)
        XCTAssertTrue(model.message.contains("Ready to paste"))
    }

    func testCopyReportsPasteboardFailureAndPreservesEditableWork() async {
        let controller = EditorController(capture: makeCapturedScreenshot(), capabilities: testCapabilities)
        let pasteboard = TestPasteboardService()
        pasteboard.rejectsDataWrites = true
        let snapshot = controller.snapshot
        var completed: Bool?
        controller.copyAnnotatedImage(appearance: .plain, pasteboard: pasteboard) { completed = $0 }
        await waitUntil { completed != nil }
        XCTAssertEqual(completed, false)
        XCTAssertEqual(controller.snapshot, snapshot)
        XCTAssertNil(pasteboard.data(forType: .png))
        XCTAssertFalse(controller.notice?.message.contains("Ready to paste") == true)

        pasteboard.rejectsDataWrites = false
        completed = nil
        controller.copyAnnotatedImage(appearance: .plain, pasteboard: pasteboard) { completed = $0 }
        await waitUntil { completed != nil }
        XCTAssertEqual(completed, true)
        XCTAssertNotNil(pasteboard.data(forType: .png))
        XCTAssertTrue(controller.notice?.message.contains("Ready to paste") == true)
    }

    func testCopyAndDragDeliverFlattenedRedactionsWithoutSourcePixels() async throws {
        let capture = makeCapturedScreenshot()
        let redaction = Annotation.makeSolidRedaction(in: CGRect(x: 5, y: 5, width: 40, height: 30))
        let snapshot = makeEditorSnapshot(cropRect: CGRect(origin: .zero, size: capture.pixelSize), annotations: [redaction])
        let controller = EditorController(capture: capture,
            session: makeEditorDocumentSession(initialSnapshot: snapshot, currentSnapshot: snapshot), capabilities: testCapabilities)
        let pasteboard = TestPasteboardService()
        var completed: Bool?
        controller.copyAnnotatedImage(appearance: .plain, pasteboard: pasteboard) { completed = $0 }
        await waitUntil { completed != nil }
        XCTAssertEqual(completed, true)
        XCTAssertTrue(controller.notice?.message.contains("redactions applied") == true)
        XCTAssertEqual(pasteboard.typeNames, [NSPasteboard.PasteboardType.png.rawValue])
        let copiedData = try XCTUnwrap(pasteboard.data(forType: .png))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(copiedData as CFData, nil))
        let copied = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertNotEqual(normalizedRGBAPixels(copied), normalizedRGBAPixels(capture.image))
        let payload = try XCTUnwrap(controller.promisedImagePayload(appearance: .plain,
            requestedFormat: .png, filenameTemplate: .default))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("CapturePreviewTests-drag-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: destination) }
        try await payload.write(to: destination)
        let exportedSource = try XCTUnwrap(CGImageSourceCreateWithURL(destination as CFURL, nil))
        let exported = try XCTUnwrap(CGImageSourceCreateImageAtIndex(exportedSource, 0, nil))
        XCTAssertEqual(normalizedRGBAPixels(copied), normalizedRGBAPixels(exported))
        XCTAssertEqual(normalizedRGBAPixels(controller.editableDocument.capture.image), normalizedRGBAPixels(capture.image))
    }

    func testCommonMarkupCommandsRenderAtMinimumWindowWidth() throws {
        let controller = EditorController(capture: makeCapturedScreenshot(), capabilities: testCapabilities)
        controller.activateToolbarTool(.redact)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let bar = EditorCommandBar(controller: controller, isInspectorPresented: .constant(false),
                onBack: {}, onFloatReference: { _ in }, onExportPNG: { _ in },
                onExportJPEG: { _ in }, onExportPDF: { _ in }, onCopy: { _ in },
                onShare: { _ in }, onShowLayers: {}, onShowUIMap: {}, dragOutPayloadProvider: { _ in nil })
            let view = NSHostingView(rootView: bar)
            view.appearance = NSAppearance(named: appearance)
            view.frame = CGRect(x: 0, y: 0, width: 1240, height: 140)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
            attachment.name = "Common Markup - \(appearance.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testClosingPreviewRetainsDocumentAndPreparingImage() async throws {
        let controller = EditorController(capture: makeCapturedScreenshot(), capabilities: testCapabilities)
        let coordinator = CapturePreviewCoordinator()
        coordinator.presentsWindows = false
        coordinator.present(controller: controller, autoCopyEnabled: false,
                            copy: { $0(true) }, edit: {}, export: {}, drag: { nil })
        let model = try XCTUnwrap(coordinator.model)
        coordinator.close()
        XCTAssertTrue(coordinator.model === model)
        XCTAssertFalse(model.allowsWindowRestoration)
        await waitUntil { model.image != nil }
        XCTAssertEqual(model.image?.width, controller.capture.image.width)
        XCTAssertEqual(model.image?.height, controller.capture.image.height)
        coordinator.show()
        XCTAssertTrue(coordinator.model === model)
        XCTAssertTrue(model.allowsWindowRestoration)
        coordinator.clear()
        XCTAssertNil(coordinator.model)
        XCTAssertFalse(model.allowsWindowRestoration)
    }

    func testNewPreviewCannotReceivePreviousRenderingResult() async throws {
        let first = EditorController(capture: makeCapturedScreenshot(), capabilities: testCapabilities)
        let second = EditorController(capture: makeCapturedScreenshot(image: makeCoordinateImage(width: 90, height: 60)), capabilities: testCapabilities)
        let coordinator = CapturePreviewCoordinator()
        coordinator.presentsWindows = false
        for controller in [first, second] {
            coordinator.present(controller: controller, autoCopyEnabled: false,
                                copy: { $0(true) }, edit: {}, export: {}, drag: { nil })
        }
        await waitUntil { coordinator.model?.image != nil }
        XCTAssertEqual(coordinator.model?.image?.width, 90)
        coordinator.clear()
    }

    func testPreviewPlacementSupportsNegativeDisplayOrigins() {
        let frame = CGRect(x: -1920, y: 23, width: 1920, height: 1057)
        let origin = CapturePreviewCoordinator.origin(in: frame, panelSize: CGSize(width: 304, height: 310))
        XCTAssertEqual(origin, CGPoint(x: -1904, y: 39))
        XCTAssertTrue(frame.contains(CGRect(origin: origin, size: CGSize(width: 304, height: 310))))
    }

    func testCaptureOpensEditorByDefaultWithoutPreview() {
        let app = makeApp()
        XCTAssertFalse(app.documents.showsCapturePreview)
        let presentationCount = app.lifecycle.mainWindowPresentationRequest
        app.workflowCoordinator.handle(.captureCompleted(result()))
        XCTAssertNotNil(app.documents.editorController)
        XCTAssertNotNil(app.documents.currentRecoverySessionID)
        XCTAssertFalse(app.documents.hasCapturePreview)
        XCTAssertNil(app.documents.capturePreviewCoordinator.model)
        XCTAssertFalse(app.capture.shouldKeepAppWindowHiddenAfterCapture)
        XCTAssertGreaterThan(app.lifecycle.mainWindowPresentationRequest, presentationCount)
    }

    func testResetDocumentPreferencesTurnsPreviewOff() {
        let app = makeApp()
        app.documents.showsCapturePreview = true
        app.documents.resetDocumentPreferencesToDefaults()
        XCTAssertFalse(app.documents.showsCapturePreview)
        let presentationCount = app.lifecycle.mainWindowPresentationRequest
        app.workflowCoordinator.handle(.captureCompleted(result()))
        XCTAssertFalse(app.documents.hasCapturePreview)
        XCTAssertNil(app.documents.capturePreviewCoordinator.model)
        XCTAssertGreaterThan(app.lifecycle.mainWindowPresentationRequest, presentationCount)
    }

    func testOptedInCaptureInstallsRecoverableDocumentWithoutRequestingEditor() throws {
        let app = makeApp()
        app.documents.showsCapturePreview = true
        let presentationCount = app.lifecycle.mainWindowPresentationRequest
        app.workflowCoordinator.handle(.captureCompleted(result()))
        XCTAssertNotNil(app.documents.editorController)
        XCTAssertNotNil(app.documents.currentRecoverySessionID)
        XCTAssertTrue(app.documents.hasCapturePreview)
        XCTAssertTrue(app.capture.shouldKeepAppWindowHiddenAfterCapture)
        XCTAssertEqual(app.lifecycle.mainWindowPresentationRequest, presentationCount)
        let controller = try XCTUnwrap(app.documents.editorController)
        app.documents.capturePreviewCoordinator.close()
        app.documents.showCapturePreview()
        XCTAssertTrue(app.documents.editorController === controller)
        XCTAssertTrue(app.documents.hasCapturePreview)
        app.documents.capturePreviewCoordinator.model?.edit()
        XCTAssertFalse(app.documents.hasCapturePreview)
        XCTAssertNil(app.documents.capturePreviewCoordinator.model)
        XCTAssertGreaterThan(app.lifecycle.mainWindowPresentationRequest, presentationCount)
        XCTAssertTrue(app.documents.editorController === controller)
    }

    func testEditingInvalidatesOldPreviewAndReplacementCannotReuseItsActions() throws {
        let app = makeApp()
        app.documents.showsCapturePreview = true
        app.workflowCoordinator.handle(.captureCompleted(result()))
        let oldPreview = try XCTUnwrap(app.documents.capturePreviewCoordinator.model)
        let controller = try XCTUnwrap(app.documents.editorController)
        controller.execute(AddAnnotationCommand(annotation: .makeSolidRedaction(in: CGRect(x: 5, y: 5, width: 30, height: 25))))
        XCTAssertFalse(app.documents.hasCapturePreview)
        XCTAssertNil(app.documents.capturePreviewCoordinator.model)
        app.workflowCoordinator.handle(.captureCompleted(result()))
        let newController = app.documents.editorController
        oldPreview.edit()
        XCTAssertTrue(app.documents.hasCapturePreview)
        XCTAssertTrue(app.documents.editorController === newController)
        var staleCopySucceeded: Bool?
        oldPreview.copy { staleCopySucceeded = $0 }
        XCTAssertEqual(staleCopySucceeded, false)
        app.documents.capturePreviewCoordinator.clear()
    }

    func testPrivateAndPreviewOptOutStillRequestEditor() {
        for isPrivate in [false, true] {
            let app = makeApp()
            app.documents.showsCapturePreview = isPrivate
            let count = app.lifecycle.mainWindowPresentationRequest
            app.workflowCoordinator.handle(.captureCompleted(result(isPrivate: isPrivate)))
            XCTAssertFalse(app.documents.hasCapturePreview)
            XCTAssertNil(app.documents.capturePreviewCoordinator.model)
            XCTAssertGreaterThan(app.lifecycle.mainWindowPresentationRequest, count)
            if isPrivate {
                XCTAssertNil(app.documents.currentRecoverySessionID)
                app.clipboard.autoCopyEnabled = true
                XCTAssertNil(app.documents.pendingAutoCopyTask)
                XCTAssertNil(app.documents.editorController?.notice)
            }
        }
    }

    func testKeepHiddenConsumesTokenWithoutPresentingMainWindow() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier(AppSceneID.mainWindow)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        var presentationRequests = 0
        let presenter = LiveAppWindowPresenter(requestMainWindowPresentation: { presentationRequests += 1 }, windowProvider: { [window] }, keyWindowProvider: { nil }, mainWindowProvider: { nil })
        let token = presenter.hideAppWindowIfNeeded(for: .application)
        XCTAssertNotNil(token)
        XCTAssertFalse(window.isVisible)
        presenter.keepAppWindowHidden(token)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(presentationRequests, 0)
    }

    func testPreviewPanelDoesNotBecomeMainOrStealFocus() async {
        let previousKeyWindow = NSApp.keyWindow
        let previousMainWindow = NSApp.mainWindow
        let controller = EditorController(capture: makeCapturedScreenshot(), capabilities: testCapabilities)
        let coordinator = CapturePreviewCoordinator()
        coordinator.presentsWindows = true
        coordinator.present(controller: controller, autoCopyEnabled: false,
                            copy: { $0(true) }, edit: {}, export: {}, drag: { nil })
        defer { coordinator.clear() }
        XCTAssertTrue(coordinator.panel?.styleMask.contains(.nonactivatingPanel) == true)
        XCTAssertEqual(coordinator.panel?.sharingType, NSWindow.SharingType.none)
        XCTAssertTrue(coordinator.panel?.isVisible == true)
        XCTAssertTrue(NSApp.keyWindow === previousKeyWindow)
        XCTAssertTrue(NSApp.mainWindow === previousMainWindow)
    }

    func testPreviewUsesRenderedRedactionAndKeepsSourceEditable() async throws {
        let capture = makeCapturedScreenshot()
        let annotation = Annotation.makeSolidRedaction(in: CGRect(x: 5, y: 5, width: 40, height: 30))
        let snapshot = makeEditorSnapshot(cropRect: CGRect(origin: .zero, size: capture.pixelSize), annotations: [annotation])
        let session = makeEditorDocumentSession(initialSnapshot: snapshot, currentSnapshot: snapshot)
        let controller = EditorController(capture: capture, session: session, capabilities: testCapabilities)
        let expected = try await controller.renderedImageForExport(appearance: .plain)
        let coordinator = CapturePreviewCoordinator()
        coordinator.presentsWindows = false
        coordinator.present(controller: controller, autoCopyEnabled: false,
                            copy: { $0(true) }, edit: {}, export: {}, drag: { nil })
        defer { coordinator.clear() }
        await waitUntil { coordinator.model?.image != nil }
        let preview = try XCTUnwrap(coordinator.model?.image)
        XCTAssertEqual(normalizedRGBAPixels(preview), normalizedRGBAPixels(expected))
        XCTAssertNotEqual(normalizedRGBAPixels(preview), normalizedRGBAPixels(capture.image))
        XCTAssertEqual(normalizedRGBAPixels(controller.editableDocument.capture.image), normalizedRGBAPixels(capture.image))
        XCTAssertEqual(controller.snapshot.annotations.count, 1)
    }

    func testPreviewRendersInLightDarkAndAccessibilityAppearances() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            let model = CapturePreviewModel(autoCopyEnabled: false, copy: { $0(true) }, edit: {}, export: {}, drag: { nil })
            model.image = makeCoordinateImage(width: 500, height: 300)
            let view = NSHostingView(rootView: CapturePreviewView(model: model))
            view.appearance = NSAppearance(named: appearance)
            view.frame = CGRect(x: 0, y: 0, width: 304, height: 310)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
            attachment.name = "Capture Preview - \(appearance.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func eligible(_ result: CaptureWorkflowResult, disposition: CaptureInstallationDisposition = .newDocument) -> Bool {
        CapturePreviewPolicy.shouldPresent(result: result, disposition: disposition, isEnabled: true)
    }

    private func makeApp() -> AppModel {
        let name = "CapturePreviewTests.app.\(UUID())"
        let defaults = makeDefaults(named: name)
        let environment = AppEnvironment(defaults: defaults, permissions: TestCapturePermissionService())
        let model = retainForTestLifetime(AppModel(defaults: defaults, environment: environment,
            recoveryStore: DocumentRecoveryStore(baseURL: FileManager.default.temporaryDirectory.appendingPathComponent(name)),
            shouldCheckCompatibilityOnLaunch: false, shouldStartArchiveMaintenance: false))
        model.documents.capturePreviewCoordinator.presentsWindows = false
        return model
    }

    private func result(allowsPreview: Bool = true, isPrivate: Bool = false,
                        kind: CaptureKind = .region, role: CaptureCompletionRole = .standalone) -> CaptureWorkflowResult {
        let capture = makeCapturedScreenshot(kind: kind)
        return CaptureWorkflowResult(capture: capture, uiMapSourceCapture: capture,
            request: .region(capture.sourceRect), runOptions: CaptureRunOptions(),
            isPrivateCapture: isPrivate, checkpointLabel: "Capture",
            shouldAttemptUIMapCapture: false, shouldProcessUIMap: false,
            uiMapSkipReason: nil, workflowPreset: nil, intent: .newDocument,
            completionRole: role, allowsCapturePreview: allowsPreview)
    }
}
