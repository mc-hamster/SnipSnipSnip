import CoreGraphics
import Foundation
import XCTest
@testable import SnipSnipSnip

final class CompositionCommandTests: XCTestCase {
    @MainActor
    func testNewControllerUsesDormantOneItemCompositionUntilFirstAddition() throws {
        let suiteName = "CompositionCommandTests.\(UUID().uuidString)"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = EditorController(
            capture: makeCapturedScreenshot(sourceName: "Root"),
            defaults: defaults,
            capabilities: testCapabilities
        )

        XCTAssertNotNil(controller.snapshot.composition)
        XCTAssertFalse(controller.hasComposition)
        XCTAssertFalse(controller.snapshot.composition?.isActivated ?? true)
        XCTAssertEqual(controller.snapshot.composition?.items.count, 1)
        XCTAssertEqual(controller.compositionAssetRepository.assetIDs.count, 1)
    }

    @MainActor
    func testFirstAdditionSynchronizesLegacyEditsIntoRootItemAndActivatesComposition() throws {
        let suiteName = "CompositionCommandTests.\(UUID().uuidString)"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = EditorController(
            capture: makeCapturedScreenshot(sourceName: "Root"),
            defaults: defaults,
            capabilities: testCapabilities
        )
        let annotation = Annotation.makeRectangle(
            in: CGRect(x: 4, y: 5, width: 20, height: 12),
            style: .default(for: .rectangle)
        )
        controller.addAnnotation(annotation)

        _ = try controller.appendCaptureToComposition(
            makeCapturedScreenshot(sourceName: "Added"),
            isPrivate: false
        )

        XCTAssertTrue(controller.hasComposition)
        XCTAssertTrue(controller.snapshot.composition?.isActivated ?? false)
        XCTAssertEqual(
            controller.snapshot.composition?.items.first?.editState.annotations,
            [annotation]
        )
        XCTAssertEqual(controller.snapshot.composition?.items.count, 2)
    }

    func testAddCompositionItemInsertsAfterRequestedItemAndSelectsIt() {
        let first = makeItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            assetID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            title: "First"
        )
        let third = makeItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            assetID: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
            title: "Third"
        )
        let second = makeItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            assetID: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            title: "Second"
        )
        let snapshot = makeCompositionSnapshot(items: [first, third])

        let result = AddCompositionItemCommand(item: second, afterItemID: first.id)
            .apply(to: snapshot)

        XCTAssertEqual(result.composition?.items.map(\.id), [first.id, second.id, third.id])
        XCTAssertEqual(result.composition?.selectedItemIDs, [second.id])
        XCTAssertEqual(result.composition?.comparison.primaryItemID, first.id)
        XCTAssertEqual(result.composition?.comparison.secondaryItemID, second.id)
    }

    func testAddCompositionItemRejectsDuplicateIdentityWithoutMutatingSnapshot() {
        let item = makeItem()
        let snapshot = makeCompositionSnapshot(items: [item])

        let result = AddCompositionItemCommand(item: item, afterItemID: nil)
            .apply(to: snapshot)

        XCTAssertEqual(result, snapshot)
    }

    func testMoveCompositionItemsPreservesTheirVisualOrderAndClampsDestination() {
        let items = (0..<4).map { index in
            makeItem(
                id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index + 1)")!,
                assetID: UUID(uuidString: "10000000-0000-0000-0000-00000000000\(index + 1)")!,
                title: "\(index + 1)"
            )
        }
        let snapshot = makeCompositionSnapshot(items: items)

        let result = MoveCompositionItemsCommand(
            itemIDs: [items[2].id, items[0].id],
            destinationIndex: 99
        ).apply(to: snapshot)

        XCTAssertEqual(
            result.composition?.items.map(\.id),
            [items[1].id, items[3].id, items[0].id, items[2].id]
        )
    }

    func testDuplicateCompositionItemSharesImmutableAssetAndCopiesEditableState() {
        let originalID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let duplicateID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let assetID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let annotation = Annotation.makeRectangle(
            in: CGRect(x: 4, y: 6, width: 20, height: 12),
            style: .default(for: .rectangle)
        )
        let original = CompositionItem(
            id: originalID,
            assetID: assetID,
            editState: ScreenshotEditState(
                cropRect: CGRect(x: 2, y: 3, width: 80, height: 60),
                annotations: [annotation],
                selectedAnnotationIDs: [annotation.id],
                nextCalloutNumber: 4,
                pinnedUIMapElementIDs: [UUID(uuidString: "20000000-0000-0000-0000-000000000001")!]
            ),
            framing: CompositionItemFraming(
                contentMode: .fill,
                horizontalAlignment: .trailing,
                verticalAlignment: .bottom,
                scale: 1.4,
                offset: CGSize(width: 8, height: -3),
                linkGroupID: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
            ),
            opacity: 0.65,
            weight: 1.75,
            title: "Primary",
            caption: "Keep this caption",
            accessibilityLabel: "Primary screenshot",
            freeformFrame: CGRect(x: 12, y: 20, width: 180, height: 120),
            isIncluded: false
        )
        let snapshot = makeCompositionSnapshot(items: [original])

        let result = DuplicateCompositionItemCommand(
            itemID: originalID,
            duplicateItemID: duplicateID
        ).apply(to: snapshot)
        let duplicate = result.composition?.items.last

        XCTAssertEqual(result.composition?.items.count, 2)
        XCTAssertEqual(duplicate?.id, duplicateID)
        XCTAssertEqual(duplicate?.assetID, assetID)
        XCTAssertEqual(duplicate?.editState, original.editState)
        XCTAssertEqual(duplicate?.framing, original.framing)
        XCTAssertEqual(duplicate?.opacity, original.opacity)
        XCTAssertEqual(duplicate?.weight, original.weight)
        XCTAssertEqual(duplicate?.title, original.title)
        XCTAssertEqual(duplicate?.caption, original.caption)
        XCTAssertEqual(duplicate?.accessibilityLabel, original.accessibilityLabel)
        XCTAssertEqual(
            duplicate?.freeformFrame,
            original.freeformFrame?.offsetBy(dx: 24, dy: 24)
        )
        XCTAssertEqual(duplicate?.isIncluded, original.isIncluded)
        XCTAssertEqual(result.composition?.selectedItemIDs, [duplicateID])
    }

    func testReplaceCompositionItemKeepsStableItemIdentityAndPanelProperties() {
        let itemID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let originalAssetID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let replacementAssetID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let original = CompositionItem(
            id: itemID,
            assetID: originalAssetID,
            framing: CompositionItemFraming(
                contentMode: .fill,
                horizontalAlignment: .leading,
                verticalAlignment: .top,
                scale: 1.2,
                offset: CGSize(width: 5, height: 7)
            ),
            opacity: 0.8,
            weight: 2,
            title: "Old source",
            caption: "Panel caption",
            accessibilityLabel: "Before",
            freeformFrame: CGRect(x: 20, y: 30, width: 220, height: 140),
            isIncluded: false
        )
        let replacementEditState = ScreenshotEditState(
            cropRect: CGRect(x: 1, y: 2, width: 40, height: 30),
            nextCalloutNumber: 3
        )
        let snapshot = makeCompositionSnapshot(items: [original])

        let result = ReplaceCompositionItemCommand(
            itemID: itemID,
            assetID: replacementAssetID,
            editState: replacementEditState,
            title: "New source"
        ).apply(to: snapshot)
        let replaced = result.composition?.items.first

        XCTAssertEqual(replaced?.id, itemID)
        XCTAssertEqual(replaced?.assetID, replacementAssetID)
        XCTAssertEqual(replaced?.editState, replacementEditState)
        XCTAssertEqual(replaced?.title, "New source")
        XCTAssertEqual(replaced?.caption, original.caption)
        XCTAssertEqual(replaced?.accessibilityLabel, original.accessibilityLabel)
        XCTAssertEqual(replaced?.framing, original.framing)
        XCTAssertEqual(replaced?.opacity, original.opacity)
        XCTAssertEqual(replaced?.weight, original.weight)
        XCTAssertEqual(replaced?.freeformFrame, original.freeformFrame)
        XCTAssertEqual(replaced?.isIncluded, original.isIncluded)
    }

    func testExcludingComparisonItemRepairsABSelectionUsingIncludedItemsOnly() {
        let first = makeItem(title: "A")
        let second = makeItem(title: "B")
        let third = makeItem(title: "C")
        var snapshot = makeCompositionSnapshot(items: [first, second, third])
        snapshot.composition?.comparison.primaryItemID = first.id
        snapshot.composition?.comparison.secondaryItemID = second.id

        var excluded = second
        excluded.isIncluded = false
        let result = UpdateCompositionItemCommand(item: excluded).apply(to: snapshot)

        XCTAssertFalse(result.composition?.items[1].isIncluded ?? true)
        XCTAssertEqual(result.composition?.comparison.primaryItemID, first.id)
        XCTAssertEqual(result.composition?.comparison.secondaryItemID, third.id)
    }

    func testRemoveCompositionItemsProtectsFinalItemAndRepairsSelection() {
        let first = makeItem(title: "First")
        let second = makeItem(title: "Second")
        var snapshot = makeCompositionSnapshot(items: [first, second])
        snapshot.composition?.selectedItemIDs = [second.id]
        snapshot.composition?.comparison.primaryItemID = first.id
        snapshot.composition?.comparison.secondaryItemID = second.id

        let oneRemaining = RemoveCompositionItemsCommand(itemIDs: [second.id])
            .apply(to: snapshot)

        XCTAssertEqual(oneRemaining.composition?.items.map(\.id), [first.id])
        XCTAssertEqual(oneRemaining.composition?.selectedItemIDs, [first.id])
        XCTAssertNil(oneRemaining.composition?.comparison.primaryItemID)
        XCTAssertNil(oneRemaining.composition?.comparison.secondaryItemID)

        let protected = RemoveCompositionItemsCommand(itemIDs: [first.id])
            .apply(to: oneRemaining)
        XCTAssertEqual(protected, oneRemaining)
    }

    func testRemovingEveryRequestedItemProtectsTheFirstVisualItem() {
        let first = makeItem(title: "First")
        let second = makeItem(title: "Second")
        let third = makeItem(title: "Third")
        let snapshot = makeCompositionSnapshot(items: [first, second, third])

        let result = RemoveCompositionItemsCommand(
            itemIDs: [first.id, second.id, third.id]
        ).apply(to: snapshot)

        XCTAssertEqual(result.composition?.items.map(\.id), [first.id])
    }

    @MainActor
    func testControllerUndoRedoRestoresCompleteCompositionSnapshotsChronologically() {
        let suiteName = "CompositionCommandTests.\(UUID().uuidString)"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = makeItem(title: "First")
        let second = makeItem(title: "Second")
        let initial = makeCompositionSnapshot(items: [first])
        let controller = EditorController(
            capture: makeCapturedScreenshot(),
            session: makeEditorDocumentSession(initialSnapshot: initial),
            defaults: defaults,
            capabilities: testCapabilities
        )

        controller.execute(AddCompositionItemCommand(item: second, afterItemID: first.id))
        controller.execute(
            SetCompositionLayoutCommand(
                layout: CompositionLayoutConfiguration(mode: .column)
            )
        )

        XCTAssertEqual(controller.snapshot.composition?.items.map(\.id), [first.id, second.id])
        XCTAssertEqual(controller.snapshot.composition?.layout.mode, .column)

        controller.undo()
        XCTAssertEqual(controller.snapshot.composition?.items.map(\.id), [first.id, second.id])
        XCTAssertEqual(controller.snapshot.composition?.layout.mode, .auto)

        controller.undo()
        XCTAssertEqual(controller.snapshot, initial)

        controller.redo()
        controller.redo()
        XCTAssertEqual(controller.snapshot.composition?.items.map(\.id), [first.id, second.id])
        XCTAssertEqual(controller.snapshot.composition?.layout.mode, .column)
    }

    @MainActor
    func testAppendingThenRemovingPrivateCapturePermanentlyTaintsDocumentAndRetainsUndoAsset() throws {
        let suiteName = "CompositionCommandTests.\(UUID().uuidString)"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = EditorController(
            capture: makeCapturedScreenshot(sourceName: "Public root"),
            defaults: defaults,
            capabilities: testCapabilities
        )
        let insertion = try controller.appendCaptureToComposition(
            makeCapturedScreenshot(
                image: makeCoordinateImage(width: 28, height: 18),
                sourceName: "Private addition"
            ),
            isPrivate: true
        )

        XCTAssertTrue(controller.isPrivateDocument)
        XCTAssertTrue(insertion.isPrivateDocument)
        XCTAssertEqual(controller.compositionItemCount, 2)

        controller.removeSelectedCompositionItems()

        XCTAssertEqual(controller.compositionItemCount, 1)
        XCTAssertTrue(controller.isPrivateDocument)
        XCTAssertTrue(controller.editableDocument.isPrivate)
        XCTAssertTrue(
            controller.editableDocument.compositionStoredAssets.contains {
                $0.descriptor.id == insertion.assetID
            },
            "Undo-referenced private pixels must remain persisted even after their visible item is removed."
        )
    }

    @MainActor
    func testEditableCompositionImportIsAtomicWhenALaterPrivateAssetIsCorrupt() throws {
        let suiteName = "CompositionCommandTests.\(UUID().uuidString)"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let destinationCapture = makeCapturedScreenshot(
            image: makeCoordinateImage(width: 48, height: 32),
            sourceName: "Destination"
        )
        let destinationRepository = CompositionAssetRepository()
        let destinationAssetID = try destinationRepository.add(
            capture: destinationCapture,
            isPrivate: false
        )
        var destinationSnapshot = makeEditorSnapshot(
            cropRect: CGRect(
                origin: .zero,
                size: CGSize(
                    width: destinationCapture.image.width,
                    height: destinationCapture.image.height
                )
            )
        )
        destinationSnapshot.composition = CompositionSnapshot(
            items: [
                CompositionItem(
                    assetID: destinationAssetID,
                    title: "Destination"
                ),
            ]
        )
        let controller = EditorController(
            capture: destinationCapture,
            session: makeEditorDocumentSession(
                initialSnapshot: destinationSnapshot
            ),
            defaults: defaults,
            capabilities: testCapabilities,
            compositionStoredAssets: destinationRepository.storedAssets()
        )

        let validCapture = makeCapturedScreenshot(
            image: makeCoordinateImage(width: 30, height: 20),
            sourceName: "Valid source"
        )
        let sourceRepository = CompositionAssetRepository()
        let validAssetID = try sourceRepository.add(
            capture: validCapture,
            isPrivate: true
        )
        let corruptAssetID = UUID()
        let corruptAsset = CompositionStoredAsset(
            descriptor: CompositionAssetDescriptor(
                id: corruptAssetID,
                pixelWidth: 22,
                pixelHeight: 14,
                sourceName: "Corrupt private source",
                isPrivate: true
            ),
            encodedPNG: nil,
            availability: .corrupt
        )
        var sourceSnapshot = makeEditorSnapshot()
        sourceSnapshot.composition = CompositionSnapshot(
            items: [
                CompositionItem(
                    assetID: validAssetID,
                    title: "Valid source"
                ),
                CompositionItem(
                    assetID: corruptAssetID,
                    title: "Corrupt source"
                ),
            ]
        )
        let sourceDocument = EditableScreenshotDocument(
            capture: validCapture,
            session: makeEditorDocumentSession(
                initialSnapshot: sourceSnapshot
            ),
            compositionStoredAssets: sourceRepository.storedAssets()
                + [corruptAsset],
            isPrivate: true
        )
        let snapshotBeforeImport = controller.snapshot
        let assetIDsBeforeImport = Set(
            controller.compositionAssetRepository.assetIDs
        )

        XCTAssertThrowsError(
            try controller.appendEditableDocument(sourceDocument)
        )

        XCTAssertEqual(controller.snapshot, snapshotBeforeImport)
        XCTAssertEqual(
            Set(controller.compositionAssetRepository.assetIDs),
            assetIDsBeforeImport
        )
        XCTAssertFalse(controller.isPrivateDocument)
        XCTAssertFalse(controller.canUndo)
    }

    @MainActor
    func testRemovingItemDetachesAnchorAtItsLivePostLayoutPositionAndUndoRestoresLink() throws {
        let suiteName = "CompositionCommandTests.\(UUID().uuidString)"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstCapture = makeCapturedScreenshot(
            image: makeCoordinateImage(width: 80, height: 50),
            sourceName: "First"
        )
        let secondCapture = makeCapturedScreenshot(
            image: makeCoordinateImage(width: 60, height: 40),
            sourceName: "Second"
        )
        let repository = CompositionAssetRepository()
        let firstAssetID = try repository.add(
            capture: firstCapture,
            isPrivate: false
        )
        let secondAssetID = try repository.add(
            capture: secondCapture,
            isPrivate: false
        )
        let firstItem = CompositionItem(
            assetID: firstAssetID,
            title: "First",
            freeformFrame: CGRect(x: 140, y: 70, width: 220, height: 130)
        )
        let secondItem = CompositionItem(
            assetID: secondAssetID,
            title: "Second",
            freeformFrame: CGRect(x: 20, y: 240, width: 180, height: 120)
        )
        let annotation = Annotation.makeArrow(
            from: CGPoint(x: 1, y: 1),
            to: CGPoint(x: 30, y: 20)
        )
        let anchor = CompositionAnnotationAnchor(
            target: .itemNormalized(
                itemID: firstItem.id,
                point: CGPoint(x: 0.72, y: 0.36)
            ),
            lastCanvasPoint: CGPoint(x: 3, y: 4)
        )
        var snapshot = makeEditorSnapshot()
        snapshot.composition = CompositionSnapshot(
            items: [firstItem, secondItem],
            selectedItemIDs: [firstItem.id],
            layout: CompositionLayoutConfiguration(mode: .freeform),
            canvas: CompositionCanvasState(
                annotations: [annotation],
                annotationAnchors: [
                    annotation.id: CompositionAnnotationAnchors(
                        primary: anchor,
                        secondary: nil
                    ),
                ]
            )
        )
        let controller = EditorController(
            capture: firstCapture,
            session: makeEditorDocumentSession(initialSnapshot: snapshot),
            defaults: defaults,
            capabilities: testCapabilities,
            compositionStoredAssets: repository.storedAssets()
        )
        let liveLayout = try controller.currentCompositionRenderLayout()
        let expectedDetachPoint = CompositionRenderer.resolvedCanvasPoint(
            for: anchor,
            layout: liveLayout
        )

        controller.removeCompositionItemsPreservingAnchorPositions(
            [firstItem.id]
        )

        let detachedAnchor = try XCTUnwrap(
            controller.composition?.canvas.annotationAnchors[annotation.id]?
                .primary
        )
        guard case .detachedCanvas(let detachedPoint) = detachedAnchor.target else {
            return XCTFail("Expected the removed item anchor to detach to the canvas.")
        }
        XCTAssertEqual(detachedPoint.x, expectedDetachPoint.x, accuracy: 0.001)
        XCTAssertEqual(detachedPoint.y, expectedDetachPoint.y, accuracy: 0.001)
        XCTAssertEqual(detachedAnchor.lastCanvasPoint.x, expectedDetachPoint.x, accuracy: 0.001)
        XCTAssertEqual(detachedAnchor.lastCanvasPoint.y, expectedDetachPoint.y, accuracy: 0.001)

        controller.undo()

        XCTAssertTrue(
            controller.composition?.items.contains {
                $0.id == firstItem.id
            } == true
        )
        XCTAssertEqual(
            controller.composition?.canvas.annotationAnchors[annotation.id]?
                .primary,
            anchor
        )
    }

    private func makeCompositionSnapshot(items: [CompositionItem]) -> EditorSnapshot {
        var snapshot = makeEditorSnapshot()
        snapshot.composition = CompositionSnapshot(items: items)
        return snapshot
    }

    private func makeItem(
        id: UUID = UUID(),
        assetID: UUID = UUID(),
        title: String = "Capture"
    ) -> CompositionItem {
        CompositionItem(id: id, assetID: assetID, title: title)
    }
}
