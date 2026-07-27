import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import SnipSnipSnip

final class SSSDocumentCompositionTests: XCTestCase {
    func testV7ManifestPersistsPermanentPrivateStateAndOmitsSearchMetadata() throws {
        let packageURL = temporaryPackageURL()
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let image = makeCoordinateImage(width: 36, height: 24)
        let annotation = Annotation.makeText(at: CGPoint(x: 3, y: 4))
            .updatingText("Never index this")
        let snapshot = makeEditorSnapshot(
            cropRect: CGRect(x: 0, y: 0, width: 36, height: 24),
            annotations: [annotation]
        )
        var document = makeEditableDocument(
            capture: makeCapturedScreenshot(
                image: image,
                sourceName: "Private source name"
            ),
            session: makeEditorDocumentSession(initialSnapshot: snapshot)
        )
        document.isPrivate = true

        try SSSDocumentPackage.save(
            document: document,
            previewImage: image,
            to: packageURL
        )

        let manifest = try manifestDictionary(at: packageURL)
        let privacy = try XCTUnwrap(manifest["privacy"] as? [String: Any])
        let loaded = try SSSDocumentPackage.load(from: packageURL)

        XCTAssertEqual(manifest["formatVersion"] as? Int, 7)
        XCTAssertEqual(privacy["isPrivate"] as? Bool, true)
        XCTAssertNil(manifest["metadata"])
        XCTAssertTrue(loaded.isPrivate)
        XCTAssertEqual(loaded.sourceFormatVersion, 7)
        XCTAssertEqual(
            SSSDocumentPackage.searchableText(
                for: loaded,
                includeUIMapSearchText: true
            ),
            ""
        )
        XCTAssertEqual(SSSDocumentPackage.loadSearchableText(from: packageURL), "")
        XCTAssertEqual(
            try SSSDocumentPackage.updateRecognizedText(
                "Sensitive OCR",
                in: packageURL
            ),
            ""
        )
        XCTAssertNil(try manifestDictionary(at: packageURL)["metadata"])
    }

    func testPrivateAssetProvenanceConservativelyTaintsSaveLoadAndSearch() throws {
        let fixture = try makeSavedCompositionPackage(privateAsset: true)
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        var manifest = try manifestDictionary(at: fixture.url)
        let privacy = try XCTUnwrap(manifest["privacy"] as? [String: Any])
        XCTAssertEqual(privacy["isPrivate"] as? Bool, true)
        XCTAssertNil(manifest["metadata"])
        XCTAssertTrue(try SSSDocumentPackage.load(from: fixture.url).isPrivate)

        manifest["privacy"] = ["isPrivate": false]
        manifest["metadata"] = [
            "search": [
                "annotationText": "secret annotation",
                "recognizedText": "secret OCR",
                "searchableText": "secret searchable text",
            ],
        ]
        let tamperedData = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        )
        try tamperedData.write(
            to: fixture.url.appendingPathComponent(
                SSSDocumentPackage.manifestFilename
            ),
            options: .atomic
        )

        XCTAssertTrue(
            try SSSDocumentPackage.load(from: fixture.url).isPrivate,
            "Private source provenance must win over an inconsistent manifest privacy bit."
        )
        XCTAssertEqual(
            SSSDocumentPackage.loadSearchableText(from: fixture.url),
            "",
            "Index helpers must not expose metadata when any saved source is private."
        )
        XCTAssertEqual(
            try SSSDocumentPackage.updateRecognizedText(
                "new secret OCR",
                in: fixture.url
            ),
            "",
            "OCR indexing must honor private asset provenance even when the manifest bit is inconsistent."
        )
    }

    func testRepresentativeV6PackageMigratesEveryLegacyEditingSurfaceWithPixelEquivalentOutput() throws {
        let packageURL = temporaryPackageURL()
        let migratedPackageURL = temporaryPackageURL()
        defer {
            try? FileManager.default.removeItem(at: packageURL)
            try? FileManager.default.removeItem(at: migratedPackageURL)
        }

        let image = makeCoordinateImage(
            width: 360,
            height: 260,
            pattern: .weighted(
                xMultiplier: 5,
                yMultiplier: 7,
                includeBlueSum: true
            )
        )
        let overlayImage = makeCoordinateImage(
            width: 24,
            height: 18,
            pattern: .weighted(
                xMultiplier: 11,
                yMultiplier: 3,
                includeBlueSum: true
            )
        )
        let overlayAssetID = UUID(
            uuidString: "66000000-0000-0000-0000-000000000090"
        )!
        let pinnedElementID = UUID(
            uuidString: "66000000-0000-0000-0000-000000000091"
        )!
        let uiMap = UIMapSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_060),
            sourceRect: CGRect(x: 40, y: 80, width: 360, height: 260),
            elements: [
                UIMapElement(
                    id: pinnedElementID,
                    name: "Legacy save button",
                    accessibilityLabel: "Save legacy fixture",
                    accessibilityIdentifier: "legacy-save",
                    role: "AXButton",
                    roleDescription: "Button",
                    documentRect: CGRect(
                        x: 24,
                        y: 18,
                        width: 72,
                        height: 28
                    ),
                    owningApplication: "Legacy Fixture",
                    bundleIdentifier: "com.example.legacy-fixture"
                )
            ]
        )
        let capture = makeCapturedScreenshot(
            image: image,
            kind: .window,
            sourceName: "Representative Version Six",
            sourceRect: uiMap.sourceRect,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_006),
            uiMap: uiMap
        )
        let annotations = representativeLegacyAnnotations(
            overlayImage: overlayImage,
            overlayAssetID: overlayAssetID
        )
        let scene = AppliedPresentationScene(
            sceneID: "builtin.legacy-v6-migration-fixture",
            name: "Legacy V6 Migration Fixture",
            version: 1,
            sanitizedSVGText: legacyMigrationSceneSVG(),
            textSlotValues: [:],
            screenshotSlotSettings: PresentationSceneScreenshotSlotSettings(
                framingPreset: .showFull,
                fit: .contain,
                alignment: .center,
                scale: 0.92,
                offset: CGSize(width: 3, height: -2),
                hasManualAdjustment: true
            )
        )
        var styledPresentation =
            ScreenshotPresentationPreset.transparentShadow.settings
        styledPresentation.background = .twoColorGradient(
            start: RGBAColor(red: 0.92, green: 0.96, blue: 1, alpha: 1),
            end: RGBAColor(red: 0.42, green: 0.50, blue: 0.72, alpha: 1)
        )
        styledPresentation.canvas = .preset(.landscapeWide)
        styledPresentation.subjectPlacement = PresentationSubjectPlacement(
            fit: .contain,
            alignment: .bottomRight,
            scale: 0.88,
            offset: CGSize(width: 5, height: -4)
        )
        styledPresentation.frame = .browser(
            PresentationBrowserFrameStyle(
                title: "Version Six",
                address: "https://example.invalid/v6",
                scheme: .dark,
                showsTrafficLights: true
            )
        )
        styledPresentation.padding = 22
        styledPresentation.cornerRadius = 18
        styledPresentation.shadow = .medium
        styledPresentation.shadowBlurRadius = 34
        styledPresentation.shadowOffsetX = 4
        styledPresentation.shadowOffsetY = 12
        styledPresentation.shadowOpacity = 0.36
        styledPresentation.scene = scene

        var styleOnlyPresentation = styledPresentation
        styleOnlyPresentation.scene = nil
        styleOnlyPresentation.canvas = .original

        let cropRect = CGRect(x: 10, y: 10, width: 340, height: 240)
        let initial = makeEditorSnapshot(
            cropRect: cropRect,
            annotations: Array(annotations.prefix(4)),
            selectedAnnotationIDs: [annotations[0].id],
            nextCalloutNumber: 1
        )
        let undo = makeEditorSnapshot(
            cropRect: cropRect,
            annotations: Array(annotations.prefix(11)),
            selectedAnnotationIDs: [annotations[8].id, annotations[9].id],
            nextCalloutNumber: 5,
            presentation: styleOnlyPresentation,
            pinnedUIMapElementIDs: [pinnedElementID]
        )
        let current = makeEditorSnapshot(
            cropRect: cropRect,
            annotations: annotations,
            selectedAnnotationIDs: [
                annotations[3].id,
                annotations[12].id,
            ],
            nextCalloutNumber: 7,
            presentation: styledPresentation,
            pinnedUIMapElementIDs: [pinnedElementID]
        )
        let redo = makeEditorSnapshot(
            cropRect: CGRect(x: 12, y: 12, width: 336, height: 236),
            annotations: Array(annotations.dropFirst(4)),
            selectedAnnotationIDs: [annotations[15].id],
            nextCalloutNumber: 8,
            presentation: styleOnlyPresentation
        )
        var toolStyles = makeDefaultToolStyles()
        var rectangleToolStyle = toolStyles[.rectangle]!
        rectangleToolStyle.lineWidth = 9
        rectangleToolStyle.dashStyle = .dashed
        toolStyles[.rectangle] = rectangleToolStyle
        let savedPresentation = SavedPresentation(
            id: UUID(
                uuidString: "66000000-0000-0000-0000-000000000092"
            )!,
            name: "Legacy style",
            presentation: styleOnlyPresentation,
            createdAt: Date(timeIntervalSince1970: 1_700_000_061),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_062)
        )
        let session = makeEditorDocumentSession(
            initialSnapshot: initial,
            currentSnapshot: current,
            undoStack: [initial, undo],
            redoStack: [redo],
            toolStyles: toolStyles,
            savedPresentations: [savedPresentation]
        )

        try LegacyV6FixtureWriter.write(
            capture: capture,
            session: session,
            overlayAssets: [overlayAssetID: overlayImage],
            previewImage: image,
            to: packageURL
        )

        let v6Manifest = try manifestDictionary(at: packageURL)
        let v6Assets = try XCTUnwrap(v6Manifest["assets"] as? [String: Any])
        let v6Session = try XCTUnwrap(v6Manifest["session"] as? [String: Any])
        let v6Current = try XCTUnwrap(
            v6Session["currentSnapshot"] as? [String: Any]
        )
        XCTAssertEqual(v6Manifest["formatVersion"] as? Int, 6)
        XCTAssertNil(v6Manifest["privacy"])
        XCTAssertNil(v6Assets["captures"])
        XCTAssertNil(v6Current["composition"])
        XCTAssertEqual(
            (v6Assets["imageOverlays"] as? [[String: Any]])?.count,
            1
        )
        XCTAssertNotNil(
            (v6Manifest["capture"] as? [String: Any])?["uiMap"]
        )
        XCTAssertEqual(
            (v6Session["undoStack"] as? [[String: Any]])?.count,
            2
        )
        XCTAssertEqual(
            (v6Session["redoStack"] as? [[String: Any]])?.count,
            1
        )

        let loaded = try SSSDocumentPackage.load(from: packageURL)
        XCTAssertEqual(loaded.sourceFormatVersion, 6)
        XCTAssertFalse(loaded.isPrivate)
        XCTAssertEqual(loaded.capture.sourceName, capture.sourceName)
        XCTAssertEqual(loaded.capture.capturedAt, capture.capturedAt)
        XCTAssertEqual(loaded.capture.uiMap, uiMap)
        XCTAssertEqual(loaded.session.undoStack.count, 2)
        XCTAssertEqual(loaded.session.redoStack.count, 1)
        XCTAssertEqual(
            loaded.session.undoStack.map(\.annotations.count),
            [4, 11]
        )
        XCTAssertEqual(
            loaded.session.redoStack.map(\.annotations.count),
            [12]
        )
        XCTAssertEqual(
            loaded.session.undoStack.last?.presentation,
            styleOnlyPresentation
        )
        XCTAssertEqual(
            loaded.session.redoStack.first?.presentation,
            styleOnlyPresentation
        )
        XCTAssertEqual(loaded.session.savedPresentations, [savedPresentation])
        XCTAssertEqual(
            loaded.session.toolStyles[.rectangle],
            rectangleToolStyle
        )
        XCTAssertEqual(
            loaded.session.currentSnapshot.annotations.map(\.editorTool),
            [
                .rectangle,
                .ellipse,
                .line,
                .arrow,
                .statusMark,
                .freehand,
                .highlighter,
                .highlight,
                .text,
                .callout,
                .measure,
                .spotlight,
                .select,
                .blur,
                .pixelate,
                .redact,
            ]
        )
        guard case let .imageOverlay(loadedOverlay) =
            loaded.session.currentSnapshot.annotations[12].kind else {
            return XCTFail("Expected the v6 image-overlay annotation.")
        }
        XCTAssertEqual(loadedOverlay.assetID, overlayAssetID)
        XCTAssertEqual(loadedOverlay.image.width, overlayImage.width)
        XCTAssertEqual(loadedOverlay.image.height, overlayImage.height)
        XCTAssertEqual(
            loaded.session.currentSnapshot.presentation,
            styledPresentation
        )
        XCTAssertEqual(
            loaded.session.currentSnapshot.presentation.scene?.sceneID,
            scene.sceneID
        )

        let liftedAssetID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000701"
        )!
        let liftedItemID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000702"
        )!
        for snapshot in allSnapshots(in: loaded.session) {
            let composition = try XCTUnwrap(snapshot.composition)
            let item = try XCTUnwrap(composition.items.first)
            XCTAssertFalse(composition.isActivated)
            XCTAssertEqual(composition.items.count, 1)
            XCTAssertEqual(composition.selectedItemIDs, [liftedItemID])
            XCTAssertEqual(item.id, liftedItemID)
            XCTAssertEqual(item.assetID, liftedAssetID)
            XCTAssertEqual(item.editState.cropRect, snapshot.cropRect)
            XCTAssertEqual(item.editState.annotations, snapshot.annotations)
            XCTAssertEqual(
                item.editState.selectedAnnotationIDs,
                snapshot.selectedAnnotationIDs
            )
            XCTAssertEqual(
                item.editState.pinnedUIMapElementIDs,
                snapshot.pinnedUIMapElementIDs
            )
            XCTAssertTrue(composition.canvas.annotations.isEmpty)
        }
        XCTAssertEqual(
            loaded.compositionStoredAssets.map(\.descriptor.id),
            [liftedAssetID]
        )
        XCTAssertEqual(SSSDocumentPackage.compatibilityStatus(at: packageURL), .compatible)

        let v6Plain = try renderMigratedFixture(
            loaded,
            appearance: .plain
        )
        let v6Styled = try renderMigratedFixture(
            loaded,
            appearance: .styled
        )
        try SSSDocumentPackage.save(
            document: loaded,
            previewImage: v6Styled,
            to: migratedPackageURL
        )
        let reopened = try SSSDocumentPackage.load(from: migratedPackageURL)
        let v7Plain = try renderMigratedFixture(
            reopened,
            appearance: .plain
        )
        let v7Styled = try renderMigratedFixture(
            reopened,
            appearance: .styled
        )

        XCTAssertEqual(try manifestDictionary(at: packageURL)["formatVersion"] as? Int, 6)
        XCTAssertEqual(try manifestDictionary(at: migratedPackageURL)["formatVersion"] as? Int, 7)
        XCTAssertEqual(reopened.sourceFormatVersion, 7)
        XCTAssertEqual(reopened.session, loaded.session)
        XCTAssertEqual(reopened.capture.uiMap, uiMap)
        assertPixelEquivalent(v6Plain, v7Plain, label: "Plain")
        assertPixelEquivalent(v6Styled, v7Styled, label: "Styled Scene")
    }

    func testV7SaveCanonicalizesLegacySnapshotIntoDormantOneItemComposition() throws {
        let packageURL = temporaryPackageURL()
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let image = makeCoordinateImage(width: 32, height: 20)
        let annotation = Annotation.makeRectangle(
            in: CGRect(x: 3, y: 4, width: 10, height: 8),
            style: .default(for: .rectangle)
        )
        let snapshot = makeEditorSnapshot(
            cropRect: CGRect(x: 1, y: 2, width: 28, height: 16),
            annotations: [annotation]
        )

        try SSSDocumentPackage.save(
            document: makeEditableDocument(
                capture: makeCapturedScreenshot(image: image, sourceName: "Legacy in memory"),
                session: makeEditorDocumentSession(initialSnapshot: snapshot)
            ),
            previewImage: image,
            to: packageURL
        )

        let manifest = try manifestDictionary(at: packageURL)
        let session = try XCTUnwrap(manifest["session"] as? [String: Any])
        let current = try XCTUnwrap(session["currentSnapshot"] as? [String: Any])
        let composition = try XCTUnwrap(current["composition"] as? [String: Any])
        let captures = try XCTUnwrap(
            (manifest["assets"] as? [String: Any])?["captures"] as? [[String: Any]]
        )
        let loaded = try SSSDocumentPackage.load(from: packageURL)
        let loadedComposition = try XCTUnwrap(
            loaded.session.currentSnapshot.composition
        )

        XCTAssertEqual(composition["isActivated"] as? Bool, false)
        XCTAssertEqual((composition["items"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(captures.count, 1)
        XCTAssertFalse(loadedComposition.isActivated)
        XCTAssertEqual(loadedComposition.items.first?.editState.annotations, [annotation])
    }

    func testV7RoundTripPreservesCompositionAssetsAndEveryHistorySnapshot() throws {
        let packageURL = temporaryPackageURL()
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let primaryImage = makeCoordinateImage(width: 30, height: 18)
        let secondaryImage = makeCoordinateImage(
            width: 24,
            height: 32,
            pattern: .weighted(xMultiplier: 7, yMultiplier: 11, includeBlueSum: true)
        )
        let primaryAssetID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let secondaryAssetID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let primaryItem = CompositionItem(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            assetID: primaryAssetID,
            title: "Primary",
            caption: "Start",
            semanticRole: .before,
            zIndex: 2
        )
        let secondaryItem = CompositionItem(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            assetID: secondaryAssetID,
            editState: ScreenshotEditState(
                cropRect: CGRect(x: 2, y: 3, width: 18, height: 25),
                annotations: [
                    Annotation.makeRectangle(
                        in: CGRect(x: 4, y: 5, width: 8, height: 6),
                        style: .default(for: .rectangle)
                    )
                ],
                nextCalloutNumber: 2
            ),
            framing: CompositionItemFraming(
                contentMode: .fill,
                horizontalAlignment: .trailing,
                verticalAlignment: .bottom,
                scale: 1.25,
                offset: CGSize(width: 3, height: -2)
            ),
            opacity: 0.9,
            weight: 1.5,
            title: "Secondary",
            caption: "Finish",
            accessibilityLabel: "Finished state",
            semanticRole: .after,
            zIndex: 7
        )
        let canvasAnnotation = Annotation.makeLine(
            from: CGPoint(x: 10, y: 12),
            to: CGPoint(x: 42, y: 28)
        )

        var initial = makeEditorSnapshot(
            cropRect: CGRect(x: 0, y: 0, width: 30, height: 18)
        )
        initial.composition = CompositionSnapshot(
            items: [primaryItem],
            selectedItemIDs: [primaryItem.id]
        )
        var current = initial
        current.composition = CompositionSnapshot(
            items: [primaryItem, secondaryItem],
            selectedItemIDs: [secondaryItem.id],
            layout: CompositionLayoutConfiguration(
                mode: .steps,
                gridColumns: 2,
                targetAspectRatio: 16 / 9,
                sizingMode: .weighted,
                orientation: .landscape
            ),
            comparison: CompositionComparisonSettings(
                mode: .wipe,
                axis: .vertical,
                primaryItemID: primaryItem.id,
                secondaryItemID: secondaryItem.id,
                wipePosition: 0.4,
                primaryLabel: "Original",
                secondaryLabel: "Updated",
                showsLabels: true,
                keepsViewsLinked: false,
                registrationMode: .manual,
                manualRegistrationOffset: CGSize(width: 2.5, height: -1.25),
                registrationSensitivity: 0.7,
                unchangedContentOpacity: 0.15,
                differenceCueStyle: .pattern,
                blinkCrossfadeDuration: 0.1,
                blinkLoops: false,
                posterFrame: .primary
            ),
            steps: CompositionStepsSettings(
                axis: .horizontal,
                flow: .grid,
                gridColumns: 2,
                numberingStyle: .uppercaseRoman,
                startIndex: 3,
                showsCaptions: true,
                connectorStyle: .arrow,
                itemsPerPage: 6
            ),
            canvas: CompositionCanvasState(
                title: "Release flow",
                appearance: CompositionCanvasAppearance(
                    fill: .color(RGBAColor(red: 0.95, green: 0.96, blue: 0.98, alpha: 1)),
                    insets: CompositionInsets(18),
                    itemSpacing: 12,
                    captionFontSize: 15,
                    captionFontName: "Helvetica Neue",
                    captionFontWeight: .medium,
                    captionTextAlignment: .center,
                    captionPlacement: .overlayBottom,
                    titleColor: RGBAColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1),
                    titleBackgroundColor: RGBAColor(red: 1, green: 1, blue: 1, alpha: 0.5),
                    titleFontSize: 30,
                    titleFontName: "Avenir Next",
                    titleFontWeight: .bold,
                    titleTextAlignment: .center,
                    titleInsets: CompositionInsets(10)
                ),
                annotations: [canvasAnnotation],
                annotationAnchors: [
                    canvasAnnotation.id: CompositionAnnotationAnchors(
                        primary: CompositionAnnotationAnchor(
                            target: .canvasNormalized(
                                CGPoint(x: 0.1, y: 0.2)
                            ),
                            lastCanvasPoint: CGPoint(x: 10, y: 12)
                        ),
                        secondary: CompositionAnnotationAnchor(
                            target: .itemNormalized(
                                itemID: secondaryItem.id,
                                point: CGPoint(x: 0.75, y: 0.4)
                            ),
                            lastCanvasPoint: CGPoint(x: 42, y: 28)
                        )
                    )
                ]
            )
        )
        var redo = current
        redo.composition?.layout = CompositionLayoutConfiguration(mode: .compare)

        let session = makeEditorDocumentSession(
            initialSnapshot: initial,
            currentSnapshot: current,
            undoStack: [initial],
            redoStack: [redo]
        )
        let storedAssets = [
            try storedAsset(
                id: primaryAssetID,
                image: primaryImage,
                sourceName: "Primary source"
            ),
            try storedAsset(
                id: secondaryAssetID,
                image: secondaryImage,
                sourceName: "Secondary source"
            ),
        ]
        let document = EditableScreenshotDocument(
            capture: makeCapturedScreenshot(
                image: primaryImage,
                sourceName: "Primary source"
            ),
            session: session,
            compositionStoredAssets: storedAssets
        )

        try SSSDocumentPackage.save(
            document: document,
            previewImage: primaryImage,
            to: packageURL
        )
        let loaded = try SSSDocumentPackage.load(from: packageURL)
        let manifest = try manifestDictionary(at: packageURL)
        let assets = try XCTUnwrap(manifest["assets"] as? [String: Any])
        let captureRecords = try XCTUnwrap(assets["captures"] as? [[String: Any]])

        XCTAssertEqual(loaded.session, session)
        XCTAssertEqual(
            Set(loaded.compositionStoredAssets.map(\.descriptor.id)),
            Set([primaryAssetID, secondaryAssetID])
        )
        XCTAssertEqual(captureRecords.count, 2)
        for assetID in [primaryAssetID, secondaryAssetID] {
            let filename = "assets/captures/\(assetID.uuidString).png"
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: packageURL.appendingPathComponent(filename).path
                )
            )
        }
    }

    func testV7CompositionWrittenBeforeExpandedSchemaLoadsWithLockedDefaults() throws {
        let fixture = try makeSavedCompositionPackage()
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        try updateManifest(at: fixture.url) { manifest in
            var session = manifest["session"] as! [String: Any]
            for key in ["initialSnapshot", "currentSnapshot"] {
                var snapshot = session[key] as! [String: Any]
                stripExpandedCompositionKeys(from: &snapshot)
                session[key] = snapshot
            }
            for key in ["undoStack", "redoStack"] {
                var snapshots = session[key] as! [[String: Any]]
                for index in snapshots.indices {
                    stripExpandedCompositionKeys(from: &snapshots[index])
                }
                session[key] = snapshots
            }
            manifest["session"] = session
        }

        let loaded = try SSSDocumentPackage.load(from: fixture.url)
        let composition = try XCTUnwrap(
            loaded.session.currentSnapshot.composition
        )
        let item = try XCTUnwrap(composition.items.first)
        let appearance = composition.canvas.appearance

        XCTAssertEqual(item.semanticRole, .standard)
        XCTAssertEqual(item.zIndex, 0)
        XCTAssertTrue(composition.isActivated)
        XCTAssertEqual(composition.layout.sizingMode, .equal)
        XCTAssertEqual(composition.layout.orientation, .automatic)
        XCTAssertTrue(composition.comparison.showsLabels)
        XCTAssertTrue(composition.comparison.keepsViewsLinked)
        XCTAssertEqual(composition.comparison.registrationMode, .automatic)
        XCTAssertEqual(composition.comparison.manualRegistrationOffset, .zero)
        XCTAssertEqual(composition.comparison.registrationSensitivity, 0.5)
        XCTAssertEqual(composition.comparison.unchangedContentOpacity, 0.2)
        XCTAssertEqual(
            composition.comparison.differenceCueStyle,
            .outlineAndPattern
        )
        XCTAssertEqual(composition.comparison.blinkCrossfadeDuration, 0)
        XCTAssertTrue(composition.comparison.blinkLoops)
        XCTAssertEqual(composition.comparison.posterFrame, .secondary)
        XCTAssertEqual(composition.steps.flow, .column)
        XCTAssertEqual(composition.steps.gridColumns, 2)
        XCTAssertNil(composition.steps.itemsPerPage)
        XCTAssertNil(appearance.captionFontName)
        XCTAssertEqual(appearance.captionFontWeight, .regular)
        XCTAssertEqual(appearance.captionTextAlignment, .leading)
        XCTAssertEqual(appearance.captionPlacement, .below)
        XCTAssertEqual(appearance.titleFontSize, 28)
        XCTAssertNil(appearance.titleFontName)
        XCTAssertEqual(appearance.titleFontWeight, .semibold)
        XCTAssertEqual(appearance.titleTextAlignment, .leading)
        XCTAssertTrue(composition.canvas.annotationAnchors.isEmpty)
    }

    func testPartiallyExpandedV7CompositionPreservesPresentFieldsAndDefaultsMissingOnes() throws {
        let fixture = try makeSavedCompositionPackage()
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        try updateCurrentComposition(at: fixture.url) { composition in
            var layout = composition["layout"] as! [String: Any]
            layout["sizingMode"] = CompositionSizingMode.weighted.rawValue
            layout.removeValue(forKey: "orientation")
            composition["layout"] = layout

            var comparison = composition["comparison"] as! [String: Any]
            comparison["showsLabels"] = false
            comparison.removeValue(forKey: "registrationMode")
            composition["comparison"] = comparison

            var steps = composition["steps"] as! [String: Any]
            steps["flow"] = CompositionStepFlow.row.rawValue
            steps.removeValue(forKey: "gridColumns")
            composition["steps"] = steps

            var canvas = composition["canvas"] as! [String: Any]
            var appearance = canvas["appearance"] as! [String: Any]
            appearance["captionFontWeight"] =
                CompositionTextWeight.bold.rawValue
            appearance.removeValue(forKey: "titleFontWeight")
            canvas["appearance"] = appearance
            composition["canvas"] = canvas
        }

        let composition = try XCTUnwrap(
            SSSDocumentPackage.load(from: fixture.url)
                .session.currentSnapshot.composition
        )

        XCTAssertEqual(composition.layout.sizingMode, .weighted)
        XCTAssertEqual(composition.layout.orientation, .automatic)
        XCTAssertFalse(composition.comparison.showsLabels)
        XCTAssertEqual(composition.comparison.registrationMode, .automatic)
        XCTAssertEqual(composition.steps.flow, .row)
        XCTAssertEqual(composition.steps.gridColumns, 2)
        XCTAssertEqual(
            composition.canvas.appearance.captionFontWeight,
            .bold
        )
        XCTAssertEqual(
            composition.canvas.appearance.titleFontWeight,
            .semibold
        )
    }

    func testTraversalAssetPathIsRejectedBeforeReadingOutsidePackage() throws {
        let packageURL = try makeSavedPublicPackage()
        defer { try? FileManager.default.removeItem(at: packageURL) }

        try updateManifest(at: packageURL) { manifest in
            var assets = manifest["assets"] as! [String: Any]
            assets["baseImage"] = "../outside.png"
            manifest["assets"] = assets
        }

        XCTAssertThrowsError(try SSSDocumentPackage.load(from: packageURL)) { error in
            guard case SSSDocumentError.invalidAssetPath("../outside.png") = error else {
                return XCTFail("Expected invalid traversal path, got \(error)")
            }
        }
    }

    func testNormalDocumentCannotOptIntoTrustedRecoveryBaseEscape() throws {
        let packageURL = try makeSavedPublicPackage()
        defer { try? FileManager.default.removeItem(at: packageURL) }

        try updateManifest(at: packageURL) { manifest in
            var assets = manifest["assets"] as! [String: Any]
            assets["baseImage"] = "../../base.png"
            manifest["assets"] = assets
        }

        XCTAssertThrowsError(try SSSDocumentPackage.load(from: packageURL)) { error in
            guard case SSSDocumentError.invalidAssetPath("../../base.png") = error else {
                return XCTFail("Expected normal-open recovery-path rejection, got \(error)")
            }
        }
    }

    func testCompositionCaptureTraversalPathIsRejected() throws {
        let fixture = try makeSavedCompositionPackage()
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        try updateManifest(at: fixture.url) { manifest in
            var assets = manifest["assets"] as! [String: Any]
            var captures = assets["captures"] as! [[String: Any]]
            captures[0]["filename"] = "../outside.png"
            assets["captures"] = captures
            manifest["assets"] = assets
        }

        XCTAssertThrowsError(try SSSDocumentPackage.load(from: fixture.url)) { error in
            guard case SSSDocumentError.invalidAssetPath("../outside.png") = error else {
                return XCTFail("Expected invalid composition traversal path, got \(error)")
            }
        }
    }

    func testMissingCompositionCaptureRetainsPanelAndMarksAssetMissing() throws {
        let fixture = try makeSavedCompositionPackage()
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        try FileManager.default.removeItem(
            at: fixture.url.appendingPathComponent(
                "assets/captures/\(fixture.assetID.uuidString).png"
            )
        )

        let loaded = try SSSDocumentPackage.load(from: fixture.url)
        let stored = try XCTUnwrap(loaded.compositionStoredAssets.first)

        XCTAssertEqual(stored.descriptor.id, fixture.assetID)
        XCTAssertEqual(stored.availability, .missing)
        XCTAssertNil(stored.encodedPNG)
        XCTAssertEqual(
            loaded.session.currentSnapshot.composition?.items.map(\.assetID),
            [fixture.assetID]
        )
    }

    func testOversizedCompositionCaptureRetainsPanelAndMarksAssetCorrupt() throws {
        let fixture = try makeSavedCompositionPackage()
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        let oversized = makeSolidImage(
            width: SSSDocumentPackage.maximumImageDimension + 1,
            height: 1,
            color: PixelSample(red: 80, green: 20, blue: 140, alpha: 255)
        )
        try ImageExporter.pngData(for: oversized).write(
            to: fixture.url.appendingPathComponent(
                "assets/captures/\(fixture.assetID.uuidString).png"
            ),
            options: .atomic
        )

        let loaded = try SSSDocumentPackage.load(from: fixture.url)
        let stored = try XCTUnwrap(loaded.compositionStoredAssets.first)

        XCTAssertEqual(stored.descriptor.id, fixture.assetID)
        XCTAssertEqual(stored.availability, .corrupt)
        XCTAssertNil(stored.encodedPNG)
        XCTAssertEqual(
            loaded.session.currentSnapshot.composition?.items.map(\.assetID),
            [fixture.assetID]
        )
    }

    func testSymlinkedAssetThatEscapesPackageIsRejected() throws {
        let packageURL = try makeSavedPublicPackage()
        let externalURL = packageURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(UUID().uuidString)-outside.png")
        defer {
            try? FileManager.default.removeItem(at: packageURL)
            try? FileManager.default.removeItem(at: externalURL)
        }

        let baseURL = packageURL.appendingPathComponent("base.png")
        try FileManager.default.moveItem(at: baseURL, to: externalURL)
        try FileManager.default.createSymbolicLink(at: baseURL, withDestinationURL: externalURL)

        XCTAssertThrowsError(try SSSDocumentPackage.load(from: packageURL)) { error in
            guard case SSSDocumentError.invalidAssetPath("base.png") = error else {
                return XCTFail("Expected escaping symlink rejection, got \(error)")
            }
        }
    }

    func testImageExceedingDimensionGuardIsRejectedWithoutOpeningDocument() throws {
        let packageURL = try makeSavedPublicPackage()
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let oversized = makeSolidImage(
            width: SSSDocumentPackage.maximumImageDimension + 1,
            height: 1,
            color: PixelSample(red: 20, green: 40, blue: 60, alpha: 255)
        )
        let oversizedData = try ImageExporter.pngData(for: oversized)
        try oversizedData.write(
            to: packageURL.appendingPathComponent("base.png"),
            options: .atomic
        )

        XCTAssertThrowsError(try SSSDocumentPackage.load(from: packageURL)) { error in
            guard case SSSDocumentError.oversizedImage("base.png") = error else {
                return XCTFail("Expected oversized-image rejection, got \(error)")
            }
        }
    }

    func testOversizedEncodedBaseIsRejectedBeforeItIsReadOrDecoded() throws {
        let packageURL = try makeSavedPublicPackage()
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let baseURL = packageURL.appendingPathComponent(
            SSSDocumentPackage.baseImageFilename
        )
        try replaceWithSparseFile(
            at: baseURL,
            byteCount: SSSDocumentPackage.maximumEncodedImageAssetBytes + 1
        )

        XCTAssertThrowsError(try SSSDocumentPackage.load(from: packageURL)) {
            guard case SSSDocumentError.oversizedImage(
                SSSDocumentPackage.baseImageFilename
            ) = $0 else {
                return XCTFail(
                    "Expected encoded-size preflight rejection, got \($0)"
                )
            }
        }
    }

    func testOversizedEncodedOverlayIsRejectedBeforeBaseImagePreflight() throws {
        let packageURL = try makeSavedPublicPackage()
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let overlayID = UUID()
        let overlayFilename =
            "assets/image-overlays/\(overlayID.uuidString).png"
        try updateManifest(at: packageURL) { manifest in
            var assets = manifest["assets"] as! [String: Any]
            assets["imageOverlays"] = [
                [
                    "id": overlayID.uuidString,
                    "filename": overlayFilename,
                ],
            ]
            manifest["assets"] = assets
        }
        try replaceWithSparseFile(
            at: packageURL.appendingPathComponent(overlayFilename),
            byteCount: SSSDocumentPackage.maximumEncodedImageAssetBytes + 1
        )
        try Data("not an image".utf8).write(
            to: packageURL.appendingPathComponent(
                SSSDocumentPackage.baseImageFilename
            ),
            options: .atomic
        )

        XCTAssertThrowsError(try SSSDocumentPackage.load(from: packageURL)) {
            guard case SSSDocumentError.oversizedImage(
                overlayFilename
            ) = $0 else {
                return XCTFail(
                    "Expected overlay size rejection before image headers, got \($0)"
                )
            }
        }
    }

    func testAggregateEncodedBudgetIncludesBaseAndAllCaptureFiles() throws {
        let fixture = try makeSavedCompositionPackage()
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        let perFileBytes =
            SSSDocumentPackage.maximumAggregateImageAssetBytes / 4 + 1
        var addedFiles: [URL] = []
        try updateManifest(at: fixture.url) { manifest in
            var assets = manifest["assets"] as! [String: Any]
            var captures = assets["captures"] as! [[String: Any]]
            let prototype = captures[0]
            for _ in 0..<4 {
                let id = UUID()
                let filename = "assets/captures/\(id.uuidString).png"
                var record = prototype
                var descriptor = record["descriptor"] as! [String: Any]
                record["id"] = id.uuidString
                record["filename"] = filename
                descriptor["id"] = id.uuidString
                record["descriptor"] = descriptor
                captures.append(record)

                let fileURL = fixture.url.appendingPathComponent(filename)
                try replaceWithSparseFile(
                    at: fileURL,
                    byteCount: perFileBytes
                )
                addedFiles.append(fileURL)
            }
            assets["captures"] = captures
            manifest["assets"] = assets
        }
        XCTAssertEqual(addedFiles.count, 4)

        XCTAssertThrowsError(try SSSDocumentPackage.load(from: fixture.url)) {
            guard case SSSDocumentError.compositionAssetsTooLarge = $0 else {
                return XCTFail(
                    "Expected aggregate encoded-size rejection, got \($0)"
                )
            }
        }
    }

    func testAggregateDecodedPixelBudgetUsesImageHeadersBeforeReadingCaptures() throws {
        let fixture = try makeSavedCompositionPackage()
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        let width = 16_384
        let height = 16_384
        let declaredPNG = try monochromePNGData(
            width: width,
            height: height
        )
        let propertySource = try XCTUnwrap(
            CGImageSourceCreateWithData(declaredPNG as CFData, nil)
        )
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(
                propertySource,
                0,
                nil
            ) as? [CFString: Any]
        )
        XCTAssertEqual(
            (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            width
        )
        XCTAssertEqual(
            (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            height
        )

        try updateManifest(at: fixture.url) { manifest in
            var assets = manifest["assets"] as! [String: Any]
            var captures = assets["captures"] as! [[String: Any]]
            let prototype = captures[0]
            for _ in 0..<4 {
                let id = UUID()
                let filename = "assets/captures/\(id.uuidString).png"
                var record = prototype
                var descriptor = record["descriptor"] as! [String: Any]
                record["id"] = id.uuidString
                record["filename"] = filename
                descriptor["id"] = id.uuidString
                descriptor["pixelWidth"] = width
                descriptor["pixelHeight"] = height
                record["descriptor"] = descriptor
                captures.append(record)
                try declaredPNG.write(
                    to: fixture.url.appendingPathComponent(filename),
                    options: .atomic
                )
            }
            assets["captures"] = captures
            manifest["assets"] = assets
        }

        XCTAssertThrowsError(try SSSDocumentPackage.load(from: fixture.url)) {
            guard case SSSDocumentError.compositionAssetsTooLarge = $0 else {
                return XCTFail(
                    "Expected aggregate decoded-pixel rejection, got \($0)"
                )
            }
        }
    }

    func testEagerDecodedPixelBudgetIncludesBaseAndOverlays() throws {
        let packageURL = try makeSavedPublicPackage()
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let width = 16_384
        let height = 16_384
        let declaredPNG = try monochromePNGData(
            width: width,
            height: height
        )
        let overlayID = UUID()
        let overlayFilename =
            "assets/image-overlays/\(overlayID.uuidString).png"
        try updateManifest(at: packageURL) { manifest in
            var assets = manifest["assets"] as! [String: Any]
            assets["imageOverlays"] = [
                [
                    "id": overlayID.uuidString,
                    "filename": overlayFilename,
                ],
            ]
            manifest["assets"] = assets
        }
        try declaredPNG.write(
            to: packageURL.appendingPathComponent(
                SSSDocumentPackage.baseImageFilename
            ),
            options: .atomic
        )
        try FileManager.default.createDirectory(
            at: packageURL.appendingPathComponent(
                SSSDocumentPackage.imageOverlayAssetsDirectoryName,
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )
        try declaredPNG.write(
            to: packageURL.appendingPathComponent(overlayFilename),
            options: .atomic
        )

        XCTAssertThrowsError(try SSSDocumentPackage.load(from: packageURL)) {
            guard case SSSDocumentError.compositionAssetsTooLarge = $0 else {
                return XCTFail(
                    "Expected eager decoded-pixel rejection, got \($0)"
                )
            }
        }
    }

    func testInvalidPresentationGeometryIsRejectedBeforeBaseImagePreflight() throws {
        let packageURL = try makeSavedPublicPackage()
        defer { try? FileManager.default.removeItem(at: packageURL) }

        try updateManifest(at: packageURL) { manifest in
            var session = manifest["session"] as! [String: Any]
            var current = session["currentSnapshot"] as! [String: Any]
            var presentation = current["presentation"] as! [String: Any]
            var style = presentation["style"] as! [String: Any]
            style["padding"] =
                SSSDocumentPackage.maximumGeometryMagnitude * 2
            presentation["style"] = style
            current["presentation"] = presentation
            session["currentSnapshot"] = current
            manifest["session"] = session
        }
        try Data("not an image".utf8).write(
            to: packageURL.appendingPathComponent(
                SSSDocumentPackage.baseImageFilename
            ),
            options: .atomic
        )

        XCTAssertThrowsError(try SSSDocumentPackage.load(from: packageURL)) {
            guard case SSSDocumentError.invalidComposition(let reason) = $0,
                  reason.contains("Presentation style geometry") else {
                return XCTFail(
                    "Expected Presentation validation before decode, got \($0)"
                )
            }
        }
    }

    func testOversizedCustomPresentationCanvasIsRejected() throws {
        let packageURL = try makeSavedPublicPackage()
        defer { try? FileManager.default.removeItem(at: packageURL) }

        try updateManifest(at: packageURL) { manifest in
            var session = manifest["session"] as! [String: Any]
            var current = session["currentSnapshot"] as! [String: Any]
            var presentation = current["presentation"] as! [String: Any]
            presentation["canvas"] = [
                "kind": "custom",
                "width":
                    SSSDocumentPackage.maximumPersistedFixedOutputDimension
                    + 1,
                "height": 100,
            ]
            current["presentation"] = presentation
            session["currentSnapshot"] = current
            manifest["session"] = session
        }

        XCTAssertThrowsError(try SSSDocumentPackage.load(from: packageURL)) {
            guard case SSSDocumentError.invalidComposition(let reason) = $0,
                  reason.contains("Presentation output dimensions") else {
                return XCTFail(
                    "Expected custom-canvas rejection, got \($0)"
                )
            }
        }
    }

    func testOversizedCompositionCanvasIsRejectedBeforeImageDecode() throws {
        let fixture = try makeSavedCompositionPackage()
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        try updateCurrentComposition(at: fixture.url) { composition in
            var layout = composition["layout"] as! [String: Any]
            layout["mode"] = "freeform"
            layout["freeformCanvasSize"] = [
                SSSDocumentPackage.maximumComputedPresentationDimension + 1,
                100,
            ]
            composition["layout"] = layout
        }
        try Data("not an image".utf8).write(
            to: fixture.url.appendingPathComponent(
                SSSDocumentPackage.baseImageFilename
            ),
            options: .atomic
        )

        XCTAssertThrowsError(try SSSDocumentPackage.load(from: fixture.url)) {
            guard case SSSDocumentError.invalidComposition(let reason) = $0,
                  reason.contains("Presentation output dimensions") else {
                return XCTFail(
                    "Expected composition canvas rejection before decode, got \($0)"
                )
            }
        }
    }

    func testOversizedPersistedSceneCanvasIsRejectedBeforeImageDecode() throws {
        let packageURL = temporaryPackageURL()
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let image = makeCoordinateImage(width: 24, height: 16)
        let sceneID = "builtin.package-resource-guard"
        let validSVG = presentationSceneSVG(
            id: sceneID,
            width: 200,
            height: 120
        )
        let validScene = try PresentationSceneValidator.validate(
            svgText: validSVG,
            source: .bundled
        )
        var presentation = ScreenshotPresentationPreset.lifted.settings
        presentation.scene = AppliedPresentationScene(
            sceneID: sceneID,
            name: "Package Resource Guard",
            version: 1,
            sanitizedSVGText: validScene.sanitizedSVGText,
            textSlotValues: [:]
        )
        let snapshot = makeEditorSnapshot(
            cropRect: CGRect(x: 0, y: 0, width: 24, height: 16),
            presentation: presentation
        )
        try SSSDocumentPackage.save(
            document: makeEditableDocument(
                capture: makeCapturedScreenshot(image: image),
                session: makeEditorDocumentSession(initialSnapshot: snapshot)
            ),
            previewImage: image,
            to: packageURL
        )

        let oversizedSVG = presentationSceneSVG(
            id: sceneID,
            width:
                SSSDocumentPackage.maximumPersistedFixedOutputDimension + 1,
            height: 120
        )
        try updateManifest(at: packageURL) { manifest in
            var session = manifest["session"] as! [String: Any]
            var current = session["currentSnapshot"] as! [String: Any]
            var storedPresentation =
                current["presentation"] as! [String: Any]
            var scene = storedPresentation["scene"] as! [String: Any]
            scene["sanitizedSVGText"] = oversizedSVG
            storedPresentation["scene"] = scene
            current["presentation"] = storedPresentation
            session["currentSnapshot"] = current
            manifest["session"] = session
        }
        try Data("not an image".utf8).write(
            to: packageURL.appendingPathComponent(
                SSSDocumentPackage.baseImageFilename
            ),
            options: .atomic
        )

        XCTAssertThrowsError(try SSSDocumentPackage.load(from: packageURL)) {
            guard case SSSDocumentError.invalidComposition(let reason) = $0,
                  reason.contains("Presentation output dimensions") else {
                return XCTFail(
                    "Expected Scene canvas rejection before decode, got \($0)"
                )
            }
        }
    }

    func testNonfiniteSavedPresentationGeometryIsRejectedBeforeWriting() throws {
        let packageURL = temporaryPackageURL()
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let image = makeCoordinateImage(width: 24, height: 16)
        var presentation = ScreenshotPresentationPreset.lifted.settings
        presentation.subjectPlacement.offset = CGSize(
            width: CGFloat.nan,
            height: 0
        )
        let snapshot = makeEditorSnapshot(
            cropRect: CGRect(x: 0, y: 0, width: 24, height: 16),
            presentation: presentation
        )
        let document = makeEditableDocument(
            capture: makeCapturedScreenshot(image: image),
            session: makeEditorDocumentSession(initialSnapshot: snapshot)
        )

        XCTAssertThrowsError(
            try SSSDocumentPackage.save(
                document: document,
                previewImage: image,
                to: packageURL
            )
        ) {
            guard case SSSDocumentError.invalidComposition(let reason) = $0,
                  reason.contains("Presentation subject offset") else {
                return XCTFail(
                    "Expected nonfinite Presentation rejection, got \($0)"
                )
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: packageURL.path))
    }

    func testDuplicateCompositionItemIDsAreRejectedAcrossDecodedSnapshots() throws {
        let fixture = try makeSavedCompositionPackage()
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        try updateCurrentComposition(at: fixture.url) { composition in
            var items = composition["items"] as! [[String: Any]]
            items.append(items[0])
            composition["items"] = items
        }

        XCTAssertThrowsError(try SSSDocumentPackage.load(from: fixture.url)) {
            guard case SSSDocumentError.invalidComposition(let reason) = $0,
                  reason.contains("duplicate composition item") else {
                return XCTFail("Expected duplicate item rejection, got \($0)")
            }
        }
    }

    func testCompositionItemReferenceToUndeclaredAssetIsRejected() throws {
        let fixture = try makeSavedCompositionPackage()
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        let undeclaredID = UUID()
        try updateCurrentComposition(at: fixture.url) { composition in
            var items = composition["items"] as! [[String: Any]]
            items[0]["assetID"] = undeclaredID.uuidString
            composition["items"] = items
        }

        XCTAssertThrowsError(try SSSDocumentPackage.load(from: fixture.url)) {
            guard case SSSDocumentError.invalidComposition(let reason) = $0,
                  reason.contains("undeclared asset") else {
                return XCTFail("Expected undeclared asset rejection, got \($0)")
            }
        }
    }

    func testComparisonSelectorsMustBeExplicitDistinctIncludedItems() throws {
        let fixture = try makeSavedCompositionPackage()
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        try updateCurrentComposition(at: fixture.url) { composition in
            var items = composition["items"] as! [[String: Any]]
            var second = items[0]
            second["id"] = UUID().uuidString
            items.append(second)
            composition["items"] = items

            var layout = composition["layout"] as! [String: Any]
            layout["mode"] = CompositionLayoutMode.compare.rawValue
            composition["layout"] = layout

            var comparison = composition["comparison"] as! [String: Any]
            comparison["primaryItemID"] = items[0]["id"]
            comparison["secondaryItemID"] = UUID().uuidString
            composition["comparison"] = comparison
        }

        XCTAssertThrowsError(try SSSDocumentPackage.load(from: fixture.url)) {
            guard case SSSDocumentError.invalidComposition(let reason) = $0,
                  reason.contains("selectors") else {
                return XCTFail("Expected comparison selector rejection, got \($0)")
            }
        }
    }

    func testCompositionGeometryOutsideSafeBoundsIsRejected() throws {
        let fixture = try makeSavedCompositionPackage()
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        try updateCurrentComposition(at: fixture.url) { composition in
            var items = composition["items"] as! [[String: Any]]
            items[0]["freeformFrame"] = [
                "x": SSSDocumentPackage.maximumGeometryMagnitude * 2,
                "y": 0,
                "width": 100,
                "height": 100,
            ]
            composition["items"] = items
        }

        XCTAssertThrowsError(try SSSDocumentPackage.load(from: fixture.url)) {
            guard case SSSDocumentError.invalidComposition(let reason) = $0,
                  reason.contains("freeform item frame") else {
                return XCTFail("Expected geometry rejection, got \($0)")
            }
        }
    }

    func testCompositionAnchorCannotReferenceUnknownItem() throws {
        let fixture = try makeSavedCompositionPackage()
        let destinationURL = temporaryPackageURL()
        defer {
            try? FileManager.default.removeItem(at: fixture.url)
            try? FileManager.default.removeItem(at: destinationURL)
        }

        var document = try SSSDocumentPackage.load(from: fixture.url)
        var composition = try XCTUnwrap(
            document.session.currentSnapshot.composition
        )
        let annotation = Annotation.makeLine(
            from: CGPoint(x: 2, y: 3),
            to: CGPoint(x: 8, y: 9)
        )
        composition.canvas.annotations = [annotation]
        composition.canvas.annotationAnchors = [
            annotation.id: CompositionAnnotationAnchors(
                primary: CompositionAnnotationAnchor(
                    target: .itemNormalized(
                        itemID: UUID(),
                        point: CGPoint(x: 0.25, y: 0.75)
                    ),
                    lastCanvasPoint: CGPoint(x: 2, y: 3)
                ),
                secondary: nil
            ),
        ]
        document.session.currentSnapshot.composition = composition

        XCTAssertThrowsError(
            try SSSDocumentPackage.save(
                document: document,
                previewImage: document.capture.image,
                to: destinationURL
            )
        ) {
            guard case SSSDocumentError.invalidComposition(let reason) = $0,
                  reason.contains("unknown composition item") else {
                return XCTFail("Expected unknown anchor item rejection, got \($0)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    func testExcessiveUndoSnapshotAggregateIsRejectedWithoutCreatingDestination() throws {
        let fixture = try makeSavedCompositionPackage()
        let destinationURL = temporaryPackageURL()
        defer {
            try? FileManager.default.removeItem(at: fixture.url)
            try? FileManager.default.removeItem(at: destinationURL)
        }

        var document = try SSSDocumentPackage.load(from: fixture.url)
        document.session.undoStack = Array(
            repeating: document.session.currentSnapshot,
            count: SSSDocumentPackage.maximumSnapshotCount
        )

        XCTAssertThrowsError(
            try SSSDocumentPackage.save(
                document: document,
                previewImage: document.capture.image,
                to: destinationURL
            )
        ) {
            guard case SSSDocumentError.invalidComposition(let reason) = $0,
                  reason.contains("too many undo or redo") else {
                return XCTFail("Expected aggregate snapshot rejection, got \($0)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    private func representativeLegacyAnnotations(
        overlayImage: CGImage,
        overlayAssetID: UUID
    ) -> [Annotation] {
        func identified(
            _ suffix: Int,
            _ annotation: Annotation,
            rotation: CGFloat = 0
        ) -> Annotation {
            Annotation(
                id: UUID(
                    uuidString: String(
                        format:
                            "66000000-0000-0000-0000-%012X",
                        suffix
                    )
                )!,
                groupID: suffix <= 2
                    ? UUID(
                        uuidString:
                            "66000000-0000-0000-0000-000000000080"
                    )
                    : nil,
                kind: annotation.kind,
                style: annotation.style,
                rotationDegrees: rotation
            )
        }

        var rectangleStyle = AnnotationStyle.default(for: .rectangle)
        rectangleStyle.lineWidth = 5
        rectangleStyle.cornerRadius = 8
        rectangleStyle.dashStyle = .dashed

        var arrow = Annotation.makeArrow(
            from: CGPoint(x: 220, y: 25),
            to: CGPoint(x: 320, y: 55)
        )
        arrow = arrow.updatingArrow(
            curvature: 0.18,
            headStyle: .double,
            label: "Legacy arrow",
            labelBoxColor: RGBAColor(
                red: 0.05,
                green: 0.05,
                blue: 0.08,
                alpha: 0.75
            ),
            labelPlacement: .parallelAbove,
            labelFontSize: 13,
            labelTextColor: .complementary,
            headShape: .triangle
        )

        var callout = Annotation.makeCallout(
            at: CGPoint(x: 102, y: 145),
            number: 4
        )
        callout = callout
            .updatingText("Legacy callout")
            .updatingTextAlignment(.center)
            .updatingCalloutStyle(.outlined)

        return [
            identified(
                1,
                Annotation.makeRectangle(
                    in: CGRect(x: 20, y: 20, width: 50, height: 34),
                    style: rectangleStyle
                ),
                rotation: 5
            ),
            identified(
                2,
                Annotation.makeEllipse(
                    in: CGRect(x: 82, y: 20, width: 48, height: 34)
                ),
                rotation: -7
            ),
            identified(
                3,
                Annotation.makeLine(
                    from: CGPoint(x: 145, y: 22),
                    to: CGPoint(x: 205, y: 52)
                )
            ),
            identified(4, arrow),
            identified(
                5,
                Annotation.makeStatusMark(
                    in: CGRect(x: 24, y: 74, width: 34, height: 34)
                )
            ),
            identified(
                6,
                Annotation.makeFreehand(
                    points: [
                        CGPoint(x: 80, y: 96),
                        CGPoint(x: 94, y: 78),
                        CGPoint(x: 110, y: 100),
                        CGPoint(x: 130, y: 82),
                    ]
                )
            ),
            identified(
                7,
                Annotation.makeHighlighter(
                    points: [
                        CGPoint(x: 145, y: 90),
                        CGPoint(x: 165, y: 82),
                        CGPoint(x: 185, y: 96),
                        CGPoint(x: 207, y: 84),
                    ]
                )
            ),
            identified(
                8,
                Annotation.makeHighlight(
                    in: CGRect(x: 222, y: 76, width: 56, height: 28)
                )
            ),
            identified(
                9,
                Annotation(
                    id: UUID(),
                    groupID: nil,
                    kind: .text(
                        TextShape(
                            rect: CGRect(
                                x: 20,
                                y: 120,
                                width: 76,
                                height: 36
                            ),
                            text: "Legacy text",
                            alignment: .right,
                            automaticallySizesToText: false
                        )
                    ),
                    style: .default(for: .text)
                )
            ),
            identified(10, callout),
            identified(
                11,
                Annotation.makeMeasurement(
                    from: CGPoint(x: 270, y: 118),
                    to: CGPoint(x: 330, y: 155)
                ),
                rotation: -4
            ),
            identified(
                12,
                Annotation.makeSpotlight(
                    in: CGRect(x: 20, y: 174, width: 60, height: 44)
                )
            ),
            identified(
                13,
                Annotation.makeImageOverlay(
                    image: overlayImage,
                    in: CGRect(x: 96, y: 176, width: 42, height: 32),
                    assetID: overlayAssetID,
                    role: .capturedCursor
                ),
                rotation: 9
            ),
            identified(
                14,
                Annotation.makeBlur(
                    in: CGRect(x: 152, y: 176, width: 42, height: 32)
                )
            ),
            identified(
                15,
                Annotation.makePixelate(
                    in: CGRect(x: 208, y: 176, width: 42, height: 32)
                )
            ),
            identified(
                16,
                Annotation.makeSolidRedaction(
                    in: CGRect(x: 264, y: 176, width: 42, height: 32)
                )
            ),
        ]
    }

    private func legacyMigrationSceneSVG() -> String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" width="480" height="320" viewBox="0 0 480 320">
          <metadata id="snipsnipsnip-scene">
        {
          "schema": "\(PresentationSceneMetadata.schema)",
          "schemaVersion": \(PresentationSceneMetadata.supportedSchemaVersion),
          "id": "builtin.legacy-v6-migration-fixture",
          "name": "Legacy V6 Migration Fixture",
          "version": 1,
          "canvas": { "width": 480, "height": 320 },
          "slots": [
            {
              "id": "primaryScreenshot",
              "type": "image",
              "required": true,
              "label": "Screenshot",
              "defaultFraming": "showFull"
            }
          ]
        }
          </metadata>
          <rect x="0" y="0" width="480" height="320" fill="#172033"/>
          <image data-sss-slot="primaryScreenshot" href="snipsnipsnip:primaryScreenshot" x="24" y="20" width="432" height="280"/>
        </svg>
        """
    }

    private func allSnapshots(
        in session: EditorDocumentSession
    ) -> [EditorSnapshot] {
        [session.initialSnapshot, session.currentSnapshot]
            + session.undoStack
            + session.redoStack
    }

    private func renderMigratedFixture(
        _ document: EditableScreenshotDocument,
        appearance: ScreenshotOutputAppearance
    ) throws -> CGImage {
        var snapshot = document.session.currentSnapshot
        if appearance == .plain {
            snapshot.presentation = .plain
        }
        let pinnedElements = snapshot.pinnedUIMapElementIDs.compactMap {
            document.capture.uiMap?.element(matching: $0)
        }
        return try CompositionOutputExporter.staticImage(
            CompositionOutputInput(
                baseImage: document.capture.image,
                snapshot: snapshot,
                compositionAssets: [:],
                compositionAssetRepository: CompositionAssetRepository(
                    storedAssets: document.compositionStoredAssets
                ),
                pinnedUIMapElements: pinnedElements,
                appearance: appearance
            )
        )
    }

    private func assertPixelEquivalent(
        _ lhs: CGImage,
        _ rhs: CGImage,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.width, rhs.width, "\(label) width", file: file, line: line)
        XCTAssertEqual(lhs.height, rhs.height, "\(label) height", file: file, line: line)
        guard lhs.width == rhs.width, lhs.height == rhs.height,
              let lhsPixels = normalizedRGBAPixels(lhs),
              let rhsPixels = normalizedRGBAPixels(rhs) else {
            return
        }
        guard let mismatch = lhsPixels.indices.first(
            where: { lhsPixels[$0] != rhsPixels[$0] }
        ) else {
            return
        }
        let pixelIndex = mismatch / 4
        XCTFail(
            "\(label) differs at (\(pixelIndex % lhs.width), \(pixelIndex / lhs.width)), channel \(mismatch % 4): \(lhsPixels[mismatch]) != \(rhsPixels[mismatch])",
            file: file,
            line: line
        )
    }

    private func normalizedRGBAPixels(_ image: CGImage) -> [UInt8]? {
        let bytesPerRow = image.width * 4
        var pixels = [UInt8](
            repeating: 0,
            count: bytesPerRow * image.height
        )
        let rendered = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let baseAddress = storage.baseAddress,
                  let colorSpace = CGColorSpace(
                    name: CGColorSpace.sRGB
                  ),
                  let context = CGContext(
                    data: baseAddress,
                    width: image.width,
                    height: image.height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo:
                        CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return false
            }
            context.interpolationQuality = .none
            context.draw(
                image,
                in: CGRect(
                    x: 0,
                    y: 0,
                    width: image.width,
                    height: image.height
                )
            )
            return true
        }
        return rendered ? pixels : nil
    }

    private func temporaryPackageURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sss")
    }

    private func replaceWithSparseFile(
        at url: URL,
        byteCount: UInt64
    ) throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: url.path,
                contents: nil
            )
        )
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: byteCount)
        try handle.close()
    }

    private func presentationSceneSVG(
        id: String,
        width: Int,
        height: Int
    ) -> String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="\(height)" viewBox="0 0 \(width) \(height)">
          <metadata id="snipsnipsnip-scene">
        {
          "schema": "\(PresentationSceneMetadata.schema)",
          "schemaVersion": \(PresentationSceneMetadata.supportedSchemaVersion),
          "id": "\(id)",
          "name": "Package Resource Guard",
          "version": 1,
          "canvas": { "width": \(width), "height": \(height) },
          "slots": [
            {"id":"primaryScreenshot","type":"image","required":true,"label":"Screenshot"}
          ]
        }
          </metadata>
          <image data-sss-slot="primaryScreenshot" href="snipsnipsnip:primaryScreenshot" x="0" y="0" width="\(width)" height="\(height)"/>
        </svg>
        """
    }

    private func monochromePNGData(
        width: Int,
        height: Int
    ) throws -> Data {
        let bytesPerRow = (width + 7) / 8
        let storage = Data(
            repeating: 0,
            count: bytesPerRow * height
        )
        guard let provider = CGDataProvider(data: storage as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 1,
                  bitsPerPixel: 1,
                  bytesPerRow: bytesPerRow,
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGBitmapInfo(
                      rawValue: CGImageAlphaInfo.none.rawValue
                  ),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            throw SSSDocumentError.invalidImageData
        }
        return try ImageExporter.pngData(for: image)
    }

    private func makeSavedPublicPackage() throws -> URL {
        let packageURL = temporaryPackageURL()
        let image = makeCoordinateImage(width: 24, height: 16)
        try SSSDocumentPackage.save(
            document: makeEditableDocument(
                capture: makeCapturedScreenshot(image: image),
                session: makeEditorDocumentSession(
                    initialSnapshot: makeEditorSnapshot(
                        cropRect: CGRect(x: 0, y: 0, width: 24, height: 16)
                    )
                )
            ),
            previewImage: image,
            to: packageURL
        )
        return packageURL
    }

    private func makeSavedCompositionPackage(
        privateAsset: Bool = false
    ) throws -> (url: URL, assetID: UUID) {
        let packageURL = temporaryPackageURL()
        let rootImage = makeCoordinateImage(width: 24, height: 16)
        let compositionImage = makeCoordinateImage(
            width: 18,
            height: 12,
            pattern: .weighted(xMultiplier: 3, yMultiplier: 5, includeBlueSum: true)
        )
        let assetID = UUID()
        var snapshot = makeEditorSnapshot(
            cropRect: CGRect(x: 0, y: 0, width: 24, height: 16)
        )
        snapshot.composition = CompositionSnapshot(
            items: [CompositionItem(assetID: assetID, title: "Retained panel")]
        )
        let document = EditableScreenshotDocument(
            capture: makeCapturedScreenshot(image: rootImage),
            session: makeEditorDocumentSession(initialSnapshot: snapshot),
            compositionStoredAssets: [
                try storedAsset(
                    id: assetID,
                    image: compositionImage,
                    sourceName: "Composition source",
                    isPrivate: privateAsset
                )
            ]
        )
        try SSSDocumentPackage.save(
            document: document,
            previewImage: rootImage,
            to: packageURL
        )
        return (packageURL, assetID)
    }

    private func storedAsset(
        id: UUID,
        image: CGImage,
        sourceName: String,
        isPrivate: Bool = false
    ) throws -> CompositionStoredAsset {
        CompositionStoredAsset(
            descriptor: CompositionAssetDescriptor(
                id: id,
                pixelWidth: image.width,
                pixelHeight: image.height,
                sourceName: sourceName,
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                accessibilityLabel: sourceName,
                captureKind: CaptureKind.region.rawValue,
                sourceRect: CGRect(
                    origin: .zero,
                    size: CGSize(width: image.width, height: image.height)
                ),
                isPrivate: isPrivate
            ),
            encodedPNG: try ImageExporter.pngData(for: image)
        )
    }

    private func manifestDictionary(at packageURL: URL) throws -> [String: Any] {
        let data = try Data(
            contentsOf: packageURL.appendingPathComponent(
                SSSDocumentPackage.manifestFilename
            )
        )
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func updateManifest(
        at packageURL: URL,
        mutation: (inout [String: Any]) throws -> Void
    ) throws {
        var manifest = try manifestDictionary(at: packageURL)
        try mutation(&manifest)
        let data = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(
            to: packageURL.appendingPathComponent(
                SSSDocumentPackage.manifestFilename
            ),
            options: .atomic
        )
    }

    private func updateCurrentComposition(
        at packageURL: URL,
        mutation: (inout [String: Any]) throws -> Void
    ) throws {
        try updateManifest(at: packageURL) { manifest in
            var session = manifest["session"] as! [String: Any]
            var current = session["currentSnapshot"] as! [String: Any]
            var composition = current["composition"] as! [String: Any]
            try mutation(&composition)
            current["composition"] = composition
            session["currentSnapshot"] = current
            manifest["session"] = session
        }
    }

    private func stripExpandedCompositionKeys(
        from snapshot: inout [String: Any]
    ) {
        guard var composition = snapshot["composition"] as? [String: Any] else {
            return
        }
        composition.removeValue(forKey: "isActivated")

        var layout = composition["layout"] as! [String: Any]
        layout.removeValue(forKey: "sizingMode")
        layout.removeValue(forKey: "orientation")
        composition["layout"] = layout

        var comparison = composition["comparison"] as! [String: Any]
        for key in [
            "showsLabels",
            "keepsViewsLinked",
            "registrationMode",
            "manualRegistrationOffset",
            "registrationSensitivity",
            "unchangedContentOpacity",
            "differenceCueStyle",
            "blinkCrossfadeDuration",
            "blinkLoops",
            "posterFrame",
        ] {
            comparison.removeValue(forKey: key)
        }
        composition["comparison"] = comparison

        var steps = composition["steps"] as! [String: Any]
        steps.removeValue(forKey: "flow")
        steps.removeValue(forKey: "gridColumns")
        steps.removeValue(forKey: "itemsPerPage")
        composition["steps"] = steps

        var items = composition["items"] as! [[String: Any]]
        for index in items.indices {
            items[index].removeValue(forKey: "semanticRole")
            items[index].removeValue(forKey: "zIndex")
        }
        composition["items"] = items

        var canvas = composition["canvas"] as! [String: Any]
        canvas.removeValue(forKey: "annotationAnchors")
        var appearance = canvas["appearance"] as! [String: Any]
        for key in [
            "captionFontName",
            "captionFontWeight",
            "captionTextAlignment",
            "captionPlacement",
            "titleColor",
            "titleBackgroundColor",
            "titleFontSize",
            "titleFontName",
            "titleFontWeight",
            "titleTextAlignment",
            "titleInsets",
        ] {
            appearance.removeValue(forKey: key)
        }
        canvas["appearance"] = appearance
        composition["canvas"] = canvas
        snapshot["composition"] = composition
    }
}
