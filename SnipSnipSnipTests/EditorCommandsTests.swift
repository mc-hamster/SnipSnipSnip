import CoreGraphics
import XCTest
@testable import SnipSnipSnip

final class EditorCommandsTests: XCTestCase {
    private var emptySnapshot: EditorSnapshot {
        makeEditorSnapshot()
    }

    func testAddUpdateAndDeleteAnnotationCommands() {
        let annotation = Annotation.makeRectangle(in: CGRect(x: 20, y: 30, width: 100, height: 60))
        let added = AddAnnotationCommand(annotation: annotation).apply(to: emptySnapshot)

        XCTAssertEqual(added.annotations.count, 1)
        XCTAssertEqual(added.selectedAnnotationIDs, [annotation.id])

        let moved = annotation.translated(by: CGSize(width: 15, height: 25))
        let updated = UpdateAnnotationCommand(annotation: moved).apply(to: added)

        XCTAssertEqual(updated.annotations.first?.boundingRect.origin.x, 35)
        XCTAssertEqual(updated.annotations.first?.boundingRect.origin.y, 55)

        let deleted = DeleteAnnotationsCommand(annotationIDs: [annotation.id]).apply(to: updated)

        XCTAssertTrue(deleted.annotations.isEmpty)
        XCTAssertTrue(deleted.selectedAnnotationIDs.isEmpty)
    }

    func testCropCommandNormalizesRect() {
        let cropped = SetCropCommand(rect: CGRect(x: 200, y: 150, width: -50, height: -25)).apply(to: emptySnapshot)

        XCTAssertEqual(cropped.cropRect, CGRect(x: 150, y: 125, width: 50, height: 25))
    }

    func testSelectionCommandSetsSelectedAnnotationID() {
        let annotation = Annotation.makeBlur(in: CGRect(x: 10, y: 10, width: 80, height: 40))
        let added = AddAnnotationCommand(annotation: annotation).apply(to: emptySnapshot)
        let selected = SetSelectionCommand(annotationID: annotation.id).apply(to: added)

        XCTAssertEqual(selected.selectedAnnotationIDs, [annotation.id])
    }

    func testGroupingCommandAssignsSharedGroupID() {
        let first = Annotation.makeRectangle(in: CGRect(x: 10, y: 10, width: 40, height: 40))
        let second = Annotation.makeEllipse(in: CGRect(x: 80, y: 10, width: 40, height: 40))
        let grouped = SetGroupCommand(annotationIDs: [first.id, second.id], groupID: UUID()).apply(to: makeEditorSnapshot(
            cropRect: emptySnapshot.cropRect,
            annotations: [first, second],
            selectedAnnotationIDs: [first.id, second.id]
        ))

        XCTAssertNotNil(grouped.annotations.first?.groupID)
        XCTAssertEqual(grouped.annotations.first?.groupID, grouped.annotations.last?.groupID)
    }

    func testAddingCalloutAdvancesNextCalloutNumber() {
        let callout = Annotation.makeCallout(at: CGPoint(x: 30, y: 40), number: 1)
        let added = AddAnnotationCommand(annotation: callout).apply(to: emptySnapshot)

        XCTAssertEqual(added.nextCalloutNumber, 2)
    }

    func testUpdatingTextAnnotationReplacesDisplayedText() {
        let annotation = Annotation.makeText(at: .zero)
        let updated = annotation.updatingText("Hello")

        switch updated.kind {
        case let .text(shape):
            XCTAssertEqual(shape.text, "Hello")
        default:
            XCTFail("Expected a text annotation")
        }
    }

    func testUpdatingCalloutAlignmentPreservesCalloutContent() {
        let annotation = Annotation.makeCallout(at: CGPoint(x: 30, y: 40), number: 4).updatingText("Review this")
        let updated = annotation.updatingTextAlignment(.right)

        switch updated.kind {
        case let .callout(shape):
            XCTAssertEqual(shape.number, 4)
            XCTAssertEqual(shape.text, "Review this")
            XCTAssertEqual(shape.alignment, .right)
        default:
            XCTFail("Expected a callout annotation")
        }
    }

    func testUpdatingRedactionModePreservesGeometry() {
        let annotation = Annotation.makeBlur(in: CGRect(x: 10, y: 10, width: 80, height: 40))
        let updated = annotation.updatingRedactionMode(.solid)

        XCTAssertEqual(updated.boundingRect, annotation.boundingRect)
        XCTAssertEqual(updated.redactionMode, .solid)
    }

    func testRotatedAnnotationExpandsBoundsAndHitTestsInsideRotatedGeometry() {
        let annotation = Annotation.makeRectangle(in: CGRect(x: 40, y: 50, width: 80, height: 20))
            .updatingRotationDegrees(90)

        XCTAssertEqual(annotation.boundingRect.midX, 80, accuracy: 0.001)
        XCTAssertEqual(annotation.boundingRect.midY, 60, accuracy: 0.001)
        XCTAssertEqual(annotation.boundingRect.width, 20, accuracy: 1)
        XCTAssertEqual(annotation.boundingRect.height, 80, accuracy: 1)
        XCTAssertTrue(annotation.contains(CGPoint(x: 80, y: 60)))
        XCTAssertFalse(annotation.contains(CGPoint(x: 50, y: 50)))
    }

    func testMeasurementLengthUsesEndpointDistance() {
        let annotation = Annotation.makeMeasurement(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 40, y: 60))

        guard case let .measurement(shape) = annotation.kind else {
            return XCTFail("Expected measurement annotation")
        }

        XCTAssertEqual(shape.length, 50, accuracy: 0.001)
    }

    func testUpdateAnnotationCommandPersistsRotationForUndoRedoSnapshots() {
        let annotation = Annotation.makeRectangle(in: CGRect(x: 20, y: 30, width: 100, height: 60))
        let added = AddAnnotationCommand(annotation: annotation).apply(to: emptySnapshot)
        let rotated = UpdateAnnotationCommand(annotation: annotation.updatingRotationDegrees(45)).apply(to: added)

        XCTAssertEqual(rotated.annotations.first?.rotationDegrees, 45)
        XCTAssertEqual(added.annotations.first?.rotationDegrees, 0)
    }

    func testArrowScaledThroughFlippedResizeKeepsArrowHeadOnOriginalTargetSide() {
        let originalBounds = CGRect(x: 20, y: 20, width: 60, height: 40)
        let annotation = Annotation.makeArrow(
            from: CGPoint(x: originalBounds.minX, y: originalBounds.minY),
            to: CGPoint(x: originalBounds.maxX, y: originalBounds.maxY)
        )
        let flippedBounds = gscSignedScaleBounds(for: originalBounds, handle: .left, point: CGPoint(x: 100, y: originalBounds.midY))
        let updated = annotation.scaled(from: originalBounds, to: flippedBounds.resolved(to: flippedBounds.rect))

        switch updated.kind {
        case let .arrow(shape):
            XCTAssertEqual(shape.start, CGPoint(x: 100, y: 20))
            XCTAssertEqual(shape.end, CGPoint(x: 80, y: 60))
        default:
            XCTFail("Expected an arrow annotation")
        }
    }

    // MARK: - Layer Reordering Tests

    func testBringForwardMovesAnnotationUpOnePosition() {
        let first = Annotation.makeRectangle(in: CGRect(x: 0, y: 0, width: 40, height: 40))
        let second = Annotation.makeEllipse(in: CGRect(x: 50, y: 0, width: 40, height: 40))
        let third = Annotation.makeRectangle(in: CGRect(x: 100, y: 0, width: 40, height: 40))
        let snapshot = makeEditorSnapshot(
            annotations: [first, second, third],
            selectedAnnotationIDs: [second.id]
        )

        let result = ReorderAnnotationsCommand(
            annotationIDs: [second.id],
            direction: .forward,
            distance: .one
        ).apply(to: snapshot)

        XCTAssertEqual(result.annotations.map(\.id), [first.id, third.id, second.id])
        XCTAssertEqual(result.selectedAnnotationIDs, [second.id])
    }

    func testSendBackwardMovesAnnotationDownOnePosition() {
        let first = Annotation.makeRectangle(in: CGRect(x: 0, y: 0, width: 40, height: 40))
        let second = Annotation.makeEllipse(in: CGRect(x: 50, y: 0, width: 40, height: 40))
        let third = Annotation.makeRectangle(in: CGRect(x: 100, y: 0, width: 40, height: 40))
        let snapshot = makeEditorSnapshot(
            annotations: [first, second, third],
            selectedAnnotationIDs: [second.id]
        )

        let result = ReorderAnnotationsCommand(
            annotationIDs: [second.id],
            direction: .backward,
            distance: .one
        ).apply(to: snapshot)

        XCTAssertEqual(result.annotations.map(\.id), [second.id, first.id, third.id])
        XCTAssertEqual(result.selectedAnnotationIDs, [second.id])
    }

    func testBringToFrontMovesAnnotationToEndOfArray() {
        let first = Annotation.makeRectangle(in: CGRect(x: 0, y: 0, width: 40, height: 40))
        let second = Annotation.makeEllipse(in: CGRect(x: 50, y: 0, width: 40, height: 40))
        let third = Annotation.makeRectangle(in: CGRect(x: 100, y: 0, width: 40, height: 40))
        let snapshot = makeEditorSnapshot(
            annotations: [first, second, third],
            selectedAnnotationIDs: [first.id]
        )

        let result = ReorderAnnotationsCommand(
            annotationIDs: [first.id],
            direction: .forward,
            distance: .extreme
        ).apply(to: snapshot)

        XCTAssertEqual(result.annotations.map(\.id), [second.id, third.id, first.id])
    }

    func testSendToBackMovesAnnotationToStartOfArray() {
        let first = Annotation.makeRectangle(in: CGRect(x: 0, y: 0, width: 40, height: 40))
        let second = Annotation.makeEllipse(in: CGRect(x: 50, y: 0, width: 40, height: 40))
        let third = Annotation.makeRectangle(in: CGRect(x: 100, y: 0, width: 40, height: 40))
        let snapshot = makeEditorSnapshot(
            annotations: [first, second, third],
            selectedAnnotationIDs: [third.id]
        )

        let result = ReorderAnnotationsCommand(
            annotationIDs: [third.id],
            direction: .backward,
            distance: .extreme
        ).apply(to: snapshot)

        XCTAssertEqual(result.annotations.map(\.id), [third.id, first.id, second.id])
    }

    func testBringForwardNoOpWhenAlreadyAtTop() {
        let first = Annotation.makeRectangle(in: CGRect(x: 0, y: 0, width: 40, height: 40))
        let second = Annotation.makeEllipse(in: CGRect(x: 50, y: 0, width: 40, height: 40))
        let snapshot = makeEditorSnapshot(
            annotations: [first, second],
            selectedAnnotationIDs: [second.id]
        )

        let result = ReorderAnnotationsCommand(
            annotationIDs: [second.id],
            direction: .forward,
            distance: .one
        ).apply(to: snapshot)

        XCTAssertEqual(result.annotations.map(\.id), [first.id, second.id])
    }

    func testSendBackwardNoOpWhenAlreadyAtBottom() {
        let first = Annotation.makeRectangle(in: CGRect(x: 0, y: 0, width: 40, height: 40))
        let second = Annotation.makeEllipse(in: CGRect(x: 50, y: 0, width: 40, height: 40))
        let snapshot = makeEditorSnapshot(
            annotations: [first, second],
            selectedAnnotationIDs: [first.id]
        )

        let result = ReorderAnnotationsCommand(
            annotationIDs: [first.id],
            direction: .backward,
            distance: .one
        ).apply(to: snapshot)

        XCTAssertEqual(result.annotations.map(\.id), [first.id, second.id])
    }

    func testMultiSelectionBringForwardMovesBlockTogether() {
        let first = Annotation.makeRectangle(in: CGRect(x: 0, y: 0, width: 40, height: 40))
        let second = Annotation.makeEllipse(in: CGRect(x: 50, y: 0, width: 40, height: 40))
        let third = Annotation.makeRectangle(in: CGRect(x: 100, y: 0, width: 40, height: 40))
        let fourth = Annotation.makeEllipse(in: CGRect(x: 150, y: 0, width: 40, height: 40))
        let snapshot = makeEditorSnapshot(
            annotations: [first, second, third, fourth],
            selectedAnnotationIDs: [second.id, third.id]
        )

        let result = ReorderAnnotationsCommand(
            annotationIDs: [second.id, third.id],
            direction: .forward,
            distance: .one
        ).apply(to: snapshot)

        // Block [second, third] moves past fourth
        XCTAssertEqual(result.annotations.map(\.id), [first.id, fourth.id, second.id, third.id])
        XCTAssertEqual(Set(result.selectedAnnotationIDs), Set([second.id, third.id]))
    }

    func testMultiSelectionSendBackwardMovesBlockTogether() {
        let first = Annotation.makeRectangle(in: CGRect(x: 0, y: 0, width: 40, height: 40))
        let second = Annotation.makeEllipse(in: CGRect(x: 50, y: 0, width: 40, height: 40))
        let third = Annotation.makeRectangle(in: CGRect(x: 100, y: 0, width: 40, height: 40))
        let fourth = Annotation.makeEllipse(in: CGRect(x: 150, y: 0, width: 40, height: 40))
        let snapshot = makeEditorSnapshot(
            annotations: [first, second, third, fourth],
            selectedAnnotationIDs: [second.id, third.id]
        )

        let result = ReorderAnnotationsCommand(
            annotationIDs: [second.id, third.id],
            direction: .backward,
            distance: .one
        ).apply(to: snapshot)

        // Block [second, third] moves before first
        XCTAssertEqual(result.annotations.map(\.id), [second.id, third.id, first.id, fourth.id])
        XCTAssertEqual(Set(result.selectedAnnotationIDs), Set([second.id, third.id]))
    }

    func testReorderCommandLabel() {
        XCTAssertEqual(
            ReorderAnnotationsCommand(annotationIDs: [], direction: .forward, distance: .one).label,
            "Bring Forward"
        )
        XCTAssertEqual(
            ReorderAnnotationsCommand(annotationIDs: [], direction: .backward, distance: .one).label,
            "Send Backward"
        )
        XCTAssertEqual(
            ReorderAnnotationsCommand(annotationIDs: [], direction: .forward, distance: .extreme).label,
            "Bring to Front"
        )
        XCTAssertEqual(
            ReorderAnnotationsCommand(annotationIDs: [], direction: .backward, distance: .extreme).label,
            "Send to Back"
        )
    }

    func testSetAnnotationOrderCommandAppliesFullBackToFrontOrder() {
        let first = Annotation.makeRectangle(in: CGRect(x: 0, y: 0, width: 40, height: 40))
        let second = Annotation.makeEllipse(in: CGRect(x: 50, y: 0, width: 40, height: 40))
        let third = Annotation.makeArrow(from: CGPoint(x: 100, y: 0), to: CGPoint(x: 140, y: 40))
        let snapshot = makeEditorSnapshot(
            annotations: [first, second, third],
            selectedAnnotationIDs: [second.id]
        )

        let result = SetAnnotationOrderCommand(
            annotationIDsBackToFront: [third.id, first.id, second.id]
        ).apply(to: snapshot)

        XCTAssertEqual(result.annotations.map(\.id), [third.id, first.id, second.id])
        XCTAssertEqual(result.selectedAnnotationIDs, [second.id])
    }

    func testSetAnnotationOrderCommandRejectsPartialOrUnknownOrder() {
        let first = Annotation.makeRectangle(in: CGRect(x: 0, y: 0, width: 40, height: 40))
        let second = Annotation.makeEllipse(in: CGRect(x: 50, y: 0, width: 40, height: 40))
        let snapshot = makeEditorSnapshot(annotations: [first, second])

        let partial = SetAnnotationOrderCommand(annotationIDsBackToFront: [second.id])
            .apply(to: snapshot)
        let unknown = SetAnnotationOrderCommand(annotationIDsBackToFront: [second.id, UUID()])
            .apply(to: snapshot)

        XCTAssertEqual(partial.annotations.map(\.id), [first.id, second.id])
        XCTAssertEqual(unknown.annotations.map(\.id), [first.id, second.id])
    }

    func testSnapshotCanReorderForward() {
        let first = Annotation.makeRectangle(in: CGRect(x: 0, y: 0, width: 40, height: 40))
        let second = Annotation.makeEllipse(in: CGRect(x: 50, y: 0, width: 40, height: 40))

        let snapshotWithBottomSelected = makeEditorSnapshot(
            annotations: [first, second],
            selectedAnnotationIDs: [first.id]
        )
        XCTAssertTrue(snapshotWithBottomSelected.canReorderForward)

        let snapshotWithTopSelected = makeEditorSnapshot(
            annotations: [first, second],
            selectedAnnotationIDs: [second.id]
        )
        XCTAssertFalse(snapshotWithTopSelected.canReorderForward)

        let emptySnapshot = makeEditorSnapshot()
        XCTAssertFalse(emptySnapshot.canReorderForward)
    }

    func testSnapshotCanReorderBackward() {
        let first = Annotation.makeRectangle(in: CGRect(x: 0, y: 0, width: 40, height: 40))
        let second = Annotation.makeEllipse(in: CGRect(x: 50, y: 0, width: 40, height: 40))

        let snapshotWithTopSelected = makeEditorSnapshot(
            annotations: [first, second],
            selectedAnnotationIDs: [second.id]
        )
        XCTAssertTrue(snapshotWithTopSelected.canReorderBackward)

        let snapshotWithBottomSelected = makeEditorSnapshot(
            annotations: [first, second],
            selectedAnnotationIDs: [first.id]
        )
        XCTAssertFalse(snapshotWithBottomSelected.canReorderBackward)

        let emptySnapshot = makeEditorSnapshot()
        XCTAssertFalse(emptySnapshot.canReorderBackward)
    }
}
