import CoreGraphics
import XCTest
@testable import SnipSnipSnip

final class EditorLayerReorderRegressionTests: XCTestCase {
    func testExtremeReorderMovesMixedSelectionIncludingBothEdgeLayers() {
        let snapshot = fixtureSnapshot()
        let annotations = snapshot.annotations
        for (direction, expectedIndices) in [(ReorderDirection.forward, [1, 3, 0, 2, 4]),
                                              (.backward, [0, 2, 4, 1, 3])] {
            let result = ReorderAnnotationsCommand(annotationIDs: snapshot.selectedAnnotationIDs,
                direction: direction, distance: .extreme).apply(to: snapshot)
            XCTAssertEqual(result.annotations, expectedIndices.map { annotations[$0] })
            XCTAssertEqual(result.selectedAnnotationIDs, snapshot.selectedAnnotationIDs)
            XCTAssertEqual(result.cropRect, snapshot.cropRect)
        }
    }

    func testOneStepReorderStillStopsAtSelectionBoundary() {
        let snapshot = fixtureSnapshot()
        for direction in [ReorderDirection.forward, .backward] {
            XCTAssertEqual(ReorderAnnotationsCommand(annotationIDs: snapshot.selectedAnnotationIDs,
                direction: direction, distance: .one).apply(to: snapshot), snapshot)
        }
    }

    @MainActor
    func testExtremeReorderIsOneUndoableChangeAndPreservesStableOrder() {
        for direction in [ReorderDirection.forward, .backward] {
            let name = "EditorLayerReorderRegressionTests.\(UUID())"
            let defaults = makeDefaults(named: name)
            defer { defaults.removePersistentDomain(forName: name) }
            let snapshot = fixtureSnapshot()
            let controller = EditorController(capture: makeCapturedScreenshot(),
                session: makeEditorDocumentSession(initialSnapshot: snapshot), defaults: defaults)
            // Opening a legacy single-image snapshot seeds its inactive
            // composition; Undo must restore the complete opened state.
            let before = controller.snapshot
            if direction == .forward { controller.sendToFront() } else { controller.sendToBack() }
            let reordered = controller.snapshot
            XCTAssertNotEqual(reordered.annotations, snapshot.annotations)
            XCTAssertEqual(controller.documentSession.undoStack.count, 1)
            controller.undo()
            XCTAssertEqual(controller.snapshot, before)
            controller.redo()
            XCTAssertEqual(controller.snapshot, reordered)
        }
    }

    private func fixtureSnapshot() -> EditorSnapshot {
        let annotations = (0..<5).map { index in
            Annotation.makeRectangle(in: CGRect(x: index * 4, y: 4, width: 20, height: 20))
        }
        return makeEditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: 64, height: 48),
            annotations: annotations,
            selectedAnnotationIDs: [annotations[4].id, annotations[0].id, annotations[2].id])
    }
}
