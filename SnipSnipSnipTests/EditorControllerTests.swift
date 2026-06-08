import AppKit
import CoreGraphics
import XCTest
@testable import SnipSnipSnip

@MainActor
final class EditorControllerTests: XCTestCase {
    func testFreshCaptureAddsCapturedCursorAsEditableOverlay() {
        let cursorImage = makeSolidImage(width: 12, height: 14, color: PixelSample(red: 10, green: 20, blue: 30, alpha: 255))
        let capture = makeCapturedScreenshot().attachingCursorOverlay(
            CapturedCursorOverlay(image: cursorImage, rect: CGRect(x: 8, y: 9, width: 12, height: 14))
        )
        let controller = retainForTestLifetime(EditorController(capture: capture))

        guard case let .imageOverlay(shape) = controller.snapshot.annotations.first?.kind else {
            return XCTFail("Expected captured cursor image overlay")
        }

        XCTAssertEqual(controller.snapshot.annotations.count, 1)
        XCTAssertEqual(shape.rect, CGRect(x: 8, y: 9, width: 12, height: 14))
        XCTAssertEqual(shape.role, .capturedCursor)

        controller.select(annotationIDs: [controller.snapshot.annotations[0].id])
        controller.deleteSelected()
        XCTAssertTrue(controller.snapshot.annotations.isEmpty)
    }

    @MainActor
    func testTextUpdatesCoalesceIntoSingleUndoableCommit() async {
        let text = Annotation.makeText(at: CGPoint(x: 40, y: 40)).updatingText("Hello")
        let snapshot = makeEditorSnapshot(
            annotations: [text],
            selectedAnnotationIDs: [text.id]
        )
        let controller = makeController(snapshot: snapshot)

        controller.updateText("Hello A")
        controller.updateText("Hello AB")
        controller.updateText("Hello ABC")

        XCTAssertEqual(controller.selectedText, "Hello ABC")
        XCTAssertEqual(controller.persistenceRevision, 0)

        try? await Task.sleep(nanoseconds: 450_000_000)

        XCTAssertEqual(controller.persistenceRevision, 1)

        controller.undo()

        XCTAssertEqual(controller.selectedText, "Hello")
    }

    @MainActor
    func testTextBoundsExpandImmediatelyWhileTyping() async {
        let baseText = Annotation.makeText(at: CGPoint(x: 40, y: 40)).updatingText("Hello")
        let snapshot = makeEditorSnapshot(
            annotations: [baseText],
            selectedAnnotationIDs: [baseText.id]
        )
        let controller = makeController(snapshot: snapshot)
        let originalBounds = controller.selectedAnnotation?.boundingRect
        let expandedText = Array(repeating: "wrap me into multiple lines", count: 8).joined(separator: " ")

        controller.updateText(expandedText)

        guard let updatedBounds = controller.selectedAnnotation?.boundingRect,
              let originalBounds
        else {
            return XCTFail("Expected updated text annotation bounds")
        }

        XCTAssertGreaterThan(updatedBounds.height, originalBounds.height)
        XCTAssertEqual(controller.persistenceRevision, 0)

        try? await Task.sleep(nanoseconds: 450_000_000)

        XCTAssertGreaterThan(controller.selectedAnnotation?.boundingRect.height ?? 0, originalBounds.height)
        XCTAssertEqual(controller.persistenceRevision, 1)
    }

    @MainActor
    func testLineBreakTypingExpandsTextBoundsBeforeCommit() {
        let baseText = Annotation.makeText(at: CGPoint(x: 40, y: 40))
            .resized(to: CGRect(x: 40, y: 40, width: 180, height: 60))
            .updatingText("Line 1")
        let snapshot = makeEditorSnapshot(
            annotations: [baseText],
            selectedAnnotationIDs: [baseText.id]
        )
        let controller = makeController(snapshot: snapshot)
        let originalBounds = controller.selectedAnnotation?.boundingRect

        controller.insertLineBreakInTextSelection()
        controller.applyTextInput("This second line should stay visible in the annotation frame.")

        guard let updatedBounds = controller.selectedAnnotation?.boundingRect,
              let originalBounds
        else {
            return XCTFail("Expected updated text annotation bounds")
        }

        XCTAssertGreaterThan(updatedBounds.height, originalBounds.height)
        XCTAssertEqual(controller.persistenceRevision, 0)
    }

    @MainActor
    func testTypingWithAppModelObserverStaysResponsive() {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let defaults = makeTestDefaults()
        let model = retainForTestLifetime(AppModel(defaults: defaults, recoveryStore: store, shouldCheckCompatibilityOnLaunch: false))
        model.autoCopyEnabled = false

        let text = Annotation.makeText(at: CGPoint(x: 40, y: 40)).updatingText("Hello")
        let snapshot = makeEditorSnapshot(
            cropRect: CGRect(x: 0, y: 0, width: 160, height: 120),
            annotations: [text],
            selectedAnnotationIDs: [text.id]
        )
        let controller = makeController(snapshot: snapshot, defaults: defaults)
        let documentURL = rootURL.appendingPathComponent("TypingBenchmark.sss")

        model.installEditorController(controller, documentURL: documentURL, savedSession: controller.documentSession)

        var currentText = controller.selectedText
        let elapsed = ContinuousClock().measure {
            for index in 0..<240 {
                let scalar = UnicodeScalar(97 + (index % 26)) ?? "a"
                currentText.append(Character(scalar))
                controller.updateText(currentText)
            }
        }

        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertTrue(model.hasUnsavedChanges)

        model.resetEditorSessionState()
        try? FileManager.default.removeItem(at: rootURL)
    }

    @MainActor
    func testPresentationPresetChangesAreUndoable() {
        let controller = makeController(snapshot: makeEditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: 160, height: 120)))
        let originalPresentation = controller.snapshot.presentation

        controller.applyPresentationPreset(.transparentShadow)

        if FeatureFlags.presentationStylingEnabled {
            XCTAssertEqual(controller.snapshot.presentation, ScreenshotPresentationPreset.transparentShadow.settings)
            XCTAssertTrue(controller.requiresPNGForFaithfulExport)

            controller.undo()

            XCTAssertEqual(controller.snapshot.presentation, .plain)
            XCTAssertFalse(controller.requiresPNGForFaithfulExport)
        } else {
            XCTAssertEqual(controller.snapshot.presentation, originalPresentation)
            XCTAssertFalse(controller.requiresPNGForFaithfulExport)
        }
    }

    @MainActor
    func testPresentationDefaultsToTransparentBackground() {
        let controller = makeController(snapshot: makeEditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: 160, height: 120)))
        let originalPresentation = controller.snapshot.presentation

        controller.updatePresentationPadding(24)

        if FeatureFlags.presentationStylingEnabled {
            XCTAssertTrue(controller.presentation.isTransparent)
            XCTAssertTrue(controller.requiresPNGForFaithfulExport)
        } else {
            XCTAssertEqual(controller.snapshot.presentation, originalPresentation)
            XCTAssertEqual(controller.presentation, .plain)
            XCTAssertFalse(controller.requiresPNGForFaithfulExport)
        }
    }

    @MainActor
    func testPresentationCornerRadiusClampsToOneHundred() {
        let controller = makeController(snapshot: makeEditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: 160, height: 120)))
        let originalPresentation = controller.snapshot.presentation

        controller.updatePresentationCornerRadius(120)

        if FeatureFlags.presentationStylingEnabled {
            XCTAssertEqual(controller.presentation.cornerRadius, 100)
        } else {
            XCTAssertEqual(controller.snapshot.presentation, originalPresentation)
            XCTAssertEqual(controller.presentation, .plain)
        }
    }

    @MainActor
    func testPresentationShadowDirectionControlsSignedOffsets() {
        let controller = makeController(snapshot: makeEditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: 160, height: 120)))
        let originalPresentation = controller.snapshot.presentation

        controller.updatePresentationShadow(.strong)
        controller.updatePresentationShadowDirection(.topLeft)

        controller.updatePresentationShadowOffsetX(24)
        controller.updatePresentationShadowOffsetY(26)

        controller.updatePresentationShadowDirection(.bottomRight)

        if FeatureFlags.presentationStylingEnabled {
            XCTAssertEqual(controller.presentation.shadowDirection, .bottomRight)
            XCTAssertEqual(controller.presentation.shadowOffsetX, 24)
            XCTAssertEqual(controller.presentation.shadowOffsetY, 26)
        } else {
            XCTAssertEqual(controller.snapshot.presentation, originalPresentation)
            XCTAssertEqual(controller.presentation, .plain)
        }
    }

    func testSelectingGroupedAnnotationExpandsGroupInDocumentOrder() {
        let groupID = UUID()
        let first = Annotation.makeRectangle(in: CGRect(x: 10, y: 10, width: 40, height: 30)).updatingGroup(groupID)
        let second = Annotation.makeEllipse(in: CGRect(x: 80, y: 10, width: 40, height: 30)).updatingGroup(groupID)
        let third = Annotation.makeLine(from: CGPoint(x: 20, y: 80), to: CGPoint(x: 100, y: 120))
        let snapshot = makeEditorSnapshot(
            annotations: [first, second, third],
            selectedAnnotationIDs: []
        )
        let controller = makeController(snapshot: snapshot)

        controller.select(annotationIDs: [second.id])

        XCTAssertEqual(controller.snapshot.selectedAnnotationIDs, [first.id, second.id])
        XCTAssertEqual(controller.selectedAnnotations.map(\ .id), [first.id, second.id])
    }

    func testToggleSelectionRemovesEntireExpandedGroup() {
        let groupID = UUID()
        let first = Annotation.makeRectangle(in: CGRect(x: 10, y: 10, width: 40, height: 30)).updatingGroup(groupID)
        let second = Annotation.makeEllipse(in: CGRect(x: 80, y: 10, width: 40, height: 30)).updatingGroup(groupID)
        let snapshot = makeEditorSnapshot(
            annotations: [first, second],
            selectedAnnotationIDs: [first.id, second.id]
        )
        let controller = makeController(snapshot: snapshot)

        controller.select(annotationIDs: [first.id], toggle: true)

        XCTAssertTrue(controller.snapshot.selectedAnnotationIDs.isEmpty)
    }

    @MainActor
    func testSelectedAnnotationBodyCanMoveWhileRectangleToolIsActive() {
        let annotation = Annotation.makeRectangle(in: CGRect(x: 30, y: 30, width: 50, height: 40))
        let snapshot = makeEditorSnapshot(
            cropRect: CGRect(x: 0, y: 0, width: 160, height: 120),
            annotations: [annotation],
            selectedAnnotationIDs: [annotation.id]
        )
        let controller = makeController(snapshot: snapshot)
        controller.activeTool = .rectangle

        let (_, overlay, window) = makeCanvasHarness(controller: controller, frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let startPoint = viewPoint(for: CGPoint(x: annotation.boundingRect.midX, y: annotation.boundingRect.midY), controller: controller)
        let endPoint = viewPoint(for: CGPoint(x: annotation.boundingRect.midX + 20, y: annotation.boundingRect.midY + 10), controller: controller)

        sendMouseEvent(.leftMouseDown, at: startPoint, to: overlay, in: window, eventNumber: 1)
        sendMouseEvent(.leftMouseDragged, at: endPoint, to: overlay, in: window, eventNumber: 2)
        sendMouseEvent(.leftMouseUp, at: endPoint, to: overlay, in: window, eventNumber: 3)

        guard let updatedBounds = controller.selectedAnnotation?.boundingRect else {
            return XCTFail("Expected moved annotation bounds")
        }

        XCTAssertEqual(controller.snapshot.annotations.count, 1)
        XCTAssertEqual(controller.selectedAnnotation?.id, annotation.id)
        XCTAssertGreaterThan(updatedBounds.minX, annotation.boundingRect.minX)
        XCTAssertGreaterThan(updatedBounds.minY, annotation.boundingRect.minY)
    }

    @MainActor
    func testRectangleToolDragAddsAnnotation() {
        let controller = makeController(snapshot: makeEditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: 160, height: 120)))
        controller.activeTool = .rectangle

        let (_, overlay, window) = makeCanvasHarness(
            controller: controller,
            frame: CGRect(x: 0, y: 0, width: 640, height: 480)
        )

        let startPoint = viewPoint(for: CGPoint(x: 30, y: 30), controller: controller)
        let endPoint = viewPoint(for: CGPoint(x: 100, y: 80), controller: controller)

        sendMouseEvent(.leftMouseDown, at: startPoint, to: overlay, in: window, eventNumber: 1)
        sendMouseEvent(.leftMouseDragged, at: endPoint, to: overlay, in: window, eventNumber: 2)
        sendMouseEvent(.leftMouseUp, at: endPoint, to: overlay, in: window, eventNumber: 3)

        XCTAssertEqual(controller.snapshot.annotations.count, 1)
        XCTAssertEqual(controller.snapshot.annotations.first?.editorTool, .rectangle)
    }

    @MainActor
    func testTextToolClickAddsAnnotation() {
        let controller = makeController(snapshot: makeEditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: 160, height: 120)))
        controller.activeTool = .text

        let (_, overlay, window) = makeCanvasHarness(
            controller: controller,
            frame: CGRect(x: 0, y: 0, width: 640, height: 480)
        )

        let clickPoint = viewPoint(for: CGPoint(x: 50, y: 45), controller: controller)

        sendMouseEvent(.leftMouseDown, at: clickPoint, to: overlay, in: window, eventNumber: 1)

        XCTAssertEqual(controller.snapshot.annotations.count, 1)
        XCTAssertEqual(controller.snapshot.annotations.first?.editorTool, .text)
    }

    @MainActor
    func testRectangleToolDragAddsAnnotationInsideCroppedRegion() {
        let controller = makeController(
            snapshot: makeEditorSnapshot(cropRect: CGRect(x: 20, y: 15, width: 80, height: 60)),
            captureSize: CGSize(width: 160, height: 120)
        )
        controller.activeTool = .rectangle

        let (_, overlay, window) = makeCanvasHarness(
            controller: controller,
            frame: CGRect(x: 0, y: 0, width: 640, height: 480)
        )

        let startPoint = viewPoint(for: CGPoint(x: 30, y: 25), controller: controller)
        let endPoint = viewPoint(for: CGPoint(x: 85, y: 55), controller: controller)

        sendMouseEvent(.leftMouseDown, at: startPoint, to: overlay, in: window, eventNumber: 1)
        sendMouseEvent(.leftMouseDragged, at: endPoint, to: overlay, in: window, eventNumber: 2)
        sendMouseEvent(.leftMouseUp, at: endPoint, to: overlay, in: window, eventNumber: 3)

        XCTAssertEqual(controller.snapshot.annotations.count, 1)
        XCTAssertEqual(controller.snapshot.annotations.first?.editorTool, .rectangle)
    }

    @MainActor
    func testCropOverlayDoesNotEraseVisibleAnnotations() {
        let annotation = Annotation.makeRectangle(in: CGRect(x: 30, y: 30, width: 50, height: 35))
        let capture = makeCapturedScreenshot(image: makeSolidImage(width: 160, height: 120, color: PixelSample(red: 255, green: 255, blue: 255, alpha: 255)))
        let controller = makeController(
            snapshot: makeEditorSnapshot(
                cropRect: CGRect(x: 20, y: 15, width: 100, height: 80),
                annotations: [annotation]
            ),
            capture: capture
        )

        let (canvas, _, _) = makeCanvasHarness(
            controller: controller,
            frame: CGRect(x: 0, y: 0, width: 640, height: 480)
        )

        guard let rendered = renderView(canvas) else {
            return XCTFail("Expected rendered canvas image")
        }

        let borderPoint = viewPoint(for: CGPoint(x: annotation.boundingRect.midX, y: annotation.boundingRect.minY), controller: controller)
        let pixel = samplePixel(in: rendered, topLeftX: Int(borderPoint.x.rounded()), topLeftY: Int(borderPoint.y.rounded()))

        XCTAssertNotEqual(pixel, PixelSample(red: 255, green: 255, blue: 255, alpha: 255))
    }

    func testUngroupSelectedClearsEntireExpandedGroupInDocumentOrder() {
        let groupID = UUID()
        let first = Annotation.makeRectangle(in: CGRect(x: 10, y: 10, width: 40, height: 30)).updatingGroup(groupID)
        let second = Annotation.makeEllipse(in: CGRect(x: 80, y: 10, width: 40, height: 30)).updatingGroup(groupID)
        let third = Annotation.makeLine(from: CGPoint(x: 20, y: 80), to: CGPoint(x: 100, y: 120))
        let snapshot = makeEditorSnapshot(
            annotations: [first, second, third],
            selectedAnnotationIDs: []
        )
        let controller = makeController(snapshot: snapshot)

        controller.select(annotationIDs: [second.id])
        controller.ungroupSelected()

        XCTAssertEqual(controller.snapshot.selectedAnnotationIDs, [first.id, second.id])
        XCTAssertEqual(controller.snapshot.annotations.prefix(2).map(\.groupID), [nil, nil])
        XCTAssertNil(controller.snapshot.annotations.last?.groupID)
    }

    func testInspectorStateUsesSelectedTextAnnotation() {
        let text = Annotation.makeText(at: CGPoint(x: 40, y: 40)).updatingText("Hello")
        let snapshot = makeEditorSnapshot(
            annotations: [text],
            selectedAnnotationIDs: [text.id]
        )
        let controller = makeController(snapshot: snapshot)
        controller.activeTool = .rectangle

        XCTAssertEqual(controller.selectedText, "Hello")
        XCTAssertTrue(controller.showsFontControls)
        XCTAssertTrue(controller.showsFillControls)
        XCTAssertTrue(controller.showsTextAlignmentControls)
        XCTAssertEqual(controller.stylePrimaryLabel, "Text Color")
    }

    func testCanAlignSelectionIsFalseForSingleNonTextAnnotation() {
        let rectangle = Annotation.makeRectangle(in: CGRect(x: 10, y: 10, width: 40, height: 30))
        let snapshot = makeEditorSnapshot(
            annotations: [rectangle],
            selectedAnnotationIDs: [rectangle.id]
        )
        let controller = makeController(snapshot: snapshot)
        controller.activeTool = .rectangle

        XCTAssertFalse(controller.showsTextAlignmentControls)
        XCTAssertFalse(controller.canAlignSelection)
    }

    func testCanAlignSelectionIsTrueForMultipleSelectedAnnotations() {
        let first = Annotation.makeRectangle(in: CGRect(x: 10, y: 10, width: 40, height: 30))
        let second = Annotation.makeEllipse(in: CGRect(x: 80, y: 20, width: 40, height: 30))
        let snapshot = makeEditorSnapshot(
            annotations: [first, second],
            selectedAnnotationIDs: [first.id, second.id]
        )
        let controller = makeController(snapshot: snapshot)

        XCTAssertTrue(controller.canAlignSelection)
    }

    func testRotateSelectedClockwise90UpdatesSelectionAndIsUndoable() {
        let first = Annotation.makeRectangle(in: CGRect(x: 10, y: 10, width: 40, height: 30))
            .updatingRotationDegrees(15)
        let second = Annotation.makeEllipse(in: CGRect(x: 80, y: 20, width: 40, height: 30))
            .updatingRotationDegrees(270)
        let snapshot = makeEditorSnapshot(
            annotations: [first, second],
            selectedAnnotationIDs: [first.id, second.id]
        )
        let controller = makeController(snapshot: snapshot)

        controller.rotateSelectedClockwise90()

        XCTAssertEqual(controller.snapshot.annotations.map(\.rotationDegrees), [105, 0])
        XCTAssertEqual(controller.snapshot.selectedAnnotationIDs, [first.id, second.id])

        controller.undo()

        XCTAssertEqual(controller.snapshot.annotations.map(\.rotationDegrees), [15, 270])
        XCTAssertEqual(controller.snapshot.selectedAnnotationIDs, [first.id, second.id])
    }

    func testRotateSelectedClockwise90IgnoresArrowSelection() {
        let arrow = Annotation.makeArrow(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 80, y: 70))
        let snapshot = makeEditorSnapshot(
            annotations: [arrow],
            selectedAnnotationIDs: [arrow.id]
        )
        let controller = makeController(snapshot: snapshot)

        XCTAssertFalse(controller.canRotateSelection)

        controller.rotateSelectedClockwise90()

        XCTAssertEqual(controller.snapshot.annotations.first?.rotationDegrees, 0)
        XCTAssertFalse(controller.canUndo)
    }

    func testUpdateRedactionModeChangesSelectedRedactionBeforeActiveTool() {
        let redaction = Annotation.makeBlur(in: CGRect(x: 10, y: 10, width: 60, height: 40))
        let snapshot = makeEditorSnapshot(
            annotations: [redaction],
            selectedAnnotationIDs: [redaction.id]
        )
        let controller = makeController(snapshot: snapshot)
        controller.activeTool = .rectangle

        controller.updateRedactionMode(.solid)

        XCTAssertEqual(controller.selectedAnnotation?.redactionMode, .solid)
        XCTAssertEqual(controller.activeTool, .rectangle)
    }

    func testUpdateRedactionModeFallsBackToMatchingActiveToolWithoutSelection() {
        let controller = makeController()

        controller.updateRedactionMode(.pixelate)
        XCTAssertEqual(controller.activeTool, .pixelate)

        controller.updateRedactionMode(.solid)
        XCTAssertEqual(controller.activeTool, .redact)
    }

    func testActivateToolbarRedactionToolUsesPersistedMode() {
        let defaults = makeTestDefaults()
        defaults.set(RedactionMode.pixelate.rawValue, forKey: "editor.lastRedactionMode")
        let controller = makeController(defaults: defaults)

        controller.activateToolbarTool(.blur)

        XCTAssertEqual(controller.activeTool, .pixelate)
        XCTAssertEqual(controller.currentRedactionMode, .pixelate)
    }

    func testUpdateRedactionModePersistsAcrossControllerRestarts() {
        let defaults = makeTestDefaults()
        let controller = makeController(defaults: defaults)

        controller.updateRedactionMode(.solid)

        XCTAssertEqual(defaults.string(forKey: "editor.lastRedactionMode"), RedactionMode.solid.rawValue)

        let reloaded = makeController(defaults: defaults)
        reloaded.activateToolbarTool(.blur)

        XCTAssertEqual(reloaded.activeTool, .redact)
        XCTAssertEqual(reloaded.currentRedactionMode, .solid)
    }

    @MainActor
    func testUpdateStrokeColorPersistsAcrossFreshCaptureControllers() {
        let defaults = makeTestDefaults()
        let capture = makeCapturedScreenshot(image: makeCoordinateImage(width: 160, height: 120))
        let controller = retainForTestLifetime(EditorController(capture: capture, defaults: defaults))
        controller.activeTool = .rectangle

        controller.updateStrokeColor(.calloutFill)

        XCTAssertEqual(defaults.string(forKey: "editor.lastStrokeColorID"), "pink")

        let reloaded = retainForTestLifetime(EditorController(capture: capture, defaults: defaults))
        reloaded.activeTool = .rectangle

        XCTAssertEqual(reloaded.inspectorStyle.strokeColor, .calloutFill)
    }

    @MainActor
    func testLaterToolChangesDoNotOverwritePersistedArrowStyle() {
        let defaults = makeTestDefaults()
        let capture = makeCapturedScreenshot(image: makeCoordinateImage(width: 160, height: 120))
        let controller = retainForTestLifetime(EditorController(capture: capture, defaults: defaults))

        controller.activeTool = .arrow
        controller.updateStrokeColor(.calloutFill)
        controller.updateLineWidth(11)

        controller.activeTool = .callout
        controller.updateStrokeColor(.ellipseStroke)
        controller.updateFillColor(.highlightFill)
        controller.updateFontSize(26)

        let reloaded = retainForTestLifetime(EditorController(capture: capture, defaults: defaults))

        reloaded.activeTool = .arrow
        XCTAssertEqual(reloaded.inspectorStyle.strokeColor, .calloutFill)
        XCTAssertEqual(reloaded.inspectorStyle.lineWidth, 11)
    }

    @MainActor
    func testSelectedAnnotationStyleChangesPersistBackToOwningTool() {
        let defaults = makeTestDefaults()
        let arrow = Annotation.makeArrow(
            from: CGPoint(x: 20, y: 20),
            to: CGPoint(x: 120, y: 80)
        )
        let snapshot = makeEditorSnapshot(
            annotations: [arrow],
            selectedAnnotationIDs: [arrow.id]
        )
        let controller = makeController(snapshot: snapshot, defaults: defaults)

        controller.updateStrokeColor(.blurOutline)
        controller.updateLineWidth(9)

        let capture = makeCapturedScreenshot(image: makeCoordinateImage(width: 160, height: 120))
        let reloaded = retainForTestLifetime(EditorController(capture: capture, defaults: defaults))
        reloaded.activeTool = .arrow

        XCTAssertEqual(reloaded.inspectorStyle.strokeColor, .blurOutline)
        XCTAssertEqual(reloaded.inspectorStyle.lineWidth, 9)
    }

    @MainActor
    func testSampledColorAppliesToStrokeOrFill() {
        let controller = makeController()
        controller.activeTool = .rectangle

        controller.applySampledColor(at: CGPoint(x: 12, y: 8))
        controller.activeTool = .rectangle
        XCTAssertEqual(controller.inspectorStyle.strokeColor, RGBAColor(red: 12.0 / 255.0, green: 8.0 / 255.0, blue: 0, alpha: 1))

        controller.activeTool = .rectangle
        controller.applySampledColor(at: CGPoint(x: 20, y: 11), toFill: true)
        controller.activeTool = .rectangle
        XCTAssertEqual(controller.inspectorStyle.fillColor, RGBAColor(red: 20.0 / 255.0, green: 11.0 / 255.0, blue: 0, alpha: 1))
    }

    @MainActor
    func testSampledColorReadsLittleEndianFirstImagesAsBGRA() {
        let controller = makeController(capture: makeCapturedScreenshot(image: makeBGRACoordinateImage(width: 80, height: 60)))
        controller.activeTool = .rectangle

        controller.applySampledColor(at: CGPoint(x: 21, y: 13))
        controller.activeTool = .rectangle

        XCTAssertEqual(controller.inspectorStyle.strokeColor.red, 21.0 / 255.0, accuracy: 0.0001)
        XCTAssertEqual(controller.inspectorStyle.strokeColor.green, 13.0 / 255.0, accuracy: 0.0001)
        XCTAssertEqual(controller.inspectorStyle.strokeColor.blue, 34.0 / 255.0, accuracy: 0.0001)
        XCTAssertEqual(controller.inspectorStyle.strokeColor.alpha, 1, accuracy: 0.0001)
    }

    @MainActor
    func testInspectorSamplingModeArmsCanvasPickerAndClearsAfterSampling() {
        let controller = makeController()
        controller.activeTool = .rectangle

        controller.beginImageColorSampling(.fill)
        XCTAssertTrue(controller.isSamplingImageColor)
        XCTAssertEqual(controller.imageColorSamplingTarget, .fill)
        XCTAssertEqual(controller.activeTool, .colorPicker)

        controller.applySampledColor(at: CGPoint(x: 8, y: 6))

        XCTAssertFalse(controller.isSamplingImageColor)
        XCTAssertEqual(controller.activeTool, .select)
        XCTAssertEqual(controller.style(for: .rectangle).fillColor, RGBAColor(red: 8.0 / 255.0, green: 6.0 / 255.0, blue: 0, alpha: 1))
    }

    @MainActor
    func testImageSamplingPreviewUpdatesWithoutCommittingStyle() {
        let controller = makeController()
        controller.activeTool = .rectangle
        let originalStroke = controller.style(for: .rectangle).strokeColor

        controller.beginImageColorSampling(.picker)
        controller.previewSampledColor(at: CGPoint(x: 12, y: 9))

        XCTAssertEqual(controller.previewedImageSampleColor, RGBAColor(red: 12.0 / 255.0, green: 9.0 / 255.0, blue: 0, alpha: 1))
        XCTAssertEqual(controller.sampledPickerPreviewColor, RGBAColor(red: 12.0 / 255.0, green: 9.0 / 255.0, blue: 0, alpha: 1))
        XCTAssertEqual(controller.style(for: .rectangle).strokeColor, originalStroke)

        controller.applySampledColor(at: CGPoint(x: 14, y: 10))

        XCTAssertNil(controller.previewedImageSampleColor)
        XCTAssertEqual(controller.style(for: .rectangle).strokeColor, RGBAColor(red: 14.0 / 255.0, green: 10.0 / 255.0, blue: 0, alpha: 1))
    }

    @MainActor
    func testDeletingCalloutRenumbersRemainingCallouts() {
        let first = Annotation.makeCallout(at: CGPoint(x: 10, y: 10), number: 1)
        let second = Annotation.makeCallout(at: CGPoint(x: 20, y: 20), number: 2)
            .updatingText("Document second step")
        let third = Annotation.makeCallout(at: CGPoint(x: 30, y: 30), number: 3)
        let snapshot = makeEditorSnapshot(
            annotations: [first, second, third],
            selectedAnnotationIDs: [second.id],
            nextCalloutNumber: 4
        )
        let controller = makeController(snapshot: snapshot)

        controller.deleteSelected()

        let numbers = controller.snapshot.annotations.compactMap { annotation -> Int? in
            guard case let .callout(shape) = annotation.kind else {
                return nil
            }
            return shape.number
        }
        XCTAssertEqual(numbers, [1, 2])
        XCTAssertTrue(controller.snapshot.annotations.contains { annotation in
            guard case let .callout(shape) = annotation.kind else {
                return false
            }
            return shape.text == "Document second step"
        } == false)
    }

    @MainActor
    func testNumericCropUpdateAdjustsCropRect() {
        let snapshot = makeEditorSnapshot(cropRect: CGRect(x: 4, y: 6, width: 80, height: 60))
        let controller = makeController(snapshot: snapshot, captureSize: CGSize(width: 160, height: 120))

        controller.updateCropOrigin(x: 12, y: 14, width: 44, height: 30)

        XCTAssertEqual(controller.snapshot.cropRect, CGRect(x: 12, y: 14, width: 44, height: 30))
        XCTAssertEqual(controller.viewport.contentSize, CGSize(width: 160, height: 120))
    }

    @MainActor
    func testFixedCropAspectRatioPresetImmediatelyUpdatesCropRect() {
        let snapshot = makeEditorSnapshot(cropRect: CGRect(x: 20, y: 15, width: 80, height: 60))
        let controller = makeController(snapshot: snapshot, captureSize: CGSize(width: 160, height: 120))

        controller.updateCropAspectRatioPreset(.square)

        XCTAssertEqual(controller.cropAspectRatioPreset, .square)
        XCTAssertEqual(controller.snapshot.cropRect, CGRect(x: 30, y: 15, width: 60, height: 60))

        controller.undo()
        XCTAssertEqual(controller.snapshot.cropRect, CGRect(x: 20, y: 15, width: 80, height: 60))
        XCTAssertEqual(controller.cropAspectRatioPreset, .square)
    }

    @MainActor
    func testPortraitCropAspectRatioPresetImmediatelyUpdatesCropRect() {
        let snapshot = makeEditorSnapshot(cropRect: CGRect(x: 20, y: 15, width: 80, height: 60))
        let controller = makeController(snapshot: snapshot, captureSize: CGSize(width: 160, height: 120))

        controller.updateCropAspectRatioPreset(.threeFour)

        XCTAssertEqual(controller.cropAspectRatioPreset, .threeFour)
        XCTAssertEqual(controller.snapshot.cropRect, CGRect(x: 38, y: 15, width: 45, height: 60))
    }

    @MainActor
    func testFreeformCropAspectRatioPresetDoesNotChangeCropRect() {
        let snapshot = makeEditorSnapshot(cropRect: CGRect(x: 20, y: 15, width: 80, height: 60))
        let controller = makeController(snapshot: snapshot, captureSize: CGSize(width: 160, height: 120))
        controller.cropAspectRatioPreset = .square

        controller.updateCropAspectRatioPreset(.freeform)

        XCTAssertEqual(controller.cropAspectRatioPreset, .freeform)
        XCTAssertEqual(controller.snapshot.cropRect, CGRect(x: 20, y: 15, width: 80, height: 60))
    }

    @MainActor
    func testSelectedArrowControlsUpdateCurvatureHeadAndLabel() {
        let arrow = Annotation.makeArrow(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 120, y: 60))
        let snapshot = makeEditorSnapshot(
            annotations: [arrow],
            selectedAnnotationIDs: [arrow.id]
        )
        let controller = makeController(snapshot: snapshot)

        controller.updateArrowCurvature(36)
        controller.updateArrowHeadStyle(.double)
        controller.updateArrowLabel("Ship")
        controller.updateArrowLabelBoxColor(.highlightFill)
        controller.updateArrowLabelPlacement(.parallelBelow)
        controller.updateArrowLabelFontSize(22)
        controller.updateArrowLabelTextColor(.complementary)
        controller.updateArrowHeadShape(.stealth)

        guard case let .arrow(updatedArrow) = controller.selectedAnnotation?.kind else {
            return XCTFail("Expected arrow annotation")
        }

        XCTAssertEqual(updatedArrow.curvature, 36)
        XCTAssertEqual(updatedArrow.headStyle, .double)
        XCTAssertEqual(updatedArrow.label, "Ship")
        XCTAssertEqual(updatedArrow.labelBoxColor, .highlightFill)
        XCTAssertEqual(updatedArrow.labelPlacement, .parallelBelow)
        XCTAssertEqual(updatedArrow.labelFontSize, 22)
        XCTAssertEqual(updatedArrow.labelTextColor, .complementary)
        XCTAssertEqual(updatedArrow.labelTextColor.resolvedColor(for: .arrowStroke), .arrowStroke.complementary)
        XCTAssertEqual(updatedArrow.headShape, .stealth)
        XCTAssertFalse(controller.showsRotationControls)
    }

    @MainActor
    func testArrowLabelDefaultsToTopAndTopBottomUseScreenCoordinates() {
        let arrow = Annotation.makeArrow(from: CGPoint(x: 20, y: 100), to: CGPoint(x: 180, y: 100))
            .updatingArrow(label: "Ship")

        guard case let .arrow(defaultShape) = arrow.kind else {
            return XCTFail("Expected arrow annotation")
        }

        let topArrow = arrow.updatingArrow(labelPlacement: .parallelAbove)
        let bottomArrow = arrow.updatingArrow(labelPlacement: .parallelBelow)

        XCTAssertEqual(defaultShape.labelPlacement, .parallelAbove)
        XCTAssertLessThan(topArrow.boundingRect.minY, arrow.boundingRect.minY + 0.001)
        XCTAssertGreaterThan(bottomArrow.boundingRect.maxY, arrow.boundingRect.maxY - 0.001)
    }

    @MainActor
    func testSelectableOCRUsesCroppedRegionAndNormalizesRecognizedText() async {
        let recognizer = StubTextRecognizer(text: "  First line\n\nSecond\tline  ")
        let snapshot = makeEditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: 160, height: 120))
        let controller = makeController(snapshot: snapshot, textRecognizer: recognizer)

        controller.recognizeText(in: CGRect(x: 12, y: 8, width: 30, height: 14))
        await waitForOCR(controller)

        XCTAssertEqual(controller.ocrReviewText, "First line Second line")
        XCTAssertEqual(recognizer.lastImageSize, CGSize(width: 30, height: 14))
    }

    @MainActor
    func testCompleteCaptureAttachesUIMapWhenPreferenceIsEnabled() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let defaults = makeTestDefaults()
        let uiMap = makeTestUIMap()
        let uiMapCaptureService = StubUIMapCaptureService(uiMap: uiMap)
        let model = retainForTestLifetime(AppModel(
            defaults: defaults,
            recoveryStore: store,
            uiMapCaptureService: uiMapCaptureService,
            shouldCheckCompatibilityOnLaunch: false
        ))
        model.autoCopyEnabled = false
        model.uiMapEnabled = true

        try model.completeCapture(
            makeCapturedScreenshot(image: makeCoordinateImage(width: 64, height: 48)),
            request: .region(CGRect(x: 0, y: 0, width: 64, height: 48)),
            isPrivateCapture: false
        )

        XCTAssertEqual(model.editorController?.capture.uiMap, uiMap)
        XCTAssertEqual(uiMapCaptureService.captureCallCount, 1)

        model.resetEditorSessionState()
        try? FileManager.default.removeItem(at: rootURL)
    }

    @MainActor
    func testCompleteCaptureSkipsUIMapWhenPreferenceIsDisabled() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let defaults = makeTestDefaults()
        let uiMapCaptureService = StubUIMapCaptureService(uiMap: makeTestUIMap())
        let model = retainForTestLifetime(AppModel(
            defaults: defaults,
            recoveryStore: store,
            uiMapCaptureService: uiMapCaptureService,
            shouldCheckCompatibilityOnLaunch: false
        ))
        model.autoCopyEnabled = false
        model.uiMapEnabled = false

        try model.completeCapture(
            makeCapturedScreenshot(image: makeCoordinateImage(width: 64, height: 48)),
            request: .region(CGRect(x: 0, y: 0, width: 64, height: 48)),
            isPrivateCapture: false
        )

        XCTAssertNil(model.editorController?.capture.uiMap)
        XCTAssertEqual(uiMapCaptureService.captureCallCount, 0)

        model.resetEditorSessionState()
        try? FileManager.default.removeItem(at: rootURL)
    }

    @MainActor
    func testCompleteCaptureDoesNotRecaptureExistingUIMap() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let defaults = makeTestDefaults()
        let existingUIMap = makeTestUIMap()
        let uiMapCaptureService = StubUIMapCaptureService(uiMap: UIMapSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_818_400_100),
            sourceRect: CGRect(x: 0, y: 0, width: 64, height: 48),
            elements: []
        ))
        let model = retainForTestLifetime(AppModel(
            defaults: defaults,
            recoveryStore: store,
            uiMapCaptureService: uiMapCaptureService,
            shouldCheckCompatibilityOnLaunch: false
        ))
        model.autoCopyEnabled = false
        model.uiMapEnabled = true

        try model.completeCapture(
            makeCapturedScreenshot(image: makeCoordinateImage(width: 64, height: 48), uiMap: existingUIMap),
            request: .region(CGRect(x: 0, y: 0, width: 64, height: 48)),
            isPrivateCapture: false
        )

        XCTAssertEqual(model.editorController?.capture.uiMap, existingUIMap)
        XCTAssertEqual(uiMapCaptureService.captureCallCount, 0)

        model.resetEditorSessionState()
        try? FileManager.default.removeItem(at: rootURL)
    }

    @MainActor
    func testCompleteCaptureShowsNoticeWhenRequestedUIMapIsUnavailable() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let defaults = makeTestDefaults()
        let uiMapCaptureService = StubUIMapCaptureService(uiMap: nil)
        let originalScreenRecordingStatusProvider = ScreenCapturePermissions.screenRecordingStatusProvider
        let originalAccessibilityStatusProvider = ScreenCapturePermissions.accessibilityStatusProvider
        defer {
            ScreenCapturePermissions.screenRecordingStatusProvider = originalScreenRecordingStatusProvider
            ScreenCapturePermissions.accessibilityStatusProvider = originalAccessibilityStatusProvider
            try? FileManager.default.removeItem(at: rootURL)
        }
        ScreenCapturePermissions.screenRecordingStatusProvider = { true }
        ScreenCapturePermissions.accessibilityStatusProvider = { false }

        let model = retainForTestLifetime(AppModel(
            defaults: defaults,
            recoveryStore: store,
            uiMapCaptureService: uiMapCaptureService,
            shouldCheckCompatibilityOnLaunch: false
        ))
        model.autoCopyEnabled = false
        model.uiMapEnabled = true

        try model.completeCapture(
            makeCapturedScreenshot(image: makeCoordinateImage(width: 64, height: 48)),
            request: .region(CGRect(x: 0, y: 0, width: 64, height: 48)),
            isPrivateCapture: false
        )

        XCTAssertNil(model.editorController?.capture.uiMap)
        XCTAssertEqual(uiMapCaptureService.captureCallCount, 1)
        XCTAssertEqual(
            model.editorController?.noticeMessage,
            "UI Map was not captured. Grant Accessibility access, then take the screenshot again."
        )

        model.resetEditorSessionState()
    }

    @MainActor
    func testPrivateCaptureSkipsArchiveSessionAndHistoryEntries() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let defaults = makeTestDefaults()
        let model = retainForTestLifetime(AppModel(defaults: defaults, recoveryStore: store, shouldCheckCompatibilityOnLaunch: false))
        model.autoCopyEnabled = false
        model.privateCaptureEnabled = true

        try model.completeCapture(
            makeCapturedScreenshot(image: makeCoordinateImage(width: 32, height: 24)),
            request: .region(CGRect(x: 0, y: 0, width: 32, height: 24)),
            isPrivateCapture: true
        )

        XCTAssertNotNil(model.editorController)
        XCTAssertNil(model.currentRecoverySessionID)
        XCTAssertTrue(store.allHistoryEntries().isEmpty)
        XCTAssertTrue(store.recycledHistoryEntries().isEmpty)

        model.resetEditorSessionState()
        try? FileManager.default.removeItem(at: rootURL)
    }

    @MainActor
    func testCompleteCaptureUsesLatchedPrivateCaptureState() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let defaults = makeTestDefaults()
        let model = retainForTestLifetime(AppModel(defaults: defaults, recoveryStore: store, shouldCheckCompatibilityOnLaunch: false))
        model.autoCopyEnabled = false
        model.privateCaptureEnabled = true

        try model.completeCapture(
            makeCapturedScreenshot(image: makeCoordinateImage(width: 32, height: 24)),
            request: .region(CGRect(x: 0, y: 0, width: 32, height: 24)),
            isPrivateCapture: false
        )

        XCTAssertNotNil(model.editorController)
        XCTAssertNotNil(model.currentRecoverySessionID)

        model.resetEditorSessionState()
        try? FileManager.default.removeItem(at: rootURL)
    }

    @MainActor
    func testPrivateCaptureCannotChangeWhilePrivacyLockIsActive() {
        let defaults = makeTestDefaults()
        let model = retainForTestLifetime(AppModel(defaults: defaults, shouldCheckCompatibilityOnLaunch: false))
        model.privateCaptureEnabled = false

        let latchedPrivateCapture = model.beginCapturePrivacyLock()
        model.updatePrivateCaptureEnabled(true)

        XCTAssertFalse(latchedPrivateCapture)
        XCTAssertFalse(model.privateCaptureEnabled)
        XCTAssertFalse(model.canChangePrivateCapture)
        XCTAssertNotNil(model.errorMessage)

        model.endCapturePrivacyLock()
        model.dismissError()
        model.updatePrivateCaptureEnabled(true)

        XCTAssertTrue(model.canChangePrivateCapture)
        XCTAssertTrue(model.privateCaptureEnabled)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testAppModelDoesNotPresentCancellationErrors() {
        let model = retainForTestLifetime(AppModel(defaults: makeTestDefaults(), shouldCheckCompatibilityOnLaunch: false))

        model.present(CancellationError())

        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testTransparentFillPersistsAcrossFreshCaptureControllers() {
        let defaults = makeTestDefaults()
        let capture = makeCapturedScreenshot(image: makeCoordinateImage(width: 160, height: 120))
        let controller = retainForTestLifetime(EditorController(capture: capture, defaults: defaults))
        controller.activeTool = .rectangle

        controller.updateFillColor(.clear)

        XCTAssertEqual(defaults.string(forKey: "editor.lastFillColorID"), "transparent")
        XCTAssertEqual(controller.inspectorStyle.fillColor, .clear)

        let reloaded = retainForTestLifetime(EditorController(capture: capture, defaults: defaults))
        reloaded.activeTool = .rectangle

        XCTAssertEqual(reloaded.inspectorStyle.fillColor, .clear)
    }

    @MainActor
    func testSwitchingFromTransparentFillToOpaqueColorRestoresVisibleFill() {
        let defaults = makeTestDefaults()
        let capture = makeCapturedScreenshot(image: makeCoordinateImage(width: 160, height: 120))
        let controller = retainForTestLifetime(EditorController(capture: capture, defaults: defaults))
        controller.activeTool = .rectangle

        controller.updateFillColor(.clear)
        controller.updateFillColor(.highlightFill)

        XCTAssertEqual(controller.inspectorStyle.fillColor, .highlightFill)

        let reloaded = retainForTestLifetime(EditorController(capture: capture, defaults: defaults))
        reloaded.activeTool = .rectangle

        XCTAssertEqual(reloaded.inspectorStyle.fillColor, .highlightFill)
    }

    func testPaletteOptionsExposeSingleWhiteAndTrailingTransparentSwatch() {
        XCTAssertEqual(RGBAColor.paletteOptions.filter { $0.label == "White" }.count, 1)
        XCTAssertEqual(RGBAColor.paletteOptions.last?.id, "transparent")
        XCTAssertTrue(RGBAColor.paletteOptions.last?.showsCheckerboard == true)
    }

    func testUndoRedoRestoresSnapshotAndRevision() {
        let controller = makeController()
        let annotation = Annotation.makeRectangle(in: CGRect(x: 20, y: 30, width: 60, height: 40))

        controller.addAnnotation(annotation)
        XCTAssertEqual(controller.snapshot.annotations.map(\ .id), [annotation.id])
        XCTAssertEqual(controller.persistenceRevision, 1)

        controller.undo()
        XCTAssertTrue(controller.snapshot.annotations.isEmpty)
        XCTAssertEqual(controller.persistenceRevision, 2)

        controller.redo()
        XCTAssertEqual(controller.snapshot.annotations.map(\ .id), [annotation.id])
        XCTAssertEqual(controller.persistenceRevision, 3)
    }

    @MainActor
    func testTypingAfterSelectingArrowPlacesTextNearTailAwayFromHead() {
        let arrow = Annotation.makeArrow(from: CGPoint(x: 320, y: 160), to: CGPoint(x: 450, y: 160))
        let snapshot = makeEditorSnapshot(
            cropRect: CGRect(x: 0, y: 0, width: 600, height: 400),
            annotations: [arrow],
            selectedAnnotationIDs: [arrow.id]
        )
        let controller = makeController(snapshot: snapshot)

        controller.beginTextAnnotation(with: "Label")

        guard let text = controller.selectedAnnotation,
              case let .text(shape) = text.kind
        else {
            return XCTFail("Expected new text annotation")
        }

        XCTAssertLessThan(shape.rect.maxX, 320)
        XCTAssertTrue(snapshot.cropRect.contains(shape.rect))
    }

    @MainActor
    func testTypingAfterSelectingArrowKeepsTextInsideCropNearTail() {
        let arrow = Annotation.makeArrow(from: CGPoint(x: 18, y: 100), to: CGPoint(x: 180, y: 100))
        let snapshot = makeEditorSnapshot(
            cropRect: CGRect(x: 0, y: 0, width: 320, height: 220),
            annotations: [arrow],
            selectedAnnotationIDs: [arrow.id]
        )
        let controller = makeController(snapshot: snapshot)

        controller.beginTextAnnotation(with: "Label")

        guard let text = controller.selectedAnnotation,
              case let .text(shape) = text.kind
        else {
            return XCTFail("Expected new text annotation")
        }

        XCTAssertTrue(snapshot.cropRect.contains(shape.rect))
        XCTAssertLessThan(abs(shape.rect.midY - 100), 100)
        XCTAssertLessThan(abs(shape.rect.midX - 18), 170)
    }

    @MainActor
    func testBackspaceWhileEditingNewTextAnnotationRemovesCharacterNotAnnotation() {
        let controller = makeController()
        let (_, overlay, window) = makeCanvasHarness(
            controller: controller,
            frame: CGRect(x: 0, y: 0, width: 640, height: 480)
        )

        controller.beginTextAnnotation(with: "AB")

        guard let annotationID = controller.selectedAnnotation?.id else {
            return XCTFail("Expected selected text annotation")
        }

        sendKeyEvent(.keyDown, keyCode: 51, characters: String(UnicodeScalar(NSBackspaceCharacter)!), to: overlay, in: window)

        XCTAssertEqual(controller.selectedText, "A")
        XCTAssertEqual(controller.snapshot.annotations.map(\.id), [annotationID])
        XCTAssertEqual(controller.snapshot.selectedAnnotationIDs, [annotationID])
    }

    @MainActor
    func testPersistentCropHandlesAdjustCropWithoutCropToolSelection() {
        let controller = makeController(
            snapshot: makeEditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: 160, height: 120)),
            captureSize: CGSize(width: 160, height: 120)
        )
        let (_, overlay, window) = makeCanvasHarness(
            controller: controller,
            frame: CGRect(x: 0, y: 0, width: 640, height: 480)
        )

        let crop = controller.snapshot.cropRect.gscIntegralStandardized
        let bottomRightHandle = cropHandleViewPoint(for: .bottomRight, cropRect: crop, controller: controller)
        let resizedPoint = viewPoint(for: CGPoint(x: 120, y: 90), controller: controller)

        sendMouseEvent(.leftMouseDown, at: bottomRightHandle, to: overlay, in: window, eventNumber: 1)
        sendMouseEvent(.leftMouseDragged, at: resizedPoint, to: overlay, in: window, eventNumber: 2)
        sendMouseEvent(.leftMouseUp, at: resizedPoint, to: overlay, in: window, eventNumber: 3)

        XCTAssertEqual(controller.activeTool, .select)
        XCTAssertEqual(controller.snapshot.cropRect, CGRect(x: 0, y: 0, width: 120, height: 90))
    }

    @MainActor
    func testSelectToolCanMoveCropWithoutResizing() {
        let originalCrop = CGRect(x: 20, y: 15, width: 80, height: 60)
        let controller = makeController(
            snapshot: makeEditorSnapshot(cropRect: originalCrop),
            captureSize: CGSize(width: 160, height: 120)
        )
        let (_, overlay, window) = makeCanvasHarness(
            controller: controller,
            frame: CGRect(x: 0, y: 0, width: 640, height: 480)
        )

        XCTAssertEqual(controller.activeTool, .select)

        let dragStart = viewPoint(for: CGPoint(x: originalCrop.midX, y: originalCrop.midY), controller: controller)
        let dragEnd = viewPoint(for: CGPoint(x: originalCrop.midX + 20, y: originalCrop.midY + 15), controller: controller)

        sendMouseEvent(.leftMouseDown, at: dragStart, to: overlay, in: window, eventNumber: 1)
        sendMouseEvent(.leftMouseDragged, at: dragEnd, to: overlay, in: window, eventNumber: 2)
        sendMouseEvent(.leftMouseUp, at: dragEnd, to: overlay, in: window, eventNumber: 3)

        XCTAssertEqual(controller.snapshot.cropRect, CGRect(x: 40, y: 30, width: 80, height: 60))

        controller.undo()
        XCTAssertEqual(controller.snapshot.cropRect, originalCrop)
    }

    @MainActor
    func testCropHandleResizePreviewsCropBeforeMouseUpAndCommitsSingleUndoStep() {
        let controller = makeController(
            snapshot: makeEditorSnapshot(cropRect: CGRect(x: 20, y: 15, width: 80, height: 60)),
            captureSize: CGSize(width: 160, height: 120)
        )
        let (_, overlay, window) = makeCanvasHarness(
            controller: controller,
            frame: CGRect(x: 0, y: 0, width: 640, height: 480)
        )

        let crop = controller.snapshot.cropRect.gscIntegralStandardized
        let bottomRightHandle = cropHandleViewPoint(for: .bottomRight, cropRect: crop, controller: controller)
        let expandedPoint = viewPoint(for: CGPoint(x: 140, y: 100), controller: controller)

        sendMouseEvent(.leftMouseDown, at: bottomRightHandle, to: overlay, in: window, eventNumber: 1)
        sendMouseEvent(.leftMouseDragged, at: expandedPoint, to: overlay, in: window, eventNumber: 2)

        XCTAssertEqual(controller.snapshot.cropRect, CGRect(x: 20, y: 15, width: 120, height: 85))

        sendMouseEvent(.leftMouseUp, at: expandedPoint, to: overlay, in: window, eventNumber: 3)

        XCTAssertTrue(controller.canUndo)
        XCTAssertTrue(controller.viewport.canScrollHorizontally)
        XCTAssertTrue(controller.viewport.canScrollVertically)
        controller.undo()
        XCTAssertEqual(controller.snapshot.cropRect, CGRect(x: 20, y: 15, width: 80, height: 60))
    }

    @MainActor
    func testCropHandleResizeHonorsFixedAspectRatioPreset() {
        let controller = makeController(
            snapshot: makeEditorSnapshot(cropRect: CGRect(x: 20, y: 15, width: 80, height: 60)),
            captureSize: CGSize(width: 200, height: 160)
        )
        controller.cropAspectRatioPreset = .square
        let (_, overlay, window) = makeCanvasHarness(
            controller: controller,
            frame: CGRect(x: 0, y: 0, width: 800, height: 640)
        )

        let crop = controller.snapshot.cropRect.gscIntegralStandardized
        let bottomRightHandle = cropHandleViewPoint(for: .bottomRight, cropRect: crop, controller: controller)
        let expandedPoint = viewPoint(for: CGPoint(x: 140, y: 100), controller: controller)

        sendMouseEvent(.leftMouseDown, at: bottomRightHandle, to: overlay, in: window, eventNumber: 1)
        sendMouseEvent(.leftMouseDragged, at: expandedPoint, to: overlay, in: window, eventNumber: 2)

        XCTAssertEqual(controller.snapshot.cropRect, CGRect(x: 20, y: 15, width: 85, height: 85))

        sendMouseEvent(.leftMouseUp, at: expandedPoint, to: overlay, in: window, eventNumber: 3)
        XCTAssertEqual(controller.snapshot.cropRect, CGRect(x: 20, y: 15, width: 85, height: 85))
    }

    @MainActor
    func testPersistentCropHandlesCanExpandExistingCropBackOutward() {
        let controller = makeController(
            snapshot: makeEditorSnapshot(cropRect: CGRect(x: 20, y: 15, width: 80, height: 60)),
            captureSize: CGSize(width: 160, height: 120)
        )
        let (_, overlay, window) = makeCanvasHarness(
            controller: controller,
            frame: CGRect(x: 0, y: 0, width: 640, height: 480)
        )

        let crop = controller.snapshot.cropRect.gscIntegralStandardized
        let bottomRightHandle = cropHandleViewPoint(for: .bottomRight, cropRect: crop, controller: controller)
        let expandedPoint = viewPoint(for: CGPoint(x: 140, y: 100), controller: controller)

        sendMouseEvent(.leftMouseDown, at: bottomRightHandle, to: overlay, in: window, eventNumber: 1)
        sendMouseEvent(.leftMouseDragged, at: expandedPoint, to: overlay, in: window, eventNumber: 2)
        sendMouseEvent(.leftMouseUp, at: expandedPoint, to: overlay, in: window, eventNumber: 3)

        XCTAssertEqual(controller.snapshot.cropRect, CGRect(x: 20, y: 15, width: 120, height: 85))
        XCTAssertEqual(controller.viewport.contentSize, CGSize(width: 160, height: 120))
    }

    @MainActor
    func testCommitPreviewedCropRectRefitsViewportToCommittedCrop() {
        let controller = makeController(
            snapshot: makeEditorSnapshot(cropRect: CGRect(x: 20, y: 15, width: 80, height: 60)),
            captureSize: CGSize(width: 160, height: 120)
        )
        let initialImageRect = controller.viewport.imageRect

        controller.previewCropRect(CGRect(x: 20, y: 15, width: 120, height: 85))

        XCTAssertEqual(controller.viewport.imageRect, initialImageRect)

        controller.commitPreviewedCropRect(
            CGRect(x: 20, y: 15, width: 120, height: 85),
            originalRect: CGRect(x: 20, y: 15, width: 80, height: 60)
        )

        XCTAssertEqual(controller.snapshot.cropRect, CGRect(x: 20, y: 15, width: 120, height: 85))
        XCTAssertGreaterThan(controller.viewport.imageRect.width, initialImageRect.width)
        XCTAssertGreaterThan(controller.viewport.imageRect.height, initialImageRect.height)
    }

    @MainActor
    func testInitialDisplayRefocusesExistingCropInsteadOfFittingFullImage() {
        let controller = makeController(
            snapshot: makeEditorSnapshot(cropRect: CGRect(x: 20, y: 15, width: 120, height: 85)),
            captureSize: CGSize(width: 160, height: 120)
        )
        controller.updateViewportCanvasSize(CGSize(width: 640, height: 480))
        let initialImageRect = controller.viewport.imageRect

        controller.zoomToInitialDisplayScale()

        let cropDisplayRect = viewRect(for: controller.snapshot.cropRect, controller: controller)

        XCTAssertGreaterThan(controller.viewport.imageRect.width, initialImageRect.width)
        XCTAssertGreaterThan(controller.viewport.imageRect.height, initialImageRect.height)
        XCTAssertTrue(controller.viewport.canScrollHorizontally)
        XCTAssertTrue(controller.viewport.canScrollVertically)
        XCTAssertEqual(cropDisplayRect.midX, 320, accuracy: 0.001)
        XCTAssertEqual(cropDisplayRect.midY, 240, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(cropDisplayRect.minX, EditorViewport.interactionInset - 0.001)
        XCTAssertGreaterThanOrEqual(cropDisplayRect.minY, EditorViewport.interactionInset - 0.001)
        XCTAssertLessThanOrEqual(cropDisplayRect.maxX, 640 - EditorViewport.interactionInset + 0.001)
        XCTAssertLessThanOrEqual(cropDisplayRect.maxY, 480 - EditorViewport.interactionInset + 0.001)
    }

    @MainActor
    func testFocusedCropShowsCommittedCropChromeWhenScrollable() {
        let controller = makeController(
            snapshot: makeEditorSnapshot(cropRect: CGRect(x: 20, y: 15, width: 120, height: 85)),
            captureSize: CGSize(width: 160, height: 120)
        )
        let (canvas, _, _) = makeCanvasHarness(
            controller: controller,
            frame: CGRect(x: 0, y: 0, width: 640, height: 480)
        )

        controller.zoomToInitialDisplayScale()
        canvas.refreshCanvasDisplay()

        guard let presentation = canvas.debugCommittedCropPresentation else {
            return XCTFail("Expected committed crop presentation state")
        }

        let expectedCropRect = viewRect(for: controller.snapshot.cropRect, controller: controller).integral

        XCTAssertTrue(controller.viewport.canScrollHorizontally)
        XCTAssertTrue(controller.viewport.canScrollVertically)
        XCTAssertTrue(presentation.showsFocusedCropChrome)
        XCTAssertEqual(presentation.overlayAlpha, AppModel.defaultEditorCropOutsideOverlayAlpha, accuracy: 0.001)
        XCTAssertEqual(presentation.cropRect, expectedCropRect)
    }

    @MainActor
    func testFocusedCropChromeUsesConfiguredOverlayAlpha() {
        let controller = makeController(
            snapshot: makeEditorSnapshot(cropRect: CGRect(x: 20, y: 15, width: 120, height: 85)),
            captureSize: CGSize(width: 160, height: 120)
        )
        let (canvas, _, _) = makeCanvasHarness(
            controller: controller,
            frame: CGRect(x: 0, y: 0, width: 640, height: 480)
        )

        controller.updateCropOutsideOverlayAlpha(0.32)
        controller.zoomToInitialDisplayScale()
        canvas.refreshCanvasDisplay()

        guard let presentation = canvas.debugCommittedCropPresentation else {
            return XCTFail("Expected committed crop presentation state")
        }

        XCTAssertEqual(presentation.overlayAlpha, 0.32, accuracy: 0.001)
    }

    @MainActor
    func testFocusedCropShowsCommittedCropChromeWhenNotScrollable() {
        let controller = makeController(
            snapshot: makeEditorSnapshot(cropRect: CGRect(x: 20, y: 15, width: 120, height: 85)),
            captureSize: CGSize(width: 160, height: 120)
        )
        let (canvas, _, _) = makeCanvasHarness(
            controller: controller,
            frame: CGRect(x: 0, y: 0, width: 320, height: 240)
        )

        controller.zoomToFit()
        canvas.refreshCanvasDisplay()

        guard let presentation = canvas.debugCommittedCropPresentation else {
            return XCTFail("Expected committed crop presentation state")
        }

        XCTAssertTrue(presentation.showsFocusedCropChrome)
        XCTAssertEqual(presentation.overlayAlpha, AppModel.defaultEditorCropOutsideOverlayAlpha, accuracy: 0.001)
        XCTAssertGreaterThan(controller.viewport.zoomScale, 1, "Zoomed fit should focus on the cropped area, not the full image")
    }

    @MainActor
    func testCropHandlesStayOnCroppedPerimeterAfterViewportRefocus() {
        let controller = makeController(
            snapshot: makeEditorSnapshot(cropRect: CGRect(x: 20, y: 15, width: 120, height: 85)),
            captureSize: CGSize(width: 160, height: 120)
        )
        let _ = makeCanvasHarness(
            controller: controller,
            frame: CGRect(x: 0, y: 0, width: 640, height: 480)
        )

        let crop = controller.snapshot.cropRect.gscIntegralStandardized
        let bottomHandle = cropHandleViewPoint(for: .bottom, cropRect: crop, controller: controller)
        let expectedBottomHandle = viewPoint(for: CGPoint(x: crop.midX, y: crop.maxY), controller: controller)
        let rightHandle = cropHandleViewPoint(for: .right, cropRect: crop, controller: controller)
        let expectedRightHandle = viewPoint(for: CGPoint(x: crop.maxX, y: crop.midY), controller: controller)

        XCTAssertEqual(bottomHandle.x, expectedBottomHandle.x, accuracy: 0.001)
        XCTAssertEqual(bottomHandle.y, expectedBottomHandle.y, accuracy: 0.001)
        XCTAssertEqual(rightHandle.x, expectedRightHandle.x, accuracy: 0.001)
        XCTAssertEqual(rightHandle.y, expectedRightHandle.y, accuracy: 0.001)
    }

    @MainActor
    func testCanResetCropTracksWhetherCropDiffersFromFullImage() {
        let controller = makeController(
            snapshot: makeEditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: 160, height: 120)),
            captureSize: CGSize(width: 160, height: 120)
        )

        XCTAssertFalse(controller.canResetCrop)

        controller.updateCropRect(CGRect(x: 10, y: 10, width: 100, height: 80))

        XCTAssertTrue(controller.canResetCrop)

        controller.resetCrop()

        XCTAssertFalse(controller.canResetCrop)
    }

    @MainActor
    private func makeController(
        snapshot: EditorSnapshot? = nil,
        capture: CapturedScreenshot? = nil,
        captureSize: CGSize? = nil,
        defaults: UserDefaults = .standard,
        textRecognizer: any CaptureTextRecognizing = VisionCaptureTextRecognizer()
    ) -> EditorController {
        let resolvedSnapshot = snapshot ?? makeEditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: 160, height: 120))
        let resolvedCapture = capture ?? makeCapturedScreenshot(
            image: makeCoordinateImage(
                width: max(Int((captureSize?.width ?? resolvedSnapshot.cropRect.width).rounded()), 1),
                height: max(Int((captureSize?.height ?? resolvedSnapshot.cropRect.height).rounded()), 1)
            )
        )
        let session = makeEditorDocumentSession(initialSnapshot: resolvedSnapshot, currentSnapshot: resolvedSnapshot)
        return retainForTestLifetime(EditorController(capture: resolvedCapture, session: session, defaults: defaults, textRecognizer: textRecognizer))
    }

    @MainActor
    private func waitForOCR(_ controller: EditorController, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<100 where controller.isRecognizingOCR || controller.ocrReviewText == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        if controller.isRecognizingOCR {
            XCTFail("Timed out waiting for OCR", file: file, line: line)
        }
    }

    private func makeTestDefaults() -> UserDefaults {
        let suiteName = "EditorControllerTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Expected test defaults suite")
        }

        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @MainActor
    private func makeCanvasHarness(controller: EditorController, frame: CGRect) -> (AnnotationCanvasView, NSView, NSWindow) {
        let canvas = retainForTestLifetime(AnnotationCanvasView(controller: controller))
        let window = retainForTestLifetime(NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false))
        window.contentView = canvas
        canvas.frame = window.contentView?.bounds ?? frame
        canvas.layoutSubtreeIfNeeded()

        guard let overlay = canvas.subviews.last else {
            fatalError("Expected annotation overlay view")
        }

        return (canvas, overlay, window)
    }

    private func viewPoint(for documentPoint: CGPoint, controller: EditorController) -> CGPoint {
        let rect = viewRect(for: CGRect(origin: documentPoint, size: .zero), controller: controller)
        return rect.origin
    }

    private func viewRect(for documentRect: CGRect, controller: EditorController) -> CGRect {
        let canvasRect = controller.viewport.imageRect
        let documentBounds = CGRect(origin: .zero, size: CGSize(width: controller.capture.image.width, height: controller.capture.image.height))
        let origin = CGPoint(
            x: canvasRect.minX + ((documentRect.minX - documentBounds.minX) / documentBounds.width) * canvasRect.width,
            y: canvasRect.minY + ((documentRect.minY - documentBounds.minY) / documentBounds.height) * canvasRect.height
        )

        return CGRect(
            x: origin.x,
            y: origin.y,
            width: (documentRect.width / documentBounds.width) * canvasRect.width,
            height: (documentRect.height / documentBounds.height) * canvasRect.height
        )
    }

    private func cropHandleViewPoint(for handle: ResizeHandle, cropRect: CGRect, controller: EditorController) -> CGPoint {
        let canvasRect = controller.viewport.imageRect
        let documentBounds = CGRect(origin: .zero, size: CGSize(width: controller.capture.image.width, height: controller.capture.image.height))
        let viewCropRect = CGRect(
            x: canvasRect.minX + ((cropRect.minX - documentBounds.minX) / documentBounds.width) * canvasRect.width,
            y: canvasRect.minY + ((cropRect.minY - documentBounds.minY) / documentBounds.height) * canvasRect.height,
            width: (cropRect.width / documentBounds.width) * canvasRect.width,
            height: (cropRect.height / documentBounds.height) * canvasRect.height
        )
        let point: CGPoint

        switch handle {
        case .topLeft:
            point = CGPoint(x: viewCropRect.minX, y: viewCropRect.minY)
        case .top:
            point = CGPoint(x: viewCropRect.midX, y: viewCropRect.minY)
        case .topRight:
            point = CGPoint(x: viewCropRect.maxX, y: viewCropRect.minY)
        case .right:
            point = CGPoint(x: viewCropRect.maxX, y: viewCropRect.midY)
        case .bottomRight:
            point = CGPoint(x: viewCropRect.maxX, y: viewCropRect.maxY)
        case .bottom:
            point = CGPoint(x: viewCropRect.midX, y: viewCropRect.maxY)
        case .bottomLeft:
            point = CGPoint(x: viewCropRect.minX, y: viewCropRect.maxY)
        case .left:
            point = CGPoint(x: viewCropRect.minX, y: viewCropRect.midY)
        }

        return point
    }

    private func sendMouseEvent(
        _ type: NSEvent.EventType,
        at point: CGPoint,
        to view: NSView,
        in window: NSWindow,
        eventNumber: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let windowPoint = view.convert(point, to: nil)

        guard let event = NSEvent.mouseEvent(
            with: type,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: 1,
            pressure: 1
        ) else {
            XCTFail("Expected mouse event", file: file, line: line)
            return
        }

        switch type {
        case .leftMouseDown:
            view.mouseDown(with: event)
        case .leftMouseDragged:
            view.mouseDragged(with: event)
        case .leftMouseUp:
            view.mouseUp(with: event)
        default:
            XCTFail("Unsupported mouse event type", file: file, line: line)
        }
    }

    private func sendKeyEvent(
        _ type: NSEvent.EventType,
        keyCode: UInt16,
        characters: String,
        to view: NSView,
        in window: NSWindow,
        modifiers: NSEvent.ModifierFlags = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let event = NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            XCTFail("Expected key event", file: file, line: line)
            return
        }

        switch type {
        case .keyDown:
            view.keyDown(with: event)
        case .keyUp:
            view.keyUp(with: event)
        default:
            XCTFail("Unsupported key event type", file: file, line: line)
        }
    }

    @MainActor
    private func renderView(_ view: NSView) -> CGImage? {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds.integral
        let width = max(Int(bounds.width), 1)
        let height = max(Int(bounds.height), 1)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ),
        let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return nil
        }

        rep.size = bounds.size
        context.imageInterpolation = .none

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        view.displayIgnoringOpacity(bounds, in: context)
        NSGraphicsContext.restoreGraphicsState()

        return rep.cgImage
    }
}

nonisolated private final class StubTextRecognizer: CaptureTextRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private let text: String
    private var imageSize: CGSize?

    init(text: String) {
        self.text = text
    }

    var lastImageSize: CGSize? {
        lock.lock()
        defer { lock.unlock() }
        return imageSize
    }

    nonisolated func recognizeText(in image: CGImage) throws -> String {
        lock.lock()
        imageSize = CGSize(width: image.width, height: image.height)
        lock.unlock()
        return text
    }
}

@MainActor
private final class StubUIMapCaptureService: UIMapCaptureServiceType {
    private let uiMap: UIMapSnapshot?
    private(set) var captureCallCount = 0

    init(uiMap: UIMapSnapshot?) {
        self.uiMap = uiMap
    }

    func captureUIMap(for capture: CapturedScreenshot) -> UIMapSnapshot? {
        captureCallCount += 1
        return uiMap
    }
}

private func makeTestUIMap() -> UIMapSnapshot {
    UIMapSnapshot(
        capturedAt: Date(timeIntervalSince1970: 1_818_400_000),
        sourceRect: CGRect(x: 0, y: 0, width: 64, height: 48),
        elements: [
            UIMapElement(
                name: "Save",
                accessibilityLabel: "Save Document",
                accessibilityIdentifier: "save-button",
                role: "AXButton",
                roleDescription: "Button",
                documentRect: CGRect(x: 8, y: 10, width: 24, height: 12),
                owningApplication: "Fixture"
            )
        ]
    )
}

private func makeBGRACoordinateImage(width: Int, height: Int) -> CGImage {
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * bytesPerRow) + (x * bytesPerPixel)
            pixels[offset] = UInt8(truncatingIfNeeded: x + y)
            pixels[offset + 1] = UInt8(truncatingIfNeeded: y)
            pixels[offset + 2] = UInt8(truncatingIfNeeded: x)
            pixels[offset + 3] = 255
        }
    }

    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)),
        provider: CGDataProvider(data: Data(pixels) as CFData)!,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}
