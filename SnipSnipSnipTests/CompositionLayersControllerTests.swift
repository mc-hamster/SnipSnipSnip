import CoreGraphics
import Foundation
import XCTest
@testable import SnipSnipSnip

final class CompositionLayersControllerTests: XCTestCase {
    @MainActor
    func testItemLayerSelectionExpandsAGroup() {
        let groupID = UUID()
        let first = makeAnnotation(x: 10).updatingGroup(groupID)
        let second = makeAnnotation(x: 40).updatingGroup(groupID)
        let third = makeAnnotation(x: 70)
        let item = CompositionItem(
            assetID: UUID(),
            editState: ScreenshotEditState(annotations: [first, second, third])
        )
        let controller = makeController(items: [item])

        controller.selectLayerAnnotations([first.id], in: .item(item.id))

        XCTAssertEqual(
            controller.selectedAnnotationIDs(in: .item(item.id)),
            [first.id, second.id]
        )
    }

    @MainActor
    func testCompositionLayerReorderIsUndoableOutsideCompositionEditing() {
        let back = makeAnnotation(x: 10)
        let middle = makeAnnotation(x: 40)
        let front = makeAnnotation(x: 70)
        var canvas = CompositionCanvasState(annotations: [back, middle, front])
        canvas.selectedAnnotationIDs = [middle.id]
        let controller = makeController(items: [makeItem()], canvas: canvas)

        controller.arrangeLayerAnnotations(
            [middle.id],
            in: .composition,
            arrangement: .forward
        )

        XCTAssertEqual(
            controller.annotations(in: .composition).map(\.id),
            [back.id, front.id, middle.id]
        )

        controller.undo()

        XCTAssertEqual(
            controller.annotations(in: .composition).map(\.id),
            [back.id, middle.id, front.id]
        )
    }

    @MainActor
    func testDeletingCompositionLayerAlsoRemovesItsAnchorAndUndoRestoresBoth() {
        let removed = makeAnnotation(x: 10)
        let retained = makeAnnotation(x: 40)
        let removedAnchor = CompositionAnnotationAnchors(
            primary: CompositionAnnotationAnchor(
                target: .canvasNormalized(CGPoint(x: 0.1, y: 0.2)),
                lastCanvasPoint: CGPoint(x: 10, y: 20)
            ),
            secondary: nil
        )
        let retainedAnchor = CompositionAnnotationAnchors(
            primary: CompositionAnnotationAnchor(
                target: .canvasNormalized(CGPoint(x: 0.4, y: 0.5)),
                lastCanvasPoint: CGPoint(x: 40, y: 50)
            ),
            secondary: nil
        )
        let canvas = CompositionCanvasState(
            annotations: [removed, retained],
            selectedAnnotationIDs: [removed.id],
            annotationAnchors: [
                removed.id: removedAnchor,
                retained.id: retainedAnchor,
            ]
        )
        let controller = makeController(items: [makeItem()], canvas: canvas)

        controller.deleteLayerAnnotations([removed.id], in: .composition)

        XCTAssertEqual(controller.annotations(in: .composition).map(\.id), [retained.id])
        XCTAssertNil(controller.composition?.canvas.annotationAnchors[removed.id])
        XCTAssertEqual(controller.composition?.canvas.annotationAnchors[retained.id], retainedAnchor)

        controller.undo()

        XCTAssertEqual(
            controller.annotations(in: .composition).map(\.id),
            [removed.id, retained.id]
        )
        XCTAssertEqual(controller.composition?.canvas.annotationAnchors[removed.id], removedAnchor)
    }

    @MainActor
    func testFreeformItemArrangeKeepsSourceAndZOrdersSynchronized() {
        let first = makeItem(title: "First", zIndex: 5)
        let second = makeItem(title: "Second", zIndex: 2)
        let third = makeItem(title: "Third", zIndex: 9)
        let controller = makeController(
            items: [first, second, third],
            selectedItemIDs: [second.id],
            layoutMode: .freeform
        )

        controller.arrangeCompositionLayerItems(
            [second.id],
            arrangement: .forward
        )

        XCTAssertEqual(
            controller.composition?.items.map(\.id),
            [second.id, first.id, third.id]
        )
        XCTAssertEqual(controller.composition?.items.map(\.zIndex), [1, 2, 3])
        XCTAssertEqual(controller.composition?.selectedItemIDs, [second.id])

        controller.undo()

        XCTAssertEqual(
            controller.composition?.items.map(\.id),
            [first.id, second.id, third.id]
        )
        XCTAssertEqual(controller.composition?.items.map(\.zIndex), [5, 2, 9])
    }

    @MainActor
    func testDuplicatingMultipleItemsSharesAssetsAndUndoesAsOneCommand() {
        let first = makeItem(title: "First")
        let second = makeItem(title: "Second")
        let third = makeItem(title: "Third")
        let controller = makeController(
            items: [first, second, third],
            selectedItemIDs: [first.id, third.id]
        )

        controller.duplicateCompositionLayerItems([first.id, third.id])

        let duplicated = controller.composition!
        XCTAssertEqual(duplicated.items.count, 5)
        XCTAssertEqual(duplicated.selectedItemIDs.count, 2)
        XCTAssertEqual(duplicated.items[1].assetID, first.assetID)
        XCTAssertEqual(duplicated.items[4].assetID, third.assetID)

        controller.undo()

        XCTAssertEqual(controller.composition?.items.map(\.id), [first.id, second.id, third.id])
    }

    @MainActor
    func testLayersCannotRemoveEveryCompositionItem() {
        let first = makeItem(title: "First")
        let second = makeItem(title: "Second")
        let controller = makeController(
            items: [first, second],
            selectedItemIDs: [first.id, second.id]
        )

        XCTAssertFalse(controller.canRemoveCompositionLayerItems([first.id, second.id]))
        controller.removeCompositionLayerItems([first.id, second.id])

        XCTAssertEqual(controller.composition?.items.map(\.id), [first.id, second.id])
        XCTAssertFalse(controller.canUndo)
    }

    @MainActor
    func testLayersCanMutateAnUnselectedItemsAnnotations() {
        let firstAnnotation = makeAnnotation(x: 10)
        let secondAnnotation = makeAnnotation(x: 40)
        let first = CompositionItem(
            assetID: UUID(),
            editState: ScreenshotEditState(annotations: [firstAnnotation])
        )
        let second = CompositionItem(
            assetID: UUID(),
            editState: ScreenshotEditState(annotations: [secondAnnotation])
        )
        let controller = makeController(
            items: [first, second],
            selectedItemIDs: [first.id]
        )

        controller.deleteLayerAnnotations(
            [secondAnnotation.id],
            in: .item(second.id)
        )

        XCTAssertEqual(controller.annotations(in: .item(first.id)).map(\.id), [firstAnnotation.id])
        XCTAssertTrue(controller.annotations(in: .item(second.id)).isEmpty)
        XCTAssertEqual(controller.composition?.selectedItemIDs, [first.id])
    }

    private func makeAnnotation(x: CGFloat) -> Annotation {
        Annotation.makeRectangle(
            in: CGRect(x: x, y: 10, width: 20, height: 20)
        )
    }

    private func makeItem(
        title: String = "Item",
        zIndex: Int = 0
    ) -> CompositionItem {
        CompositionItem(
            assetID: UUID(),
            title: title,
            freeformFrame: CGRect(x: 0, y: 0, width: 100, height: 80),
            zIndex: zIndex
        )
    }

    @MainActor
    private func makeController(
        items: [CompositionItem],
        selectedItemIDs: [UUID] = [],
        layoutMode: CompositionLayoutMode = .auto,
        canvas: CompositionCanvasState = CompositionCanvasState()
    ) -> EditorController {
        var snapshot = makeEditorSnapshot()
        var composition = CompositionSnapshot(
            items: items,
            selectedItemIDs: selectedItemIDs,
            layout: CompositionLayoutConfiguration(mode: layoutMode),
            canvas: canvas
        )
        composition.repairComparisonSelection()
        snapshot.composition = composition
        return EditorController(
            capture: makeCapturedScreenshot(),
            session: makeEditorDocumentSession(initialSnapshot: snapshot),
            defaults: UserDefaults(
                suiteName: "CompositionLayersControllerTests.\(UUID().uuidString)"
            )!,
            capabilities: testCapabilities
        )
    }
}
