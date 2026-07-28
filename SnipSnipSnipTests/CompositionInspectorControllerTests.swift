import Foundation
import XCTest
@testable import SnipSnipSnip

final class CompositionInspectorControllerTests: XCTestCase {
    func testWeightedDividerHitTestingRecognizesTheActualStructuredLayoutGap() {
        let first = makeLayoutItem(
            frame: CGRect(x: 20, y: 30, width: 120, height: 90)
        )
        let second = makeLayoutItem(
            frame: CGRect(x: 156, y: 30, width: 160, height: 90)
        )

        let hit = CompositionWeightedDividerHitTesting.divider(
            at: CGPoint(x: 148, y: 70),
            in: [first, second]
        )

        XCTAssertEqual(
            hit,
            CompositionWeightedDividerHit(
                firstItemID: first.itemID,
                secondItemID: second.itemID,
                axis: .horizontal
            )
        )
        XCTAssertNil(
            CompositionWeightedDividerHitTesting.divider(
                at: CGPoint(x: 60, y: 70),
                in: [first, second]
            ),
            "Clicks inside a panel must remain item selection, not divider resizing."
        )
    }

    func testWeightedDividerHitTestingRecognizesVerticalGridNeighbors() {
        let first = makeLayoutItem(
            frame: CGRect(x: 25, y: 20, width: 130, height: 80)
        )
        let second = makeLayoutItem(
            frame: CGRect(x: 25, y: 118, width: 130, height: 100)
        )

        XCTAssertEqual(
            CompositionWeightedDividerHitTesting.divider(
                at: CGPoint(x: 90, y: 109),
                in: [first, second]
            ),
            CompositionWeightedDividerHit(
                firstItemID: first.itemID,
                secondItemID: second.itemID,
                axis: .vertical
            )
        )
    }

    @MainActor
    func testSectionSizingIsOneUndoableCompositionMutation() {
        let first = CompositionItem(assetID: UUID(), title: "First")
        let second = CompositionItem(assetID: UUID(), title: "Second")
        let controller = makeController(items: [first, second], selectedItemIDs: [second.id])

        controller.setCompositionSectionSizing(.weighted)

        XCTAssertEqual(controller.composition?.layout.sizingMode, .weighted)
        XCTAssertEqual(controller.composition?.items[0].weight, 1)
        XCTAssertEqual(controller.composition?.items[1].weight, 1.25)

        controller.undo()
        XCTAssertEqual(controller.composition?.layout.sizingMode, .equal)
        XCTAssertEqual(controller.composition?.items.map(\.weight), [1, 1])
    }

    @MainActor
    func testSemanticBeforeAndAfterRolesKeepComparisonSelectorsValid() {
        let first = CompositionItem(assetID: UUID(), title: "First")
        let second = CompositionItem(assetID: UUID(), title: "Second")
        let controller = makeController(items: [first, second], selectedItemIDs: [first.id])

        controller.setCompositionItemRole(second.id, role: .before)

        XCTAssertEqual(controller.composition?.items[1].semanticRole, .before)
        XCTAssertEqual(controller.composition?.comparison.primaryItemID, second.id)
        XCTAssertEqual(controller.composition?.comparison.secondaryItemID, first.id)

        controller.setCompositionItemRole(first.id, role: .after)

        XCTAssertEqual(controller.composition?.items[0].semanticRole, .after)
        XCTAssertEqual(controller.composition?.comparison.secondaryItemID, first.id)
    }

    @MainActor
    func testComparisonLinkingUsesExplicitSettingAndSharedFramingGroup() {
        let first = CompositionItem(assetID: UUID(), title: "First")
        let second = CompositionItem(assetID: UUID(), title: "Second")
        let controller = makeController(items: [first, second], selectedItemIDs: [first.id])

        controller.setCompositionComparisonFramingLinked(true)

        let linked = controller.composition!
        let firstGroup = linked.items[0].framing.linkGroupID
        XCTAssertTrue(linked.comparison.keepsViewsLinked)
        XCTAssertNotNil(firstGroup)
        XCTAssertEqual(linked.items[1].framing.linkGroupID, firstGroup)
        XCTAssertTrue(controller.comparisonFramingIsLinked)

        controller.setCompositionComparisonFramingLinked(false)

        XCTAssertFalse(controller.composition?.comparison.keepsViewsLinked ?? true)
        XCTAssertNil(controller.composition?.items[0].framing.linkGroupID)
        XCTAssertNil(controller.composition?.items[1].framing.linkGroupID)
    }

    @MainActor
    func testFreeformNudgeMovesEverySelectedItemAndUndoesTogether() {
        let first = CompositionItem(
            assetID: UUID(),
            freeformFrame: CGRect(x: 10, y: 20, width: 100, height: 80)
        )
        let second = CompositionItem(
            assetID: UUID(),
            freeformFrame: CGRect(x: 40, y: 50, width: 120, height: 90)
        )
        let controller = makeController(
            items: [first, second],
            selectedItemIDs: [first.id, second.id]
        )

        controller.moveSelectedCompositionItemsBy(dx: 3, dy: -2)

        XCTAssertEqual(controller.composition?.items[0].freeformFrame?.origin, CGPoint(x: 13, y: 18))
        XCTAssertEqual(controller.composition?.items[1].freeformFrame?.origin, CGPoint(x: 43, y: 48))

        controller.undo()
        XCTAssertEqual(controller.composition?.items[0].freeformFrame?.origin, CGPoint(x: 10, y: 20))
        XCTAssertEqual(controller.composition?.items[1].freeformFrame?.origin, CGPoint(x: 40, y: 50))
    }

    @MainActor
    func testFreeformKeyboardResizeChangesEverySelectedItemAndUndoesTogether() {
        let first = CompositionItem(
            assetID: UUID(),
            freeformFrame: CGRect(x: 10, y: 20, width: 100, height: 80)
        )
        let second = CompositionItem(
            assetID: UUID(),
            freeformFrame: CGRect(x: 40, y: 50, width: 120, height: 90)
        )
        let controller = makeController(
            items: [first, second],
            selectedItemIDs: [first.id, second.id],
            layoutMode: .freeform
        )

        controller.resizeSelectedFreeformCompositionItemsBy(
            widthDelta: 10,
            heightDelta: -10
        )

        XCTAssertEqual(
            controller.composition?.items[0].freeformFrame?.size,
            CGSize(width: 110, height: 70)
        )
        XCTAssertEqual(
            controller.composition?.items[1].freeformFrame?.size,
            CGSize(width: 130, height: 80)
        )

        controller.undo()
        XCTAssertEqual(
            controller.composition?.items[0].freeformFrame?.size,
            CGSize(width: 100, height: 80)
        )
        XCTAssertEqual(
            controller.composition?.items[1].freeformFrame?.size,
            CGSize(width: 120, height: 90)
        )
    }

    @MainActor
    func testFreeformAlignDistributeAndMatchSizeEachCommitOneUndoableMutation() {
        let first = CompositionItem(
            assetID: UUID(),
            freeformFrame: CGRect(x: 0, y: 10, width: 80, height: 60)
        )
        let second = CompositionItem(
            assetID: UUID(),
            freeformFrame: CGRect(x: 180, y: 40, width: 100, height: 80)
        )
        let third = CompositionItem(
            assetID: UUID(),
            freeformFrame: CGRect(x: 430, y: 90, width: 120, height: 100)
        )
        let controller = makeController(
            items: [first, second, third],
            selectedItemIDs: [first.id, second.id, third.id],
            layoutMode: .freeform
        )

        controller.alignSelectedFreeformCompositionItems(.top)
        XCTAssertEqual(
            controller.composition?.items.compactMap(\.freeformFrame?.minY),
            [10, 10, 10]
        )
        controller.undo()
        XCTAssertEqual(
            controller.composition?.items.compactMap(\.freeformFrame?.minY),
            [10, 40, 90]
        )

        controller.distributeSelectedFreeformCompositionItems(.horizontal)
        let distributedFrames = try! XCTUnwrap(
            controller.composition?.items.compactMap(\.freeformFrame)
        )
        let firstGap = distributedFrames[1].minX - distributedFrames[0].maxX
        let secondGap = distributedFrames[2].minX - distributedFrames[1].maxX
        XCTAssertEqual(firstGap, secondGap, accuracy: 0.001)
        controller.undo()

        controller.matchSelectedFreeformCompositionItemSizes(.both)
        XCTAssertEqual(
            controller.composition?.items.compactMap(\.freeformFrame?.size),
            Array(repeating: CGSize(width: 80, height: 60), count: 3)
        )
        controller.undo()
        XCTAssertEqual(
            controller.composition?.items.compactMap(\.freeformFrame?.size),
            [
                CGSize(width: 80, height: 60),
                CGSize(width: 100, height: 80),
                CGSize(width: 120, height: 100),
            ]
        )
    }

    @MainActor
    func testFreeformCanvasTrimNormalizesItemsAndAutoExpandIsUndoable() {
        let first = CompositionItem(
            assetID: UUID(),
            freeformFrame: CGRect(x: 120, y: 80, width: 100, height: 70)
        )
        let second = CompositionItem(
            assetID: UUID(),
            freeformFrame: CGRect(x: 300, y: 210, width: 140, height: 90)
        )
        let controller = makeController(
            items: [first, second],
            selectedItemIDs: [first.id],
            layoutMode: .freeform
        )

        controller.trimFreeformCompositionCanvasToIncludedItems()

        XCTAssertEqual(
            controller.composition?.items[0].freeformFrame,
            CGRect(x: 0, y: 0, width: 100, height: 70)
        )
        XCTAssertEqual(
            controller.composition?.items[1].freeformFrame,
            CGRect(x: 180, y: 130, width: 140, height: 90)
        )
        XCTAssertEqual(
            controller.composition?.layout.freeformCanvasSize,
            CGSize(width: 320, height: 220)
        )

        controller.setFreeformCompositionCanvasSize(nil)
        XCTAssertNil(controller.composition?.layout.freeformCanvasSize)

        controller.undo()
        XCTAssertEqual(
            controller.composition?.layout.freeformCanvasSize,
            CGSize(width: 320, height: 220)
        )
        controller.undo()
        XCTAssertEqual(
            controller.composition?.items[0].freeformFrame,
            first.freeformFrame
        )
        XCTAssertEqual(
            controller.composition?.items[1].freeformFrame,
            second.freeformFrame
        )
        XCTAssertNil(controller.composition?.layout.freeformCanvasSize)
    }

    @MainActor
    func testLinkedFramingPropagatesAsOneUndoableMutation() {
        let linkGroupID = UUID()
        let initialFraming = CompositionItemFraming(linkGroupID: linkGroupID)
        let first = CompositionItem(assetID: UUID(), framing: initialFraming)
        let second = CompositionItem(assetID: UUID(), framing: initialFraming)
        let third = CompositionItem(assetID: UUID())
        let controller = makeController(
            items: [first, second, third],
            selectedItemIDs: [first.id]
        )

        controller.updateCompositionItem(itemID: first.id) {
            $0.framing.contentMode = .fill
            $0.framing.scale = 1.8
            $0.framing.offset = CGSize(width: 24, height: -12)
        }

        let updated = controller.composition!
        XCTAssertEqual(updated.items[0].framing, updated.items[1].framing)
        XCTAssertEqual(updated.items[0].framing.contentMode, .fill)
        XCTAssertEqual(updated.items[0].framing.scale, 1.8)
        XCTAssertEqual(updated.items[2].framing, CompositionItemFraming())

        controller.undo()
        XCTAssertEqual(controller.composition?.items[0].framing, initialFraming)
        XCTAssertEqual(controller.composition?.items[1].framing, initialFraming)
    }

    @MainActor
    func testWeightedModePreservesExistingWeightsAndStillChangesMode() {
        let first = CompositionItem(assetID: UUID(), weight: 1)
        let second = CompositionItem(assetID: UUID(), weight: 2)
        let controller = makeController(
            items: [first, second],
            selectedItemIDs: [first.id]
        )

        controller.setCompositionSectionSizing(.weighted)

        XCTAssertEqual(controller.composition?.layout.sizingMode, .weighted)
        XCTAssertEqual(controller.composition?.items.map(\.weight), [1, 2])
    }

    @MainActor
    func testResetComparisonKeepsSettingAndFramingLinkInSync() {
        var first = CompositionItem(assetID: UUID())
        var second = CompositionItem(assetID: UUID())
        first.framing.linkGroupID = nil
        second.framing.linkGroupID = nil
        let controller = makeController(
            items: [first, second],
            selectedItemIDs: [first.id]
        )

        controller.resetCompositionComparison()

        let reset = controller.composition!
        XCTAssertTrue(reset.comparison.keepsViewsLinked)
        XCTAssertNotNil(reset.items[0].framing.linkGroupID)
        XCTAssertEqual(reset.items[0].framing.linkGroupID, reset.items[1].framing.linkGroupID)
    }

    func testPresentationCanvasAffordancesKeepLayoutChromeFocused() {
        XCTAssertFalse(
            PresentationCanvasAffordancePolicy.showsSubjectOutline(
                in: .layout
            )
        )
        XCTAssertTrue(
            PresentationCanvasAffordancePolicy.showsSubjectOutline(
                in: .style
            )
        )
        XCTAssertTrue(
            PresentationCanvasAffordancePolicy.showsSubjectOutline(
                in: .scene
            )
        )
        XCTAssertEqual(
            PresentationCanvasAffordancePolicy.itemOutlineEmphasis(
                isSelected: false,
                isHovered: false
            ),
            .none
        )
        XCTAssertEqual(
            PresentationCanvasAffordancePolicy.itemOutlineEmphasis(
                isSelected: false,
                isHovered: true
            ),
            .hover
        )
        XCTAssertEqual(
            PresentationCanvasAffordancePolicy.itemOutlineEmphasis(
                isSelected: true,
                isHovered: false
            ),
            .selected
        )
    }

    func testPresentationCompositionOverlayGeometryMapsIntoViewportOnce() {
        let item = makeLayoutItem(
            frame: CGRect(x: 40, y: 30, width: 200, height: 150)
        )
        let compositionLayout = CompositionRenderLayout(
            requestedMode: .auto,
            resolvedMode: .row,
            canvasSize: CGSize(width: 400, height: 300),
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            items: [item],
            connectors: [],
            comparison: nil,
            omittedItemIDs: []
        )
        let presentationLayout = ScreenshotPresentationRenderLayout(
            canvasSize: CGSize(width: 1_000, height: 800),
            subjectRect: CGRect(x: 100, y: 50, width: 800, height: 600),
            screenRect: CGRect(x: 100, y: 50, width: 800, height: 600),
            contentRect: CGRect(x: 100, y: 50, width: 800, height: 600),
            subjectScale: 1,
            frame: .none
        )

        let result = PresentationCompositionOverlayGeometry.displayRect(
            for: item.frameRect,
            presentationLayout: presentationLayout,
            compositionLayout: compositionLayout,
            viewportRect: CGRect(x: 20, y: 40, width: 500, height: 400)
        )

        XCTAssertEqual(result.origin.x, 110, accuracy: 0.001)
        XCTAssertEqual(result.origin.y, 95, accuracy: 0.001)
        XCTAssertEqual(result.width, 200, accuracy: 0.001)
        XCTAssertEqual(result.height, 150, accuracy: 0.001)
    }

    func testPresentationCompositionOverlayClipsToVisibleSceneSlotAndPreservesInverseMapping() throws {
        let item = makeLayoutItem(
            frame: CGRect(x: 0, y: 0, width: 400, height: 200)
        )
        let compositionLayout = CompositionRenderLayout(
            requestedMode: .auto,
            resolvedMode: .row,
            canvasSize: CGSize(width: 400, height: 200),
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 200),
            items: [item],
            connectors: [],
            comparison: nil,
            omittedItemIDs: []
        )
        let presentationLayout = ScreenshotPresentationRenderLayout(
            canvasSize: CGSize(width: 1_000, height: 800),
            subjectRect: CGRect(x: 200, y: 100, width: 400, height: 300),
            screenRect: CGRect(x: 200, y: 100, width: 400, height: 300),
            contentRect: CGRect(x: 100, y: 50, width: 800, height: 400),
            subjectScale: 2,
            frame: .none
        )
        let viewportRect = CGRect(x: 20, y: 40, width: 500, height: 400)

        let visibleRect = try XCTUnwrap(
            PresentationCompositionOverlayGeometry.visibleDisplayRect(
                for: item.frameRect,
                presentationLayout: presentationLayout,
                compositionLayout: compositionLayout,
                viewportRect: viewportRect
            )
        )

        XCTAssertEqual(visibleRect.origin.x, 120, accuracy: 0.001)
        XCTAssertEqual(visibleRect.origin.y, 90, accuracy: 0.001)
        XCTAssertEqual(visibleRect.width, 200, accuracy: 0.001)
        XCTAssertEqual(visibleRect.height, 150, accuracy: 0.001)
        XCTAssertFalse(
            PresentationCompositionOverlayGeometry.isFullyVisible(
                compositionRect: item.frameRect,
                presentationLayout: presentationLayout,
                compositionLayout: compositionLayout
            ),
            "Partially covered Freeform items must not show mismatched resize handles."
        )
        XCTAssertTrue(
            PresentationCompositionOverlayGeometry.isFullyVisible(
                compositionRect: CGRect(
                    x: 50,
                    y: 25,
                    width: 200,
                    height: 150
                ),
                presentationLayout: presentationLayout,
                compositionLayout: compositionLayout
            )
        )
        XCTAssertNil(
            PresentationCompositionOverlayGeometry.visibleDisplayRect(
                for: CGRect(x: 0, y: 0, width: 40, height: 20),
                presentationLayout: presentationLayout,
                compositionLayout: compositionLayout,
                viewportRect: viewportRect
            )
        )
        XCTAssertNil(
            PresentationCompositionOverlayGeometry.compositionPoint(
                fromDisplayPoint: CGPoint(x: 100, y: 140),
                presentationLayout: presentationLayout,
                compositionLayout: compositionLayout,
                viewportRect: viewportRect
            ),
            "The covered content outside the scene slot must not accept item hits."
        )
        let mappedPoint = try XCTUnwrap(
            PresentationCompositionOverlayGeometry.compositionPoint(
                fromDisplayPoint: CGPoint(x: 170, y: 140),
                presentationLayout: presentationLayout,
                compositionLayout: compositionLayout,
                viewportRect: viewportRect
            )
        )
        XCTAssertEqual(mappedPoint.x, 100, accuracy: 0.001)
        XCTAssertEqual(mappedPoint.y, 75, accuracy: 0.001)
    }

    func testWipeOverlayRectsMatchTheActuallyVisibleSides() throws {
        let primaryID = UUID()
        let secondaryID = UUID()
        let frame = CGRect(x: 0, y: 0, width: 100, height: 80)
        let primary = makeLayoutItem(
            itemID: primaryID,
            frame: frame,
            zIndex: 0
        )
        let secondary = makeLayoutItem(
            itemID: secondaryID,
            frame: frame,
            zIndex: 1
        )
        let layout = CompositionRenderLayout(
            requestedMode: .compare,
            resolvedMode: .compare,
            canvasSize: frame.size,
            contentRect: frame,
            items: [primary, secondary],
            connectors: [],
            comparison: CompositionComparisonRenderLayout(
                mode: .wipe,
                axis: .horizontal,
                primaryItemID: primaryID,
                secondaryItemID: secondaryID,
                sharedFrame: frame,
                dividerRect: CGRect(x: 24, y: 0, width: 2, height: 80),
                wipePosition: 0.25
            ),
            omittedItemIDs: []
        )

        let primaryRect = try XCTUnwrap(
            PresentationCompositionOverlayGeometry.comparisonVisibleRect(
                for: primary,
                in: layout,
                comparisonPhase: .primary,
                overlayOpacity: 1
            )
        )
        let secondaryRect = try XCTUnwrap(
            PresentationCompositionOverlayGeometry.comparisonVisibleRect(
                for: secondary,
                in: layout,
                comparisonPhase: .primary,
                overlayOpacity: 1
            )
        )

        XCTAssertEqual(primaryRect, CGRect(x: 25, y: 0, width: 75, height: 80))
        XCTAssertEqual(secondaryRect, CGRect(x: 0, y: 0, width: 25, height: 80))
    }

    func testFreeformCanvasAccessibilityOrderUsesZOrderAndRetainsModelIndices() {
        let first = CompositionItem(
            assetID: UUID(),
            freeformFrame: CGRect(x: 300, y: 300, width: 80, height: 60),
            zIndex: 5
        )
        let second = CompositionItem(
            assetID: UUID(),
            freeformFrame: CGRect(x: 0, y: 0, width: 80, height: 60),
            zIndex: 2
        )
        let third = CompositionItem(
            assetID: UUID(),
            freeformFrame: CGRect(x: 150, y: 150, width: 80, height: 60),
            zIndex: 9
        )
        let composition = CompositionSnapshot(
            items: [first, second, third],
            layout: CompositionLayoutConfiguration(mode: .freeform)
        )
        let layouts = [
            makeLayoutItem(
                itemID: first.id,
                frame: first.freeformFrame!,
                zIndex: first.zIndex
            ),
            makeLayoutItem(
                itemID: second.id,
                frame: second.freeformFrame!,
                zIndex: second.zIndex
            ),
            makeLayoutItem(
                itemID: third.id,
                frame: third.freeformFrame!,
                zIndex: third.zIndex
            ),
        ]
        let layout = CompositionRenderLayout(
            requestedMode: .freeform,
            resolvedMode: .freeform,
            canvasSize: CGSize(width: 400, height: 400),
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 400),
            items: layouts,
            connectors: [],
            comparison: nil,
            omittedItemIDs: []
        )

        XCTAssertEqual(
            PresentationCompositionOverlayOrdering.orderedItems(
                composition: composition,
                layout: layout
            ),
            [
                PresentationCompositionOverlayOrderEntry(
                    itemID: third.id,
                    modelIndex: 2
                ),
                PresentationCompositionOverlayOrderEntry(
                    itemID: first.id,
                    modelIndex: 0
                ),
                PresentationCompositionOverlayOrderEntry(
                    itemID: second.id,
                    modelIndex: 1
                ),
            ]
        )
        XCTAssertGreaterThan(
            PresentationCompositionOverlayOrdering.visualZIndex(
                for: layouts[2],
                modelIndex: 2
            ),
            PresentationCompositionOverlayOrdering.visualZIndex(
                for: layouts[0],
                modelIndex: 0
            )
        )
        let tiedFront = makeLayoutItem(
            itemID: third.id,
            frame: third.freeformFrame!,
            zIndex: first.zIndex
        )
        XCTAssertGreaterThan(
            PresentationCompositionOverlayOrdering.visualZIndex(
                for: tiedFront,
                modelIndex: 2
            ),
            PresentationCompositionOverlayOrdering.visualZIndex(
                for: layouts[0],
                modelIndex: 0
            ),
            "Equal model z-indices must paint later model items on top."
        )
    }

    @MainActor
    func testFreeformCanvasArrangeActionsChangeZOrderWithoutReorderingTheModel() throws {
        let sharedFrame = CGRect(x: 40, y: 30, width: 120, height: 80)
        let first = CompositionItem(
            assetID: UUID(),
            freeformFrame: sharedFrame,
            zIndex: 5
        )
        let second = CompositionItem(
            assetID: UUID(),
            freeformFrame: sharedFrame,
            zIndex: 2
        )
        let third = CompositionItem(
            assetID: UUID(),
            freeformFrame: sharedFrame,
            zIndex: 9
        )
        let controller = makeController(
            items: [first, second, third],
            selectedItemIDs: [first.id],
            layoutMode: .freeform
        )

        XCTAssertTrue(
            controller.canMoveFreeformCompositionItem(
                first.id,
                direction: .towardFront
            )
        )
        controller.moveFreeformCompositionItem(
            first.id,
            direction: .towardFront
        )

        XCTAssertEqual(
            controller.composition?.items.map(\.id),
            [first.id, second.id, third.id]
        )
        XCTAssertEqual(
            CompositionFreeformZOrdering.itemIDsBackToFront(
                controller.composition?.items ?? []
            ),
            [second.id, third.id, first.id]
        )
        XCTAssertEqual(
            controller.composition?.items.map(\.zIndex),
            [3, 1, 2],
            "Explicit Freeform order must reserve zero as the unset sentinel."
        )
        XCTAssertEqual(controller.composition?.selectedItemIDs, [first.id])

        let composition = try XCTUnwrap(controller.composition)
        let renderedSizes = Dictionary(
            uniqueKeysWithValues: composition.items.map {
                ($0.id, sharedFrame.size)
            }
        )
        let layout = try CompositionLayoutEngine.layout(
            composition: composition,
            renderedItemSizes: renderedSizes
        )
        XCTAssertEqual(
            layout.items
                .sorted(by: { $0.zIndex < $1.zIndex })
                .map(\.itemID),
            [second.id, third.id, first.id]
        )
        let frontLayout = try XCTUnwrap(layout.itemLayout(for: first.id))
        XCTAssertEqual(
            layout.hitTest(
                CGPoint(
                    x: frontLayout.imageClipRect.midX,
                    y: frontLayout.imageClipRect.midY
                )
            )?.itemID,
            first.id,
            "Pointer hit order must match the stored and rendered front item."
        )
    }

    @MainActor
    private func makeController(
        items: [CompositionItem],
        selectedItemIDs: [UUID],
        layoutMode: CompositionLayoutMode = .auto
    ) -> EditorController {
        var snapshot = makeEditorSnapshot()
        var composition = CompositionSnapshot(
            items: items,
            selectedItemIDs: selectedItemIDs,
            layout: CompositionLayoutConfiguration(mode: layoutMode)
        )
        composition.repairComparisonSelection()
        snapshot.composition = composition
        let suiteName = "CompositionInspectorControllerTests.\(UUID().uuidString)"
        let defaults = makeDefaults(named: suiteName)

        return EditorController(
            capture: makeCapturedScreenshot(),
            session: makeEditorDocumentSession(initialSnapshot: snapshot),
            defaults: defaults,
            capabilities: testCapabilities
        )
    }

    private func makeLayoutItem(
        itemID: UUID = UUID(),
        frame: CGRect,
        zIndex: Int = 0
    ) -> CompositionItemRenderLayout {
        CompositionItemRenderLayout(
            itemID: itemID,
            assetID: UUID(),
            sourceSize: frame.size,
            frameRect: frame,
            imageClipRect: frame,
            imageDrawRect: frame,
            captionRect: nil,
            badgeRect: nil,
            opacity: 1,
            zIndex: zIndex,
            role: .item
        )
    }
}
