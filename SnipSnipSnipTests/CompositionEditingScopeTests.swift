import Foundation
import Combine
import XCTest
@testable import SnipSnipSnip

final class CompositionEditingScopeTests: XCTestCase {
    @MainActor
    func testEnteringItemEditingProjectsItemWithoutOverwritingItWithRootEdits() throws {
        let rootAnnotation = Annotation.makeRectangle(
            in: CGRect(x: 2, y: 3, width: 12, height: 10)
        )
        let itemAnnotation = Annotation.makeEllipse(
            in: CGRect(x: 15, y: 8, width: 18, height: 14)
        )
        let fixture = try makeController(
            rootAnnotations: [rootAnnotation],
            itemAnnotationSets: [[itemAnnotation], []]
        )

        fixture.controller.enterCompositionItemEditing(fixture.itemIDs[0])

        XCTAssertEqual(
            fixture.controller.snapshot.annotations.map(\.id),
            [itemAnnotation.id]
        )
        XCTAssertEqual(
            fixture.controller.editableDocument.session.currentSnapshot.annotations.map(\.id),
            [rootAnnotation.id]
        )
        XCTAssertEqual(
            fixture.controller.composition?.items[0].editState.annotations.map(\.id),
            [itemAnnotation.id]
        )
    }

    @MainActor
    func testItemEditsUndoRedoAndFinishRemainInItemScope() throws {
        let rootAnnotation = Annotation.makeRectangle(
            in: CGRect(x: 2, y: 3, width: 12, height: 10)
        )
        let itemAnnotation = Annotation.makeEllipse(
            in: CGRect(x: 15, y: 8, width: 18, height: 14)
        )
        let addedAnnotation = Annotation.makeArrow(
            from: CGPoint(x: 4, y: 5),
            to: CGPoint(x: 30, y: 20)
        )
        let fixture = try makeController(
            rootAnnotations: [rootAnnotation],
            itemAnnotationSets: [[itemAnnotation], []]
        )
        fixture.controller.enterCompositionItemEditing(fixture.itemIDs[0])

        fixture.controller.addAnnotation(addedAnnotation)
        XCTAssertEqual(
            Set(fixture.controller.snapshot.annotations.map(\.id)),
            Set([itemAnnotation.id, addedAnnotation.id])
        )

        fixture.controller.undo()
        XCTAssertEqual(
            fixture.controller.snapshot.annotations.map(\.id),
            [itemAnnotation.id]
        )

        fixture.controller.redo()
        fixture.controller.finishCompositionEditing()

        XCTAssertEqual(fixture.controller.compositionEditingScope, .layout)
        XCTAssertEqual(fixture.controller.workspaceMode, .presentation)
        XCTAssertEqual(
            Set(fixture.controller.composition?.items[0].editState.annotations.map(\.id) ?? []),
            Set([itemAnnotation.id, addedAnnotation.id])
        )
        XCTAssertEqual(
            fixture.controller.snapshot.annotations.map(\.id),
            [rootAnnotation.id]
        )
    }

    @MainActor
    func testEnteringCompositionEditingProjectsOnlyCanvasAnnotations() throws {
        let rootAnnotation = Annotation.makeRectangle(
            in: CGRect(x: 2, y: 3, width: 12, height: 10)
        )
        let canvasAnnotation = Annotation.makeArrow(
            from: CGPoint(x: 8, y: 8),
            to: CGPoint(x: 40, y: 24)
        )
        let fixture = try makeController(
            rootAnnotations: [rootAnnotation],
            itemAnnotationSets: [[], []],
            canvasAnnotations: [canvasAnnotation]
        )

        fixture.controller.enterCompositionEditing()

        XCTAssertEqual(fixture.controller.compositionEditingScope, .composition)
        XCTAssertEqual(
            fixture.controller.snapshot.annotations.map(\.id),
            [canvasAnnotation.id]
        )
        XCTAssertEqual(
            fixture.controller.editableDocument.session.currentSnapshot.annotations.map(\.id),
            [rootAnnotation.id]
        )
        XCTAssertEqual(
            fixture.controller.composition?.canvas.annotations.map(\.id),
            [canvasAnnotation.id]
        )
    }

    @MainActor
    func testPreviousNextCommitsCurrentItemBeforeProjectingNextItem() throws {
        let firstAnnotation = Annotation.makeRectangle(
            in: CGRect(x: 3, y: 4, width: 10, height: 10)
        )
        let secondAnnotation = Annotation.makeEllipse(
            in: CGRect(x: 18, y: 9, width: 12, height: 12)
        )
        let addedAnnotation = Annotation.makeLine(
            from: CGPoint(x: 1, y: 1),
            to: CGPoint(x: 20, y: 12)
        )
        let fixture = try makeController(
            rootAnnotations: [],
            itemAnnotationSets: [[firstAnnotation], [secondAnnotation]]
        )
        fixture.controller.enterCompositionItemEditing(fixture.itemIDs[0])
        fixture.controller.addAnnotation(addedAnnotation)

        fixture.controller.selectNextCompositionItemForEditing()

        XCTAssertEqual(
            fixture.controller.compositionEditingScope,
            .item(fixture.itemIDs[1])
        )
        XCTAssertEqual(
            fixture.controller.snapshot.annotations.map(\.id),
            [secondAnnotation.id]
        )
        XCTAssertEqual(
            Set(fixture.controller.composition?.items[0].editState.annotations.map(\.id) ?? []),
            Set([firstAnnotation.id, addedAnnotation.id])
        )
        XCTAssertEqual(
            fixture.controller.composition?.items[1].editState.annotations.map(\.id),
            [secondAnnotation.id]
        )
    }

    @MainActor
    func testNewCrossPanelArrowAnchorsEndpointsIndependentlyAndCanPinToCanvas() throws {
        let fixture = try makeController(
            rootAnnotations: [],
            itemAnnotationSets: [[], []]
        )
        let layout = try fixture.controller.currentCompositionRenderLayout()
        let firstLayout = try XCTUnwrap(
            layout.itemLayout(for: fixture.itemIDs[0])
        )
        let secondLayout = try XCTUnwrap(
            layout.itemLayout(for: fixture.itemIDs[1])
        )
        let arrow = Annotation.makeArrow(
            from: CGPoint(
                x: firstLayout.imageClipRect.midX,
                y: firstLayout.imageClipRect.midY
            ),
            to: CGPoint(
                x: secondLayout.imageClipRect.midX,
                y: secondLayout.imageClipRect.midY
            )
        )

        fixture.controller.enterCompositionEditing()
        fixture.controller.addAnnotation(arrow)

        let itemAnchors = try XCTUnwrap(
            fixture.controller.composition?.canvas
                .annotationAnchors[arrow.id]
        )
        guard case .itemNormalized(let primaryItemID, _) =
                itemAnchors.primary.target,
              case .itemNormalized(let secondaryItemID, _) =
                itemAnchors.secondary?.target else {
            return XCTFail(
                "A cross-panel arrow should retain one stable source anchor per endpoint."
            )
        }
        XCTAssertEqual(primaryItemID, fixture.itemIDs[0])
        XCTAssertEqual(secondaryItemID, fixture.itemIDs[1])

        fixture.controller.pinSelectedCompositionAnnotationsToCanvas()

        let canvasAnchors = try XCTUnwrap(
            fixture.controller.composition?.canvas
                .annotationAnchors[arrow.id]
        )
        guard case .canvasNormalized = canvasAnchors.primary.target,
              case .canvasNormalized = canvasAnchors.secondary?.target else {
            return XCTFail(
                "Pin Selection to Canvas should detach both endpoints from item identities."
            )
        }

        fixture.controller.undo()
        XCTAssertEqual(
            fixture.controller.composition?.canvas
                .annotationAnchors[arrow.id],
            itemAnchors
        )
    }

    @MainActor
    func testDeterministicUISmokeFixtureCanEnterCompositionEditingAfterEveryLayout() throws {
        let defaults = try XCTUnwrap(
            UserDefaults(
                suiteName: "CompositionEditingScopeTests.UIFixture.\(UUID().uuidString)"
            )
        )
        let controller = EditorController(
            capture: CompositionUITestFixture.capture(ordinal: 0),
            defaults: defaults,
            capabilities: testCapabilities
        )
        try controller.appendCaptureToComposition(
            CompositionUITestFixture.capture(ordinal: 1),
            isPrivate: false
        )

        for mode in [
            CompositionLayoutMode.auto,
            .compare,
            .steps,
            .row,
            .column,
            .grid,
            .freeform,
        ] {
            controller.setCompositionLayout(mode)
        }
        controller.setCompositionLayout(.compare)
        controller.enterCompositionEditing()

        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(controller.compositionEditingScope, .composition)
        XCTAssertEqual(controller.workspaceMode, .edit)
    }

    @MainActor
    func testDoneRestoresPresentationViewportInspectorTabAndScrollPosition() throws {
        let fixture = try makeController(
            rootAnnotations: [],
            itemAnnotationSets: [[], []]
        )
        let controller = fixture.controller
        controller.setWorkspaceMode(.presentation)
        controller.presentationInspectorTab = .layout
        controller.compositionInspectorScrollPosition = "composition.items"
        controller.updateViewportCanvasSize(CGSize(width: 900, height: 640))
        controller.updatePresentationViewportContentSize(
            CGSize(width: 1_400, height: 900)
        )
        controller.zoomIn()
        controller.panViewport(by: CGSize(width: 37, height: -24))
        let originalViewport = controller.viewport

        controller.enterCompositionEditing()
        controller.zoomToFit()
        controller.presentationInspectorTab = .style
        controller.compositionInspectorScrollPosition = nil
        controller.finishCompositionEditing()

        XCTAssertEqual(controller.viewport, originalViewport)
        XCTAssertEqual(controller.presentationInspectorTab, .layout)
        XCTAssertEqual(
            controller.compositionInspectorScrollPosition,
            "composition.items"
        )
    }

    @MainActor
    func testPresentationBackEntersCompositionEditingAndDoneReturnsToLayout() throws {
        let fixture = try makeController(
            rootAnnotations: [],
            itemAnnotationSets: [[], []]
        )
        let controller = fixture.controller
        controller.setWorkspaceMode(.presentation)
        controller.presentationInspectorTab = .scene

        XCTAssertTrue(controller.isDocumentOutputAvailable)
        controller.enterCompositionEditingFromPresentation()

        XCTAssertEqual(controller.compositionEditingScope, .composition)
        XCTAssertEqual(controller.workspaceMode, .edit)
        XCTAssertFalse(controller.isDocumentOutputAvailable)

        controller.finishCompositionEditing()

        XCTAssertEqual(controller.compositionEditingScope, .layout)
        XCTAssertEqual(controller.workspaceMode, .presentation)
        XCTAssertEqual(controller.presentationInspectorTab, .layout)
        XCTAssertTrue(controller.isDocumentOutputAvailable)
    }

    @MainActor
    func testDocumentWorkflowPublishesScopedOutputCommandAvailability() throws {
        let fixture = try makeController(
            rootAnnotations: [],
            itemAnnotationSets: [[], []]
        )
        let defaults = UserDefaults(
            suiteName:
                "CompositionEditingScopeTests.CommandAvailability."
                + UUID().uuidString
        )!
        let model = AppModel(
            defaults: defaults,
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )
        var observedAvailability: [Bool] = []
        let observation = model.documents
            .$isEditorDocumentOutputAvailable
            .removeDuplicates()
            .sink { observedAvailability.append($0) }

        model.editorController = fixture.controller
        XCTAssertTrue(model.documents.isEditorDocumentOutputAvailable)

        fixture.controller.enterCompositionItemEditing(fixture.itemIDs[0])
        XCTAssertFalse(model.documents.isEditorDocumentOutputAvailable)
        fixture.controller.finishCompositionEditing()
        XCTAssertTrue(model.documents.isEditorDocumentOutputAvailable)

        fixture.controller.enterCompositionEditing()
        XCTAssertFalse(model.documents.isEditorDocumentOutputAvailable)
        fixture.controller.finishCompositionEditing()
        XCTAssertTrue(model.documents.isEditorDocumentOutputAvailable)

        model.editorController = nil
        XCTAssertFalse(model.documents.isEditorDocumentOutputAvailable)
        XCTAssertEqual(
            observedAvailability,
            [false, true, false, true, false, true, false]
        )
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testLargeCompositionEditingUsesCappedProxyAndStoresLogicalCoordinates() throws {
        let fixture = try makeController(
            rootAnnotations: [],
            itemAnnotationSets: [[], []]
        )
        let controller = fixture.controller
        controller.setCompositionLayout(.freeform)
        for (index, itemID) in fixture.itemIDs.enumerated() {
            var item = try XCTUnwrap(
                controller.composition?.items.first { $0.id == itemID }
            )
            item.freeformFrame = CGRect(
                x: CGFloat(index) * 10_010,
                y: 0,
                width: 10_000,
                height: 1_000
            )
            controller.execute(UpdateCompositionItemCommand(item: item))
        }
        let logicalLayout = try controller.currentCompositionRenderLayout()
        XCTAssertGreaterThan(logicalLayout.canvasSize.width, 16_384)

        controller.enterCompositionEditing()
        XCTAssertEqual(controller.compositionEditingScope, .composition)
        XCTAssertEqual(
            controller.compositionAssetRepository.diagnostics.fullResolutionDecodeCount,
            0,
            "The visible composition editing proxy must downsample encoded sources before item rendering."
        )
        XCTAssertLessThanOrEqual(
            max(controller.capture.image.width, controller.capture.image.height),
            4_096
        )
        let displaySize = controller.capture.pixelSize
        let annotation = Annotation.makeRectangle(
            in: CGRect(
                x: displaySize.width * 0.25,
                y: displaySize.height * 0.20,
                width: displaySize.width * 0.10,
                height: displaySize.height * 0.30
            ),
            style: .default(for: .rectangle)
        )
        controller.addAnnotation(annotation)
        controller.finishCompositionEditing()

        let stored = try XCTUnwrap(
            controller.composition?.canvas.annotations.first {
                $0.id == annotation.id
            }
        )
        XCTAssertEqual(
            stored.boundingRect.minX / logicalLayout.canvasSize.width,
            0.25,
            accuracy: 0.002
        )
        XCTAssertEqual(
            stored.boundingRect.minY / logicalLayout.canvasSize.height,
            0.20,
            accuracy: 0.01
        )
    }

    @MainActor
    private func makeController(
        rootAnnotations: [Annotation],
        itemAnnotationSets: [[Annotation]],
        canvasAnnotations: [Annotation] = []
    ) throws -> (controller: EditorController, itemIDs: [UUID]) {
        let rootCapture = makeCapturedScreenshot()
        let repository = CompositionAssetRepository()
        var items: [CompositionItem] = []
        for (index, annotations) in itemAnnotationSets.enumerated() {
            let assetID = UUID()
            let capture = makeCapturedScreenshot(
                sourceName: "Item \(index + 1)"
            )
            try repository.add(
                capture: capture,
                isPrivate: false,
                assetID: assetID
            )
            items.append(
                CompositionItem(
                    assetID: assetID,
                    editState: ScreenshotEditState(
                        cropRect: CGRect(
                            origin: .zero,
                            size: CGSize(
                                width: capture.image.width,
                                height: capture.image.height
                            )
                        ),
                        annotations: annotations
                    ),
                    title: capture.sourceName
                )
            )
        }

        var snapshot = makeEditorSnapshot(
            cropRect: CGRect(
                origin: .zero,
                size: CGSize(
                    width: rootCapture.image.width,
                    height: rootCapture.image.height
                )
            ),
            annotations: rootAnnotations
        )
        snapshot.composition = CompositionSnapshot(
            items: items,
            selectedItemIDs: [items[0].id],
            canvas: CompositionCanvasState(annotations: canvasAnnotations)
        )
        let controller = EditorController(
            capture: rootCapture,
            session: makeEditorDocumentSession(initialSnapshot: snapshot),
            defaults: UserDefaults(
                suiteName: "CompositionEditingScopeTests.\(UUID().uuidString)"
            )!,
            capabilities: testCapabilities,
            compositionStoredAssets: repository.storedAssets()
        )
        return (controller, items.map(\.id))
    }
}
