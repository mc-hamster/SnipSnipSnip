import AppKit
import XCTest
@testable import SnipSnipSnip

@MainActor
final class PresentationInteractionRegressionTests: XCTestCase {
    func testCappedCompositionPreviewRetainsLogicalContentSizeAndFraming() throws {
        let fixture = makeController()
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        try controller.appendCaptureToComposition(controller.capture, isPrivate: false)
        controller.setCompositionLayout(.row)
        controller.applyPresentationPreset(.lifted)
        let logicalSize = try controller.currentCompositionRenderLayout().canvasSize
        let input = try XCTUnwrap(controller.presentationPreviewRenderInput(maxPixelDimension: 250))
        XCTAssertEqual(input.logicalContentSize, logicalSize)
        XCTAssertLessThanOrEqual(max(input.contentImage.width, input.contentImage.height), 250)
        let full = try XCTUnwrap(controller.presentationPreviewRender())
        let capped = try XCTUnwrap(controller.presentationPreviewRender(maxPixelDimension: 250))
        assertRectsEqual(capped.layout.subjectRect,
            full.layout.subjectRect.applying(CGAffineTransform(scaleX: capped.pixelScale, y: capped.pixelScale)), accuracy: 0.001)
    }

    func testLookDragMovesSameLogicalDistanceAtDifferentPreviewCaps() throws {
        var offsets: [CGSize] = []
        for cap: CGFloat in [300, 600] {
            let fixture = makeController()
            defer { fixture.cleanUp() }
            let controller = fixture.controller
            controller.applyPresentationPreset(.lifted)
            controller.setWorkspaceMode(.presentation)
            controller.presentationInspectorTab = .style
            let result = try XCTUnwrap(controller.presentationPreviewRender(maxPixelDimension: cap))
            let harness = makeHarness(controller, result: result)
            defer { harness.window.close() }
            let start = subjectCenter(in: harness.view, controller: controller, result: result)
            let end = CGPoint(x: start.x + 24, y: start.y + 12)
            let initialViewport = controller.viewport
            try mouse(.leftMouseDown, at: start, in: harness)
            try mouse(.leftMouseDragged, at: CGPoint(x: start.x + 12, y: start.y + 6), in: harness)
            try mouse(.leftMouseDragged, at: end, in: harness)
            try mouse(.leftMouseUp, at: end, in: harness)
            XCTAssertEqual(controller.viewport, initialViewport, "A style mutation must retain the rendered viewport until the preview updates it")
            let displayScale = controller.viewport.imageRect.width / result.layout.canvasSize.width * result.pixelScale
            XCTAssertEqual(controller.presentation.subjectPlacement.offset.width, 24 / displayScale, accuracy: 0.01)
            XCTAssertEqual(controller.presentation.subjectPlacement.offset.height, 12 / displayScale, accuracy: 0.01)
            offsets.append(controller.presentation.subjectPlacement.offset)
        }
        XCTAssertEqual(offsets[0].width, offsets[1].width, accuracy: 0.1)
        XCTAssertEqual(offsets[0].height, offsets[1].height, accuracy: 0.1)
    }

    func testEscapeCancelsLookDragAndLeavesNextGestureUsable() throws {
        let fixture = makeController()
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        controller.applyPresentationPreset(.lifted)
        controller.setWorkspaceMode(.presentation)
        controller.presentationInspectorTab = .style
        let result = try XCTUnwrap(controller.presentationPreviewRender(maxPixelDimension: 400))
        let harness = makeHarness(controller, result: result)
        defer { harness.window.close() }
        let original = controller.snapshot
        let originalUndoCount = controller.documentSession.undoStack.count
        let start = subjectCenter(in: harness.view, controller: controller, result: result)
        let end = CGPoint(x: start.x + 30, y: start.y + 20)
        try mouse(.leftMouseDown, at: start, in: harness)
        try mouse(.leftMouseDragged, at: end, in: harness)
        XCTAssertNotEqual(controller.snapshot, original)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: harness.window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        harness.view.keyDown(with: escape)
        try mouse(.leftMouseUp, at: end, in: harness)
        XCTAssertEqual(controller.snapshot, original)
        XCTAssertEqual(controller.documentSession.undoStack.count, originalUndoCount)
        try mouse(.leftMouseDown, at: start, in: harness)
        try mouse(.leftMouseDragged, at: end, in: harness)
        try mouse(.leftMouseUp, at: end, in: harness)
        XCTAssertNotEqual(controller.snapshot, original)
        controller.undo()
        XCTAssertEqual(controller.snapshot, original)
    }

    func testRotatedMockupDragUsesLocalSlotCoordinates() throws {
        let fixture = makeController()
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        let scene = try XCTUnwrap(controller.presentationScenes.first)
        controller.applyPresentationScene(id: scene.id)
        controller.setWorkspaceMode(.presentation)
        controller.presentationInspectorTab = .scene
        let transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 160, ty: 40)
        let geometry = PresentationSceneGeometry(localSlotRect: CGRect(x: 0, y: 0, width: 100, height: 50),
            localToLogicalCanvas: transform)
        let rect = geometry.logicalSlotBounds.applying(CGAffineTransform(scaleX: 0.5, y: 0.5))
        let layout = ScreenshotPresentationRenderLayout(canvasSize: CGSize(width: 150, height: 150),
            subjectRect: rect, screenRect: rect, contentRect: rect, subjectScale: 1, frame: .none)
        let result = ScreenshotPresentationRenderResult(image: makeCoordinateImage(width: 150, height: 150),
            layout: layout, pixelScale: 0.5, sceneGeometry: geometry)
        let harness = makeHarness(controller, result: result)
        defer { harness.window.close() }
        let start = subjectCenter(in: harness.view, controller: controller, result: result)
        let end = CGPoint(x: start.x + 12, y: start.y + 24)
        let displayScale = controller.viewport.imageRect.width / layout.canvasSize.width * result.pixelScale
        let expected = CGSize(width: 12 / displayScale, height: 24 / displayScale).applying(transform.inverted())
        try mouse(.leftMouseDown, at: start, in: harness)
        try mouse(.leftMouseDragged, at: end, in: harness)
        try mouse(.leftMouseUp, at: end, in: harness)
        let offset = try XCTUnwrap(controller.presentation.scene).screenshotSlotSettings.offset
        XCTAssertEqual(offset.width, expected.width, accuracy: 0.01)
        XCTAssertEqual(offset.height, expected.height, accuracy: 0.01)
    }

    private func makeController() -> (controller: EditorController, cleanUp: () -> Void) {
        let name = "PresentationInteractionRegressionTests.\(UUID())"
        let defaults = makeDefaults(named: name)
        let capture = makeCapturedScreenshot(image: makeCoordinateImage(width: 800, height: 500))
        return (EditorController(capture: capture, defaults: defaults), { defaults.removePersistentDomain(forName: name) })
    }

    private func makeHarness(_ controller: EditorController, result: ScreenshotPresentationRenderResult)
        -> (view: PresentationViewportEventHostView, window: NSWindow) {
        let view = PresentationViewportEventHostView(controller: controller,
            contentSize: result.layout.canvasSize, pixelScale: result.pixelScale,
            sceneGeometry: result.sceneGeometry, sceneMappingUnavailable: result.sceneMappingUnavailable,
            presentationLayout: result.layout, compositionLayout: nil,
            sceneSlotRect: controller.presentation.scene == nil ? nil : result.layout.subjectRect,
            onCanvasInteraction: {})
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        view.layout()
        controller.zoomToFit()
        return (view, window)
    }

    private func subjectCenter(in view: NSView, controller: EditorController, result: ScreenshotPresentationRenderResult) -> CGPoint {
        let viewport = controller.viewport.imageRect
        let scale = viewport.width / result.layout.canvasSize.width
        return CGPoint(x: viewport.minX + result.layout.subjectRect.midX * scale,
            y: viewport.minY + result.layout.subjectRect.midY * scale)
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint,
        in harness: (view: PresentationViewportEventHostView, window: NSWindow)) throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type,
            location: harness.view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: harness.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        switch type {
        case .leftMouseDown: harness.view.mouseDown(with: event)
        case .leftMouseDragged: harness.view.mouseDragged(with: event)
        case .leftMouseUp: harness.view.mouseUp(with: event)
        default: XCTFail("Unexpected test event")
        }
    }
}
