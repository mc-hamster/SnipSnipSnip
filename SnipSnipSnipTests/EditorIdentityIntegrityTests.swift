import Foundation
import XCTest
@testable import SnipSnipSnip

final class EditorIdentityIntegrityTests: XCTestCase {
    func testIdentitiesAreUniqueWithinScopesButMayBeSharedAcrossScopesAndHistory() throws {
        let arrow = numberedArrow()
        let item = CompositionItem(assetID: UUID(), editState: ScreenshotEditState(annotations: [arrow]))
        let copy = CompositionItem(assetID: item.assetID, editState: item.editState)
        var snapshot = makeEditorSnapshot(annotations: [arrow])
        snapshot.composition = CompositionSnapshot(
            items: [item, copy], canvas: CompositionCanvasState(annotations: [arrow])
        )

        XCTAssertNil(EditorIdentityIntegrity.violation(in: snapshot))
        XCTAssertNoThrow(try EditorIdentityIntegrity.validate(makeEditorDocumentSession(
            initialSnapshot: snapshot, undoStack: [snapshot], redoStack: [snapshot]
        )))

        var invalid = snapshot
        invalid.annotations.append(arrow)
        XCTAssertEqual(EditorIdentityIntegrity.violation(in: invalid)?.scope, .annotations)
        invalid = snapshot
        invalid.composition?.items.append(item)
        XCTAssertEqual(EditorIdentityIntegrity.violation(in: invalid)?.scope, .compositionItems)
        invalid = snapshot
        invalid.composition?.items[1].isIncluded = false
        invalid.composition?.items[1].editState.annotations.append(arrow)
        XCTAssertEqual(EditorIdentityIntegrity.violation(in: invalid), EditorIdentityViolation(
            scope: .itemAnnotations, ownerID: copy.id, duplicateID: arrow.id
        ))
        invalid = snapshot
        invalid.composition?.canvas.annotations.append(arrow)
        XCTAssertEqual(EditorIdentityIntegrity.violation(in: invalid)?.scope, .canvasAnnotations)
    }

    @MainActor
    func testBuggyCommandIsRejectedBeforeDocumentHistoryOrRevisionChanges() throws {
        let controller = makeController(session: makeEditorDocumentSession(
            initialSnapshot: makeEditorSnapshot(annotations: [numberedArrow()])
        ))
        controller.addAnnotation(Annotation.makeRectangle(in: CGRect(x: 3, y: 4, width: 10, height: 12)))
        controller.undo()
        let session = controller.documentSession
        let revision = controller.persistenceRevision

        for undoable in [true, false] {
            controller.execute(ConflictingAnnotationTestCommand(), undoable: undoable)
            XCTAssertEqual(controller.documentSession, session)
            XCTAssertEqual(controller.persistenceRevision, revision)
            XCTAssertEqual(controller.errorMessage, "The change could not be applied safely. Your screenshot is unchanged.")
        }
        controller.redo()
        XCTAssertEqual(controller.snapshot.annotations.count, 2, "Rejected changes must preserve usable redo history")
        XCTAssertNoThrow(try EditorIdentityIntegrity.validate(controller.documentSession))
    }

    @MainActor
    func testRejectedGestureDoesNotCommitUndoOrClearRedo() {
        let controller = makeController(session: makeEditorDocumentSession(
            initialSnapshot: makeEditorSnapshot(annotations: [numberedArrow()])
        ))
        controller.addAnnotation(Annotation.makeText(at: .zero))
        controller.undo()
        let session = controller.documentSession
        let revision = controller.persistenceRevision
        controller.beginCoalescedEditorGesture()
        controller.execute(ConflictingAnnotationTestCommand())
        controller.endCoalescedEditorGesture()

        XCTAssertEqual(controller.documentSession, session)
        XCTAssertEqual(controller.persistenceRevision, revision)
    }

    @MainActor
    func testMalformedHistoryIsRejectedBeforePoppingUndoRedoOrInitialState() {
        let valid = makeEditorSnapshot(annotations: [numberedArrow()])
        var invalid = valid
        invalid.annotations.append(invalid.annotations[0])
        let sessions = [
            makeEditorDocumentSession(initialSnapshot: valid, undoStack: [invalid]),
            makeEditorDocumentSession(initialSnapshot: valid, redoStack: [invalid]),
            makeEditorDocumentSession(initialSnapshot: invalid, currentSnapshot: valid),
        ]
        for (index, input) in sessions.enumerated() {
            let controller = makeController(session: input)
            let previous = controller.documentSession
            let revision = controller.persistenceRevision
            if index == 1 { controller.redo() } else { controller.undo() }
            XCTAssertEqual(controller.documentSession, previous)
            XCTAssertEqual(controller.persistenceRevision, revision)
            XCTAssertNotNil(controller.errorMessage)
        }
    }

    @MainActor
    func testRepeatedNumberedArrowEditingKeepsEveryHistoryStateValid() throws {
        let controller = makeController(session: makeEditorDocumentSession())
        for index in 1...40 {
            let arrow = numberedArrow(number: index)
            controller.addAnnotation(arrow)
            controller.addAnnotation(arrow) // Replayed placement.
            controller.duplicateSelectedAnnotations()
            controller.undo()
            controller.redo()
            controller.deleteSelected()
            controller.execute(ResequenceNumberedArrowsCommand(
                annotationIDs: controller.snapshot.annotations.map(\.id).reversed()
            ))
            XCTAssertNoThrow(try EditorIdentityIntegrity.validate(controller.documentSession))
            XCTAssertNil(controller.errorMessage)
        }
        XCTAssertEqual(controller.snapshot.annotations.count, 40)
    }

    @MainActor
    func testInvalidImportIsRejectedBeforeAddingAssetsOrUndoHistory() throws {
        let controller = makeController(session: makeEditorDocumentSession())
        let before = controller.documentSession
        let assetIDs = Set(controller.compositionAssetRepository.assetIDs)
        let arrow = numberedArrow()
        let source = makeEditableDocument(session: makeEditorDocumentSession(
            initialSnapshot: makeEditorSnapshot(annotations: [arrow, arrow])
        ))

        XCTAssertThrowsError(try controller.appendEditableDocument(source)) { error in
            guard case SSSDocumentError.invalidComposition("duplicate annotation IDs") = error else {
                return XCTFail("Unexpected import error: \(error)")
            }
        }
        XCTAssertEqual(controller.documentSession, before)
        XCTAssertEqual(Set(controller.compositionAssetRepository.assetIDs), assetIDs)
    }

    private func numberedArrow(number: Int = 1) -> Annotation {
        Annotation.makeNumberedArrow(from: CGPoint(x: 2, y: 2), to: CGPoint(x: 20, y: 12), number: number)
    }

    @MainActor
    private func makeController(session: EditorDocumentSession) -> EditorController {
        let name = "EditorIdentityIntegrityTests.\(UUID().uuidString)"
        let defaults = makeDefaults(named: name)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return retainForTestLifetime(EditorController(
            capture: makeCapturedScreenshot(), session: session,
            defaults: defaults, capabilities: testCapabilities
        ))
    }
}

/// Simulates a future command that forgets a local safeguard. Admission must
/// protect the document independently of individual command implementations.
nonisolated struct ConflictingAnnotationTestCommand: DocumentCommand {
    var label: String { "Conflicting test change" }
    func apply(to snapshot: EditorSnapshot) -> EditorSnapshot {
        guard let first = snapshot.annotations.first else { return snapshot }
        var updated = snapshot
        updated.annotations.append(first)
        return updated
    }
}
