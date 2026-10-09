import CoreGraphics
import XCTest
@testable import SnipSnipSnip

final class AnnotationDuplicationRegressionTests: XCTestCase {
    @MainActor
    func testMultiSelectionDuplicationPreservesPlacementAndUsesOneUndoStep() {
        let name = "AnnotationDuplicationRegressionTests.\(UUID())"
        let defaults = makeDefaults(named: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let groupID = UUID()
        let first = Annotation.makeRectangle(in: CGRect(x: 4, y: 4, width: 12, height: 12)).updatingGroup(groupID)
        let second = Annotation.makeNumberedArrow(from: CGPoint(x: 8, y: 8), to: CGPoint(x: 30, y: 20), number: 1)
            .updatingGroup(groupID)
        let third = Annotation.makeNumberedArrow(from: CGPoint(x: 12, y: 12), to: CGPoint(x: 35, y: 25), number: 2)
        let original = makeEditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: 64, height: 48),
            annotations: [first, second, third], selectedAnnotationIDs: [third.id, first.id, second.id])
        let controller = EditorController(capture: makeCapturedScreenshot(),
            session: makeEditorDocumentSession(initialSnapshot: original), defaults: defaults)
        let offset = CGSize(width: 3, height: 5)

        controller.duplicateSelectedAnnotations(offset: offset)

        let duplicated = controller.snapshot
        let copies = Array(duplicated.annotations.suffix(3))
        XCTAssertEqual(duplicated.annotations.count, 6)
        XCTAssertEqual(Array(duplicated.annotations.prefix(3)), original.annotations)
        XCTAssertEqual(Set(duplicated.annotations.map(\.id)).count, 6)
        XCTAssertEqual(duplicated.selectedAnnotationIDs, copies.map(\.id))
        XCTAssertTrue(copies.allSatisfy { $0.groupID == nil }, "Preserve existing duplicate grouping behavior")
        XCTAssertEqual(copies.map(\.boundingRect), original.annotations.map {
            $0.boundingRect.offsetBy(dx: offset.width, dy: offset.height)
        })
        let numberedCopies = copies.compactMap { annotation -> Int? in
            if case .arrow(let shape) = annotation.kind { return shape.sequenceNumber }
            return nil
        }
        XCTAssertEqual(numberedCopies, [3, 4])
        XCTAssertEqual(controller.documentSession.undoStack.count, 1)

        controller.undo()
        XCTAssertEqual(controller.snapshot, original)
        controller.redo()
        XCTAssertEqual(controller.snapshot, duplicated)
    }

    func testBatchAddRejectsConflictingIdentitiesWithoutPartialInsertion() {
        let existing = Annotation.makeRectangle(in: CGRect(x: 0, y: 0, width: 12, height: 12))
        let new = Annotation.makeEllipse(in: CGRect(x: 20, y: 0, width: 12, height: 12))
        let snapshot = makeEditorSnapshot(annotations: [existing])
        XCTAssertEqual(AddAnnotationsCommand(annotations: [new, existing]).apply(to: snapshot), snapshot)
        XCTAssertEqual(AddAnnotationsCommand(annotations: [new, new]).apply(to: snapshot), snapshot)
        XCTAssertEqual(AddAnnotationsCommand(annotations: []).apply(to: snapshot), snapshot)
    }
}
