import CoreGraphics
import Foundation
import XCTest
@testable import SnipSnipSnip

final class CompositionFoundationTests: XCTestCase {
    func testPersistentValueModelsRoundTripWithoutLoss() throws {
        let assetID = UUID()
        let linkGroupID = UUID()
        let descriptor = CompositionAssetDescriptor(
            id: assetID,
            pixelWidth: 1_440,
            pixelHeight: 900,
            sourceName: "Settings",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            accessibilityLabel: "Settings before update",
            captureKind: CaptureKind.window.rawValue,
            sourceRect: CGRect(x: 20, y: 30, width: 720, height: 450),
            coordinateContract: .current,
            isPrivate: true
        )
        let framing = CompositionItemFraming(
            contentMode: .fill,
            horizontalAlignment: .trailing,
            verticalAlignment: .bottom,
            scale: 1.25,
            offset: CGSize(width: 4, height: -6),
            linkGroupID: linkGroupID
        )
        let comparison = CompositionComparisonSettings(
            mode: .changeHighlight,
            axis: .vertical,
            primaryItemID: UUID(),
            secondaryItemID: UUID(),
            wipePosition: 0.37,
            overlayOpacity: 0.42,
            blinkInterval: 1.2,
            differenceIntensity: 0.81,
            changeThreshold: 0.19,
            changeHighlightColor: .arrowStroke,
            primaryLabel: "Old",
            secondaryLabel: "New"
        )
        let steps = CompositionStepsSettings(
            axis: .horizontal,
            numberingStyle: .uppercaseLetters,
            startIndex: 3,
            showsCaptions: false,
            connectorStyle: .line
        )
        let layout = CompositionLayoutConfiguration(
            mode: .freeform,
            gridColumns: 3,
            targetAspectRatio: 16 / 9,
            freeformCanvasSize: CGSize(width: 1_920, height: 1_080)
        )

        try assertCodableRoundTrip(descriptor)
        try assertCodableRoundTrip(framing)
        try assertCodableRoundTrip(comparison)
        try assertCodableRoundTrip(steps)
        try assertCodableRoundTrip(layout)
        try assertCodableRoundTrip(CompositionCanvasAppearance())
        XCTAssertEqual(steps.label(for: 0), "C")
        XCTAssertEqual(steps.label(for: 25), "AB")
    }

    func testRomanStepLabelsRemainDistinctAbove3999() {
        let steps = CompositionStepsSettings(
            numberingStyle: .uppercaseRoman,
            startIndex: 4_000
        )

        XCTAssertEqual(steps.label(for: 0), "MMMM")
        XCTAssertEqual(steps.label(for: 1), "MMMMI")
    }

    func testSingleAutoItemPreservesExactPixelsAndImageIdentity() throws {
        let image = makeCoordinateImage(width: 37, height: 23)
        let asset = CompositionAsset(image: image, sourceName: "Original")
        let item = CompositionItem(assetID: asset.descriptor.id)
        let composition = CompositionSnapshot(items: [item])

        let result = try CompositionRenderer.render(
            composition: composition,
            assets: [asset.descriptor.id: asset]
        )

        XCTAssertTrue(result.image === image)
        XCTAssertEqual(result.layout.requestedMode, .auto)
        XCTAssertEqual(result.layout.resolvedMode, .row)
        XCTAssertEqual(result.layout.canvasSize, CGSize(width: 37, height: 23))
        XCTAssertEqual(result.layout.contentRect, CGRect(x: 0, y: 0, width: 37, height: 23))
        XCTAssertEqual(samplePixel(in: result.image, topLeftX: 19, topLeftY: 11), samplePixel(in: image, topLeftX: 19, topLeftY: 11))
    }

    func testRowWeightsAllocateDeterministicViewportWidths() throws {
        let first = UUID()
        let second = UUID()
        var appearance = CompositionCanvasAppearance.pixelPreserving
        appearance.itemSpacing = 10
        let composition = CompositionSnapshot(
            items: [
                CompositionItem(assetID: first, weight: 1),
                CompositionItem(assetID: second, weight: 3),
            ],
            layout: CompositionLayoutConfiguration(
                mode: .row,
                sizingMode: .weighted
            ),
            canvas: CompositionCanvasState(appearance: appearance)
        )

        let layout = try CompositionLayoutEngine.layout(
            composition: composition,
            assetDescriptors: [
                first: CompositionAssetDescriptor(id: first, pixelWidth: 100, pixelHeight: 50),
                second: CompositionAssetDescriptor(id: second, pixelWidth: 100, pixelHeight: 50),
            ]
        )

        XCTAssertEqual(layout.canvasSize, CGSize(width: 210, height: 50))
        XCTAssertEqual(layout.items[0].imageClipRect, CGRect(x: 0, y: 0, width: 50, height: 50))
        XCTAssertEqual(layout.items[1].imageClipRect, CGRect(x: 60, y: 0, width: 150, height: 50))
        XCTAssertEqual(layout.items[0].imageDrawRect, CGRect(x: 0, y: 12.5, width: 50, height: 25))
        XCTAssertEqual(layout.items[1].imageDrawRect, CGRect(x: 85, y: 0, width: 100, height: 50))
    }

    func testGridUsesStableRowsColumnsAndMaximumCellSize() throws {
        var appearance = CompositionCanvasAppearance.pixelPreserving
        appearance.itemSpacing = 4
        let assets = (0..<5).map { _ in UUID() }
        let composition = CompositionSnapshot(
            items: assets.map { CompositionItem(assetID: $0) },
            layout: CompositionLayoutConfiguration(mode: .grid, gridColumns: 2),
            canvas: CompositionCanvasState(appearance: appearance)
        )
        let descriptors = Dictionary(
            uniqueKeysWithValues: assets.enumerated().map { index, id in
                (
                    id,
                    CompositionAssetDescriptor(
                        id: id,
                        pixelWidth: 40 - index,
                        pixelHeight: 30 - index
                    )
                )
            }
        )

        let layout = try CompositionLayoutEngine.layout(
            composition: composition,
            assetDescriptors: descriptors
        )

        XCTAssertEqual(layout.canvasSize, CGSize(width: 84, height: 98))
        XCTAssertEqual(layout.items[0].imageClipRect.origin, CGPoint(x: 0, y: 0))
        XCTAssertEqual(layout.items[1].imageClipRect.origin, CGPoint(x: 44, y: 0))
        XCTAssertEqual(layout.items[2].imageClipRect.origin, CGPoint(x: 0, y: 34))
        XCTAssertEqual(layout.items[4].imageClipRect.origin, CGPoint(x: 0, y: 68))
    }

    func testWeightedGridAllocatesColumnAndRowSectionsDeterministically() throws {
        let assetIDs = (0..<4).map { _ in UUID() }
        let composition = CompositionSnapshot(
            items: zip(assetIDs, [CGFloat(1), 3, 1, 1]).map {
                CompositionItem(assetID: $0.0, weight: $0.1)
            },
            layout: CompositionLayoutConfiguration(
                mode: .grid,
                gridColumns: 2,
                sizingMode: .weighted
            ),
            canvas: CompositionCanvasState(appearance: .pixelPreserving)
        )
        let descriptors = Dictionary(uniqueKeysWithValues: assetIDs.map {
            ($0, CompositionAssetDescriptor(id: $0, pixelWidth: 100, pixelHeight: 50))
        })

        let layout = try CompositionLayoutEngine.layout(
            composition: composition,
            assetDescriptors: descriptors
        )

        XCTAssertEqual(layout.canvasSize, CGSize(width: 200, height: 100))
        XCTAssertEqual(layout.items[0].imageClipRect, CGRect(x: 0, y: 0, width: 50, height: 75))
        XCTAssertEqual(layout.items[1].imageClipRect, CGRect(x: 50, y: 0, width: 150, height: 75))
        XCTAssertEqual(layout.items[2].imageClipRect, CGRect(x: 0, y: 75, width: 50, height: 25))
        XCTAssertEqual(layout.items[3].imageClipRect, CGRect(x: 50, y: 75, width: 150, height: 25))
    }

    func testAutoSelectsGridForFourSquareItemsAndTargetSquareCanvas() throws {
        let assetIDs = (0..<4).map { _ in UUID() }
        let composition = CompositionSnapshot(
            items: assetIDs.map { CompositionItem(assetID: $0) },
            layout: CompositionLayoutConfiguration(mode: .auto, targetAspectRatio: 1)
        )
        let descriptors = Dictionary(uniqueKeysWithValues: assetIDs.map {
            ($0, CompositionAssetDescriptor(id: $0, pixelWidth: 100, pixelHeight: 100))
        })

        let first = try CompositionLayoutEngine.layout(
            composition: composition,
            assetDescriptors: descriptors
        )
        let second = try CompositionLayoutEngine.layout(
            composition: composition,
            assetDescriptors: descriptors
        )

        XCTAssertEqual(first.resolvedMode, .grid)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.canvasSize, CGSize(width: 200, height: 200))
    }

    func testAutoEvaluatesUsefulGridColumnCountsBeyondSix() throws {
        let assetIDs = (0..<50).map { _ in UUID() }
        let composition = CompositionSnapshot(
            items: assetIDs.map { CompositionItem(assetID: $0) },
            layout: CompositionLayoutConfiguration(
                mode: .auto,
                targetAspectRatio: 16 / 9
            ),
            canvas: CompositionCanvasState(appearance: .pixelPreserving)
        )
        let descriptors = Dictionary(uniqueKeysWithValues: assetIDs.map {
            ($0, CompositionAssetDescriptor(id: $0, pixelWidth: 100, pixelHeight: 100))
        })

        let layout = try CompositionLayoutEngine.layout(
            composition: composition,
            assetDescriptors: descriptors
        )
        let columnCount = Set(layout.items.map { Int($0.imageClipRect.minX.rounded()) }).count

        XCTAssertEqual(layout.resolvedMode, .grid)
        XCTAssertGreaterThan(columnCount, 6)
    }

    func testExplicitStructuredOrientationExpandsAndCentersCanvasWithoutCropping() throws {
        let assetIDs = [UUID(), UUID()]
        let composition = CompositionSnapshot(
            items: assetIDs.map { CompositionItem(assetID: $0) },
            layout: CompositionLayoutConfiguration(
                mode: .row,
                orientation: .square
            ),
            canvas: CompositionCanvasState(appearance: .pixelPreserving)
        )
        let descriptors = Dictionary(uniqueKeysWithValues: assetIDs.map {
            ($0, CompositionAssetDescriptor(id: $0, pixelWidth: 100, pixelHeight: 50))
        })

        let layout = try CompositionLayoutEngine.layout(
            composition: composition,
            assetDescriptors: descriptors
        )

        XCTAssertEqual(layout.canvasSize, CGSize(width: 200, height: 200))
        XCTAssertEqual(layout.items[0].imageClipRect, CGRect(x: 0, y: 75, width: 100, height: 50))
        XCTAssertEqual(layout.items[1].imageClipRect, CGRect(x: 100, y: 75, width: 100, height: 50))
    }

    func testAutoUsesExpectedReadingDirectionForTwoItems() throws {
        let assetIDs = [UUID(), UUID()]
        let items = assetIDs.map { CompositionItem(assetID: $0) }
        let descriptors = Dictionary(uniqueKeysWithValues: assetIDs.map {
            ($0, CompositionAssetDescriptor(id: $0, pixelWidth: 100, pixelHeight: 100))
        })
        var composition = CompositionSnapshot(
            items: items,
            layout: CompositionLayoutConfiguration(mode: .auto, targetAspectRatio: 4 / 3)
        )

        let landscape = try CompositionLayoutEngine.layout(
            composition: composition,
            assetDescriptors: descriptors
        )
        XCTAssertEqual(landscape.resolvedMode, .row)

        composition.layout.targetAspectRatio = 3 / 4
        let portrait = try CompositionLayoutEngine.layout(
            composition: composition,
            assetDescriptors: descriptors
        )
        XCTAssertEqual(portrait.resolvedMode, .column)
    }

    func testComparisonUsesExplicitPairAndReportsAdditionalItemsAsOmitted() throws {
        let assetIDs = (0..<3).map { _ in UUID() }
        let itemIDs = (0..<3).map { _ in UUID() }
        let items = zip(itemIDs, assetIDs).map {
            CompositionItem(id: $0.0, assetID: $0.1)
        }
        let composition = CompositionSnapshot(
            items: items,
            layout: CompositionLayoutConfiguration(mode: .compare),
            comparison: CompositionComparisonSettings(
                mode: .wipe,
                axis: .horizontal,
                primaryItemID: itemIDs[1],
                secondaryItemID: itemIDs[2],
                wipePosition: 0.25
            )
        )
        let descriptors = Dictionary(uniqueKeysWithValues: assetIDs.map {
            ($0, CompositionAssetDescriptor(id: $0, pixelWidth: 120, pixelHeight: 80))
        })

        let layout = try CompositionLayoutEngine.layout(
            composition: composition,
            assetDescriptors: descriptors
        )

        XCTAssertEqual(layout.items.map(\.itemID), [itemIDs[1], itemIDs[2]])
        XCTAssertEqual(layout.items[0].imageClipRect, layout.items[1].imageClipRect)
        XCTAssertEqual(layout.omittedItemIDs, [itemIDs[0]])
        XCTAssertEqual(layout.comparison?.primaryItemID, itemIDs[1])
        XCTAssertEqual(layout.comparison?.secondaryItemID, itemIDs[2])
        let dividerRect = try XCTUnwrap(layout.comparison?.dividerRect)
        XCTAssertEqual(dividerRect.midX, 30, accuracy: 0.001)
        XCTAssertEqual(layout.hitTest(CGPoint(x: 15, y: 40))?.itemID, itemIDs[2])
        XCTAssertEqual(layout.hitTest(CGPoint(x: 90, y: 40))?.itemID, itemIDs[1])
    }

    func testComparisonHitTestingTracksBlinkPhaseAndOverlayVisibility() throws {
        let primaryAssetID = UUID()
        let secondaryAssetID = UUID()
        let primary = CompositionItem(assetID: primaryAssetID)
        let secondary = CompositionItem(assetID: secondaryAssetID)
        let descriptors = [
            primaryAssetID: CompositionAssetDescriptor(
                id: primaryAssetID,
                pixelWidth: 120,
                pixelHeight: 80
            ),
            secondaryAssetID: CompositionAssetDescriptor(
                id: secondaryAssetID,
                pixelWidth: 120,
                pixelHeight: 80
            ),
        ]
        var composition = CompositionSnapshot(
            items: [primary, secondary],
            layout: CompositionLayoutConfiguration(mode: .compare),
            comparison: CompositionComparisonSettings(
                mode: .blink,
                primaryItemID: primary.id,
                secondaryItemID: secondary.id
            )
        )
        let blinkLayout = try CompositionLayoutEngine.layout(
            composition: composition,
            assetDescriptors: descriptors
        )
        let center = CGPoint(x: 60, y: 40)

        XCTAssertEqual(
            blinkLayout.hitTest(
                center,
                comparisonPhase: .primary
            )?.itemID,
            primary.id
        )
        XCTAssertEqual(
            blinkLayout.hitTest(
                center,
                comparisonPhase: .secondary
            )?.itemID,
            secondary.id
        )

        composition.comparison.mode = .overlay
        let overlayLayout = try CompositionLayoutEngine.layout(
            composition: composition,
            assetDescriptors: descriptors
        )
        XCTAssertEqual(
            overlayLayout.hitTest(
                center,
                overlayOpacity: 0
            )?.itemID,
            primary.id
        )
        XCTAssertEqual(
            overlayLayout.hitTest(
                center,
                overlayOpacity: 0.5
            )?.itemID,
            secondary.id
        )
    }

    func testComparisonSuppressesAnnotationsStillAnchoredToUnusedItems() throws {
        let assetIDs = (0..<3).map { _ in UUID() }
        let items = assetIDs.map { CompositionItem(assetID: $0) }
        let annotation = Annotation.makeRectangle(
            in: CGRect(x: 4, y: 5, width: 20, height: 10),
            style: .default(for: .rectangle)
        )
        let hiddenAnchor = CompositionAnnotationAnchor(
            target: .itemNormalized(
                itemID: items[2].id,
                point: CGPoint(x: 0.5, y: 0.5)
            ),
            lastCanvasPoint: CGPoint(x: 15, y: 20)
        )
        let composition = CompositionSnapshot(
            items: items,
            layout: CompositionLayoutConfiguration(mode: .compare),
            comparison: CompositionComparisonSettings(
                mode: .sideBySide,
                primaryItemID: items[0].id,
                secondaryItemID: items[1].id
            ),
            canvas: CompositionCanvasState(
                annotations: [annotation],
                annotationAnchors: [
                    annotation.id: CompositionAnnotationAnchors(
                        primary: hiddenAnchor,
                        secondary: nil
                    ),
                ]
            )
        )
        let descriptors = Dictionary(uniqueKeysWithValues: assetIDs.map {
            ($0, CompositionAssetDescriptor(id: $0, pixelWidth: 100, pixelHeight: 50))
        })
        let layout = try CompositionLayoutEngine.layout(
            composition: composition,
            assetDescriptors: descriptors
        )

        XCTAssertTrue(
            CompositionRenderer.resolvedCanvasAnnotations(
                composition: composition,
                layout: layout
            ).isEmpty
        )

        var pinned = composition
        pinned.canvas.annotationAnchors[annotation.id] = CompositionAnnotationAnchors(
            primary: CompositionAnnotationAnchor(
                target: .canvasNormalized(CGPoint(x: 0.5, y: 0.5)),
                lastCanvasPoint: CGPoint(x: 15, y: 20)
            ),
            secondary: nil
        )
        XCTAssertEqual(
            CompositionRenderer.resolvedCanvasAnnotations(
                composition: pinned,
                layout: layout
            ).map(\.id),
            [annotation.id]
        )
    }

    func testStepsProvideBadgesCaptionsAndConnectorHitMetadata() throws {
        let assetIDs = (0..<3).map { _ in UUID() }
        let items = assetIDs.enumerated().map {
            CompositionItem(assetID: $0.element, caption: "Do thing \($0.offset + 1)")
        }
        let composition = CompositionSnapshot(
            items: items,
            layout: CompositionLayoutConfiguration(mode: .steps),
            steps: CompositionStepsSettings(
                axis: .vertical,
                numberingStyle: .uppercaseLetters,
                startIndex: 1,
                showsCaptions: true,
                connectorStyle: .arrow
            )
        )
        let descriptors = Dictionary(uniqueKeysWithValues: assetIDs.map {
            ($0, CompositionAssetDescriptor(id: $0, pixelWidth: 160, pixelHeight: 90))
        })

        let layout = try CompositionLayoutEngine.layout(
            composition: composition,
            assetDescriptors: descriptors
        )

        XCTAssertEqual(layout.items.count, 3)
        XCTAssertEqual(layout.connectors.count, 2)
        XCTAssertTrue(layout.items.allSatisfy { $0.badgeRect != nil && $0.captionRect != nil })
        XCTAssertEqual(layout.items[0].role, .step(index: 0, label: "A"))
        XCTAssertEqual(layout.items[2].role, .step(index: 2, label: "C"))
        let badgeCenter = CGPoint(
            x: layout.items[0].badgeRect!.midX,
            y: layout.items[0].badgeRect!.midY
        )
        XCTAssertEqual(layout.hitTest(badgeCenter)?.region, .stepBadge)
    }

    func testStepsHonorIndividuallyWeightedSections() throws {
        let assetIDs = [UUID(), UUID()]
        let composition = CompositionSnapshot(
            items: [
                CompositionItem(assetID: assetIDs[0], weight: 1),
                CompositionItem(assetID: assetIDs[1], weight: 3),
            ],
            layout: CompositionLayoutConfiguration(
                mode: .steps,
                sizingMode: .weighted
            ),
            steps: CompositionStepsSettings(
                flow: .row,
                numberingStyle: .none,
                showsCaptions: false,
                connectorStyle: .none
            ),
            canvas: CompositionCanvasState(appearance: .pixelPreserving)
        )
        let descriptors = Dictionary(uniqueKeysWithValues: assetIDs.map {
            ($0, CompositionAssetDescriptor(id: $0, pixelWidth: 100, pixelHeight: 50))
        })

        let layout = try CompositionLayoutEngine.layout(
            composition: composition,
            assetDescriptors: descriptors
        )

        XCTAssertEqual(layout.canvasSize, CGSize(width: 214, height: 50))
        XCTAssertEqual(layout.items[0].imageClipRect.width, 50)
        XCTAssertEqual(layout.items[1].imageClipRect.width, 150)
    }

    func testFreeformNormalizesNegativeCoordinatesAndMapsHitsToSource() throws {
        let firstAssetID = UUID()
        let secondAssetID = UUID()
        let firstItemID = UUID()
        var appearance = CompositionCanvasAppearance.pixelPreserving
        appearance.insets = CompositionInsets(5)
        let composition = CompositionSnapshot(
            items: [
                CompositionItem(
                    id: firstItemID,
                    assetID: firstAssetID,
                    freeformFrame: CGRect(x: -20, y: 10, width: 100, height: 50)
                ),
                CompositionItem(
                    assetID: secondAssetID,
                    freeformFrame: CGRect(x: 120, y: -10, width: 40, height: 40)
                ),
            ],
            layout: CompositionLayoutConfiguration(mode: .freeform),
            canvas: CompositionCanvasState(appearance: appearance)
        )
        let layout = try CompositionLayoutEngine.layout(
            composition: composition,
            assetDescriptors: [
                firstAssetID: CompositionAssetDescriptor(id: firstAssetID, pixelWidth: 100, pixelHeight: 50),
                secondAssetID: CompositionAssetDescriptor(id: secondAssetID, pixelWidth: 40, pixelHeight: 40),
            ]
        )

        XCTAssertEqual(layout.canvasSize, CGSize(width: 190, height: 80))
        XCTAssertEqual(layout.items[0].imageClipRect, CGRect(x: 5, y: 25, width: 100, height: 50))
        XCTAssertEqual(layout.items[1].imageClipRect, CGRect(x: 145, y: 5, width: 40, height: 40))

        let hit = layout.hitTest(CGPoint(x: 55, y: 50))
        XCTAssertEqual(hit?.itemID, firstItemID)
        XCTAssertEqual(hit?.region, .image)
        let sourcePoint = try XCTUnwrap(hit?.sourceNormalizedPoint)
        XCTAssertEqual(sourcePoint.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(sourcePoint.y, 0.5, accuracy: 0.001)
    }

    func testDescriptorLayoutAppliesItemCropDimensions() throws {
        let assetID = UUID()
        let item = CompositionItem(
            assetID: assetID,
            editState: ScreenshotEditState(cropRect: CGRect(x: 10, y: 5, width: 40, height: 30))
        )
        let layout = try CompositionLayoutEngine.layout(
            composition: CompositionSnapshot(items: [item]),
            assetDescriptors: [
                assetID: CompositionAssetDescriptor(id: assetID, pixelWidth: 100, pixelHeight: 80),
            ]
        )

        XCTAssertEqual(layout.canvasSize, CGSize(width: 40, height: 30))
        XCTAssertEqual(layout.items[0].sourceSize, CGSize(width: 40, height: 30))
    }

    func testRendererDrawsRowSpacingBackgroundAndOpacity() throws {
        let red = PixelSample(red: 255, green: 0, blue: 0, alpha: 255)
        let blue = PixelSample(red: 0, green: 0, blue: 255, alpha: 255)
        let firstImage = makeSolidImage(width: 20, height: 10, color: red)
        let secondImage = makeSolidImage(width: 20, height: 10, color: blue)
        let firstAsset = CompositionAsset(image: firstImage)
        let secondAsset = CompositionAsset(image: secondImage)
        var appearance = CompositionCanvasAppearance.pixelPreserving
        appearance.fill = .color(RGBAColor(red: 1, green: 1, blue: 1, alpha: 1))
        appearance.insets = CompositionInsets(2)
        appearance.itemSpacing = 2
        let composition = CompositionSnapshot(
            items: [
                CompositionItem(assetID: firstAsset.descriptor.id),
                CompositionItem(assetID: secondAsset.descriptor.id, opacity: 0.5),
            ],
            layout: CompositionLayoutConfiguration(mode: .row),
            canvas: CompositionCanvasState(appearance: appearance)
        )

        let result = try CompositionRenderer.render(
            composition: composition,
            assets: [
                firstAsset.descriptor.id: firstAsset,
                secondAsset.descriptor.id: secondAsset,
            ]
        )

        XCTAssertEqual(result.image.width, 46)
        XCTAssertEqual(result.image.height, 14)
        XCTAssertEqual(samplePixel(in: result.image, topLeftX: 0, topLeftY: 0), PixelSample(red: 255, green: 255, blue: 255, alpha: 255))
        XCTAssertEqual(samplePixel(in: result.image, topLeftX: 5, topLeftY: 5), red)
        XCTAssertEqual(samplePixel(in: result.image, topLeftX: 23, topLeftY: 5), PixelSample(red: 255, green: 255, blue: 255, alpha: 255))
        let blendedBlue = samplePixel(in: result.image, topLeftX: 30, topLeftY: 5)
        XCTAssertLessThanOrEqual(abs(Int(blendedBlue.red) - 127), 1)
        XCTAssertLessThanOrEqual(abs(Int(blendedBlue.green) - 127), 1)
        XCTAssertLessThanOrEqual(abs(Int(blendedBlue.blue) - 255), 1)
    }

    func testWipeAndBlinkRenderExpectedStaticComparisonPhase() throws {
        let red = makeSolidImage(
            width: 100,
            height: 60,
            color: PixelSample(red: 255, green: 0, blue: 0, alpha: 255)
        )
        let blue = makeSolidImage(
            width: 100,
            height: 60,
            color: PixelSample(red: 0, green: 0, blue: 255, alpha: 255)
        )
        let firstAsset = CompositionAsset(image: red)
        let secondAsset = CompositionAsset(image: blue)
        let firstItem = CompositionItem(assetID: firstAsset.descriptor.id)
        let secondItem = CompositionItem(assetID: secondAsset.descriptor.id)
        var comparison = CompositionComparisonSettings(
            mode: .wipe,
            axis: .horizontal,
            primaryItemID: firstItem.id,
            secondaryItemID: secondItem.id,
            wipePosition: 0.5
        )
        var composition = CompositionSnapshot(
            items: [firstItem, secondItem],
            layout: CompositionLayoutConfiguration(mode: .compare),
            comparison: comparison
        )
        let assets = [
            firstAsset.descriptor.id: firstAsset,
            secondAsset.descriptor.id: secondAsset,
        ]

        let wipe = try CompositionRenderer.render(composition: composition, assets: assets)
        XCTAssertEqual(samplePixel(in: wipe.image, topLeftX: 25, topLeftY: 50), PixelSample(red: 0, green: 0, blue: 255, alpha: 255))
        XCTAssertEqual(samplePixel(in: wipe.image, topLeftX: 75, topLeftY: 50), PixelSample(red: 255, green: 0, blue: 0, alpha: 255))

        comparison.mode = .blink
        composition.comparison = comparison
        let primary = try CompositionRenderer.render(
            composition: composition,
            assets: assets,
            options: CompositionRenderOptions(comparisonPhase: .primary)
        )
        let secondary = try CompositionRenderer.render(
            composition: composition,
            assets: assets,
            options: CompositionRenderOptions(comparisonPhase: .secondary)
        )
        XCTAssertEqual(samplePixel(in: primary.image, topLeftX: 50, topLeftY: 50), PixelSample(red: 255, green: 0, blue: 0, alpha: 255))
        XCTAssertEqual(samplePixel(in: secondary.image, topLeftX: 50, topLeftY: 50), PixelSample(red: 0, green: 0, blue: 255, alpha: 255))
    }

    func testDifferenceAndChangeHighlightModesRender() throws {
        let first = CompositionAsset(
            image: makeSolidImage(
                width: 24,
                height: 16,
                color: PixelSample(red: 40, green: 40, blue: 40, alpha: 255)
            )
        )
        let second = CompositionAsset(
            image: makeSolidImage(
                width: 24,
                height: 16,
                color: PixelSample(red: 220, green: 40, blue: 40, alpha: 255)
            )
        )
        let firstItem = CompositionItem(assetID: first.descriptor.id)
        let secondItem = CompositionItem(assetID: second.descriptor.id)
        var composition = CompositionSnapshot(
            items: [firstItem, secondItem],
            layout: CompositionLayoutConfiguration(mode: .compare),
            comparison: CompositionComparisonSettings(
                mode: .difference,
                primaryItemID: firstItem.id,
                secondaryItemID: secondItem.id
            )
        )
        let assets = [first.descriptor.id: first, second.descriptor.id: second]

        let difference = try CompositionRenderer.render(composition: composition, assets: assets)
        XCTAssertEqual(difference.image.width, 24)
        XCTAssertEqual(difference.image.height, 16)

        composition.comparison.mode = .changeHighlight
        let highlighted = try CompositionRenderer.render(composition: composition, assets: assets)
        XCTAssertEqual(highlighted.image.width, 24)
        XCTAssertEqual(highlighted.image.height, 16)
        XCTAssertNotEqual(
            samplePixel(in: highlighted.image, topLeftX: 12, topLeftY: 12),
            samplePixel(in: first.image, topLeftX: 12, topLeftY: 12)
        )
    }

    func testAutomaticRegistrationAlignsTranslatedComparisonContent() throws {
        let original = makeCoordinateImage(
            width: 320,
            height: 200,
            pattern: .weighted(
                xMultiplier: 5,
                yMultiplier: 7,
                includeBlueSum: true
            )
        )
        let translated = try XCTUnwrap(
            translatedImage(original, offsetX: 16, offsetY: 0)
        )
        let first = CompositionAsset(image: original)
        let second = CompositionAsset(image: translated)
        let firstItem = CompositionItem(assetID: first.descriptor.id)
        let secondItem = CompositionItem(assetID: second.descriptor.id)
        let assets = [first.descriptor.id: first, second.descriptor.id: second]

        var settings = CompositionComparisonSettings(
            mode: .difference,
            primaryItemID: firstItem.id,
            secondaryItemID: secondItem.id,
            differenceIntensity: 1,
            changeThreshold: 0,
            showsLabels: false,
            registrationMode: .disabled,
            unchangedContentOpacity: 0,
            differenceCueStyle: .luminance
        )
        var composition = CompositionSnapshot(
            items: [firstItem, secondItem],
            layout: CompositionLayoutConfiguration(mode: .compare),
            comparison: settings,
            canvas: CompositionCanvasState(appearance: .pixelPreserving)
        )

        let unregistered = try CompositionRenderer.render(
            composition: composition,
            assets: assets
        )
        settings.registrationMode = .automatic
        composition.comparison = settings
        let registered = try CompositionRenderer.render(
            composition: composition,
            assets: assets
        )
        guard case .automaticSucceeded(let offset, let confidence) =
                registered.registrationOutcome else {
            return XCTFail("Translated structured content should report successful automatic registration.")
        }
        XCTAssertNotEqual(offset, .zero)
        XCTAssertGreaterThan(confidence, 0)

        let unregisteredPixel = samplePixel(
            in: unregistered.image,
            topLeftX: 160,
            topLeftY: 100
        )
        let registeredPixel = samplePixel(
            in: registered.image,
            topLeftX: 160,
            topLeftY: 100
        )
        let unregisteredEnergy = Int(unregisteredPixel.red)
            + Int(unregisteredPixel.green)
            + Int(unregisteredPixel.blue)
        let registeredEnergy = Int(registeredPixel.red)
            + Int(registeredPixel.green)
            + Int(registeredPixel.blue)

        XCTAssertLessThan(
            registeredEnergy,
            unregisteredEnergy,
            "Automatic registration should reduce difference energy for translated content"
        )
    }

    func testAutomaticRegistrationReportsFailureForImagesWithoutMatchableStructure() throws {
        let first = CompositionAsset(
            image: makeSolidImage(
                width: 120,
                height: 80,
                color: PixelSample(red: 40, green: 40, blue: 40, alpha: 255)
            )
        )
        let second = CompositionAsset(
            image: makeSolidImage(
                width: 120,
                height: 80,
                color: PixelSample(red: 220, green: 220, blue: 220, alpha: 255)
            )
        )
        let firstItem = CompositionItem(assetID: first.descriptor.id)
        let secondItem = CompositionItem(assetID: second.descriptor.id)
        let composition = CompositionSnapshot(
            items: [firstItem, secondItem],
            layout: CompositionLayoutConfiguration(mode: .compare),
            comparison: CompositionComparisonSettings(
                mode: .difference,
                primaryItemID: firstItem.id,
                secondaryItemID: secondItem.id,
                registrationMode: .automatic
            ),
            canvas: CompositionCanvasState(appearance: .pixelPreserving)
        )

        let result = try CompositionRenderer.render(
            composition: composition,
            assets: [
                first.descriptor.id: first,
                second.descriptor.id: second,
            ]
        )

        XCTAssertEqual(result.registrationOutcome, .automaticFailed)
    }

    func testAlreadyRenderedItemImagesAreKeyedByItemNotSourceAsset() throws {
        let sharedAssetID = UUID()
        let firstItem = CompositionItem(assetID: sharedAssetID)
        let secondItem = CompositionItem(assetID: sharedAssetID)
        let composition = CompositionSnapshot(
            items: [firstItem, secondItem],
            layout: CompositionLayoutConfiguration(mode: .row)
        )
        let firstImage = makeSolidImage(
            width: 20,
            height: 10,
            color: PixelSample(red: 255, green: 0, blue: 0, alpha: 255)
        )
        let secondImage = makeSolidImage(
            width: 10,
            height: 20,
            color: PixelSample(red: 0, green: 0, blue: 255, alpha: 255)
        )

        let result = try CompositionRenderer.render(
            composition: composition,
            renderedItemImages: [
                firstItem.id: firstImage,
                secondItem.id: secondImage,
            ]
        )

        XCTAssertEqual(result.layout.items[0].sourceSize, CGSize(width: 20, height: 10))
        XCTAssertEqual(result.layout.items[1].sourceSize, CGSize(width: 10, height: 20))
    }

    func testLayoutErrorsAreSpecificAndStable() {
        let missingAssetID = UUID()
        let item = CompositionItem(assetID: missingAssetID)

        XCTAssertThrowsError(
            try CompositionLayoutEngine.layout(
                composition: CompositionSnapshot(items: [item]),
                assetDescriptors: [:]
            )
        ) { error in
            XCTAssertEqual(
                error as? CompositionLayoutError,
                .missingAssetDescriptor(assetID: missingAssetID)
            )
        }

        XCTAssertThrowsError(
            try CompositionLayoutEngine.layout(
                composition: CompositionSnapshot(
                    items: [item],
                    layout: CompositionLayoutConfiguration(mode: .compare)
                ),
                assetDescriptors: [
                    missingAssetID: CompositionAssetDescriptor(
                        id: missingAssetID,
                        pixelWidth: 10,
                        pixelHeight: 10
                    ),
                ]
            )
        ) { error in
            XCTAssertEqual(error as? CompositionLayoutError, .comparisonRequiresTwoItems)
        }
    }

    private func translatedImage(
        _ image: CGImage,
        offsetX: Int,
        offsetY: Int
    ) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        context.clear(
            CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        context.draw(
            image,
            in: CGRect(
                x: offsetX,
                y: offsetY,
                width: image.width,
                height: image.height
            )
        )
        return context.makeImage()
    }

    private func assertCodableRoundTrip<Value>(
        _ value: Value,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws where Value: Codable & Equatable {
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(Value.self, from: data)
        XCTAssertEqual(decoded, value, file: file, line: line)
    }
}
