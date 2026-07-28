import CoreGraphics
import Foundation
import XCTest
@testable import SnipSnipSnip

@MainActor
final class IntentDrivenDocumentPersistenceTests: XCTestCase {
    func testEveryPurposeAndStageCombinationNormalizesDeterministically() {
        struct Fixture {
            let name: String
            let purpose: ScreenshotDocumentPurpose
            let composition: CompositionSnapshot
            let fallback: ScreenshotWorkflowStage
            let validContentStages: [ScreenshotWorkflowStage]
        }
        func composition(
            itemCount: Int,
            isActivated: Bool,
            layoutMode: CompositionLayoutMode
        ) -> CompositionSnapshot {
            CompositionSnapshot(
                items: (0..<itemCount).map { _ in
                    CompositionItem(assetID: UUID())
                },
                isActivated: isActivated,
                layout: CompositionLayoutConfiguration(
                    mode: layoutMode
                )
            )
        }
        let fixtures = [
            Fixture(
                name: "Screenshot",
                purpose: .screenshot,
                composition: composition(
                    itemCount: 1,
                    isActivated: false,
                    layoutMode: .auto
                ),
                fallback: .editing,
                validContentStages: [.editing]
            ),
            Fixture(
                name: "Comparison Before",
                purpose: .comparison,
                composition: composition(
                    itemCount: 1,
                    isActivated: false,
                    layoutMode: .compare
                ),
                fallback: .awaitingComparisonAfter,
                validContentStages: [.awaitingComparisonAfter]
            ),
            Fixture(
                name: "Comparison Ready",
                purpose: .comparison,
                composition: composition(
                    itemCount: 2,
                    isActivated: true,
                    layoutMode: .compare
                ),
                fallback: .reviewingComparison,
                validContentStages: [.reviewingComparison]
            ),
            Fixture(
                name: "Steps",
                purpose: .steps,
                composition: composition(
                    itemCount: 2,
                    isActivated: true,
                    layoutMode: .steps
                ),
                fallback: .collecting,
                validContentStages: [.collecting, .arranging]
            ),
            Fixture(
                name: "Collection Before Arrangement",
                purpose: .collection,
                composition: composition(
                    itemCount: 1,
                    isActivated: false,
                    layoutMode: .auto
                ),
                fallback: .collecting,
                validContentStages: [.collecting, .arranging]
            ),
            Fixture(
                name: "Collection Arranged",
                purpose: .collection,
                composition: composition(
                    itemCount: 2,
                    isActivated: true,
                    layoutMode: .auto
                ),
                fallback: .arranging,
                validContentStages: [.collecting, .arranging]
            ),
        ]

        for fixture in fixtures {
            for candidate in ScreenshotWorkflowStage.allCases {
                let normalized = ScreenshotWorkflowResumeState(
                    stage: candidate
                ).normalized(
                    for: fixture.purpose,
                    composition: fixture.composition
                )
                let expectedStage =
                    candidate == .polishing
                    || fixture.validContentStages.contains(candidate)
                    ? candidate : fixture.fallback

                XCTAssertEqual(
                    normalized.stage,
                    expectedStage,
                    "\(fixture.name), candidate \(candidate)"
                )
                XCTAssertEqual(
                    normalized.returnStage,
                    candidate == .polishing ? fixture.fallback : nil,
                    "\(fixture.name), candidate \(candidate)"
                )
                XCTAssertEqual(
                    normalized.normalized(
                        for: fixture.purpose,
                        composition: fixture.composition
                    ),
                    normalized,
                    "\(fixture.name) normalization must be idempotent."
                )
            }

            let returnCandidates: [ScreenshotWorkflowStage?] =
                [nil]
                + ScreenshotWorkflowStage.allCases.map(Optional.some)
            for returnCandidate in returnCandidates {
                let normalized = ScreenshotWorkflowResumeState(
                    stage: .polishing,
                    returnStage: returnCandidate
                ).normalized(
                    for: fixture.purpose,
                    composition: fixture.composition
                )
                let expectedReturn = returnCandidate.flatMap {
                    $0 != .polishing
                        && fixture.validContentStages.contains($0)
                        ? $0 : nil
                } ?? fixture.fallback

                XCTAssertEqual(normalized.stage, .polishing, fixture.name)
                XCTAssertEqual(
                    normalized.returnStage,
                    expectedReturn,
                    "\(fixture.name), return \(String(describing: returnCandidate))"
                )
            }
        }
    }

    func testEveryCanonicalPurposeStagePairPersistsThroughV7() throws {
        struct Fixture {
            let name: String
            let purpose: ScreenshotDocumentPurpose
            let itemCount: Int
            let resumeState: ScreenshotWorkflowResumeState
        }
        let fixtures = [
            Fixture(
                name: "screenshot-editing",
                purpose: .screenshot,
                itemCount: 1,
                resumeState: ScreenshotWorkflowResumeState(
                    stage: .editing
                )
            ),
            Fixture(
                name: "screenshot-polishing",
                purpose: .screenshot,
                itemCount: 1,
                resumeState: ScreenshotWorkflowResumeState(
                    stage: .polishing,
                    returnStage: .editing
                )
            ),
            Fixture(
                name: "comparison-before",
                purpose: .comparison,
                itemCount: 1,
                resumeState: ScreenshotWorkflowResumeState(
                    stage: .awaitingComparisonAfter
                )
            ),
            Fixture(
                name: "comparison-before-polishing",
                purpose: .comparison,
                itemCount: 1,
                resumeState: ScreenshotWorkflowResumeState(
                    stage: .polishing,
                    returnStage: .awaitingComparisonAfter
                )
            ),
            Fixture(
                name: "comparison-ready",
                purpose: .comparison,
                itemCount: 2,
                resumeState: ScreenshotWorkflowResumeState(
                    stage: .reviewingComparison
                )
            ),
            Fixture(
                name: "comparison-ready-polishing",
                purpose: .comparison,
                itemCount: 2,
                resumeState: ScreenshotWorkflowResumeState(
                    stage: .polishing,
                    returnStage: .reviewingComparison
                )
            ),
            Fixture(
                name: "steps-collecting",
                purpose: .steps,
                itemCount: 2,
                resumeState: ScreenshotWorkflowResumeState(
                    stage: .collecting
                )
            ),
            Fixture(
                name: "steps-arranging",
                purpose: .steps,
                itemCount: 2,
                resumeState: ScreenshotWorkflowResumeState(
                    stage: .arranging
                )
            ),
            Fixture(
                name: "steps-polishing",
                purpose: .steps,
                itemCount: 2,
                resumeState: ScreenshotWorkflowResumeState(
                    stage: .polishing,
                    returnStage: .collecting
                )
            ),
            Fixture(
                name: "collection-collecting",
                purpose: .collection,
                itemCount: 2,
                resumeState: ScreenshotWorkflowResumeState(
                    stage: .collecting
                )
            ),
            Fixture(
                name: "collection-arranging",
                purpose: .collection,
                itemCount: 2,
                resumeState: ScreenshotWorkflowResumeState(
                    stage: .arranging
                )
            ),
            Fixture(
                name: "collection-polishing",
                purpose: .collection,
                itemCount: 2,
                resumeState: ScreenshotWorkflowResumeState(
                    stage: .polishing,
                    returnStage: .arranging
                )
            ),
        ]
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )

        for fixture in fixtures {
            let capture = makeCapturedScreenshot(
                sourceName: fixture.name
            )
            let controller = EditorController(
                capture: capture,
                capabilities: testCapabilities,
                documentPurpose: fixture.purpose,
                workflowResumeState:
                    ScreenshotWorkflowResumeState.inferred(
                        for: fixture.purpose,
                        composition: nil
                    )
            )
            if fixture.itemCount == 2 {
                _ = try controller.appendCaptureToComposition(
                    makeCapturedScreenshot(
                        sourceName: "\(fixture.name)-second"
                    ),
                    isPrivate: false
                )
                let layoutMode: CompositionLayoutMode
                switch fixture.purpose {
                case .comparison:
                    layoutMode = .compare
                case .steps:
                    layoutMode = .steps
                case .collection, .screenshot:
                    layoutMode = .auto
                }
                controller.setDocumentPurpose(
                    fixture.purpose,
                    layoutMode: layoutMode
                )
            }
            controller.setWorkflowResumeState(fixture.resumeState)

            XCTAssertEqual(
                controller.workflowResumeState,
                fixture.resumeState,
                fixture.name
            )

            let packageURL = rootURL.appendingPathComponent(
                "\(fixture.name).sss",
                isDirectory: true
            )
            try SSSDocumentPackage.save(
                document: controller.editableDocument,
                previewImage: capture.image,
                to: packageURL,
                includeUIMapSearchText: false
            )
            let loaded = try SSSDocumentPackage.load(from: packageURL)

            XCTAssertEqual(
                loaded.session.currentSnapshot.documentPurpose,
                fixture.purpose,
                fixture.name
            )
            XCTAssertEqual(
                loaded.workflowResumeState,
                fixture.resumeState,
                fixture.name
            )
        }
    }

    func testV7RoundTripPersistsPurposeAndWorkflowResumeState() throws {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sss")
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let capture = makeCapturedScreenshot()
        let controller = EditorController(
            capture: capture,
            capabilities: testCapabilities,
            documentPurpose: .comparison,
            workflowResumeState: ScreenshotWorkflowResumeState(
                stage: .awaitingComparisonAfter
            )
        )
        let document = controller.editableDocument

        try SSSDocumentPackage.save(
            document: document,
            previewImage: capture.image,
            to: packageURL,
            includeUIMapSearchText: false
        )

        let loaded = try SSSDocumentPackage.load(from: packageURL)

        XCTAssertEqual(
            loaded.session.currentSnapshot.documentPurpose,
            .comparison
        )
        XCTAssertEqual(
            loaded.workflowResumeState,
            ScreenshotWorkflowResumeState(stage: .awaitingComparisonAfter)
        )
    }

    func testPurposeInferenceUsesActivatedLegacyLayout() {
        let item = CompositionItem(assetID: UUID())

        XCTAssertEqual(
            ScreenshotDocumentPurpose.inferred(
                from: CompositionSnapshot(
                    items: [item],
                    isActivated: false,
                    layout: CompositionLayoutConfiguration(mode: .compare)
                )
            ),
            .screenshot
        )

        for (mode, expectedPurpose) in [
            (CompositionLayoutMode.compare, ScreenshotDocumentPurpose.comparison),
            (.steps, .steps),
            (.auto, .collection),
            (.row, .collection),
            (.column, .collection),
            (.grid, .collection),
            (.freeform, .collection),
        ] {
            XCTAssertEqual(
                ScreenshotDocumentPurpose.inferred(
                    from: CompositionSnapshot(
                        items: [item, CompositionItem(assetID: UUID())],
                        layout: CompositionLayoutConfiguration(mode: mode)
                    )
                ),
                expectedPurpose
            )
        }
    }

    func testUnknownFuturePurposeAndWorkflowStageFallBackWithoutRejectingV7() throws {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sss")
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let capture = makeCapturedScreenshot()
        let controller = EditorController(
            capture: capture,
            capabilities: testCapabilities,
            documentPurpose: .comparison,
            workflowResumeState: ScreenshotWorkflowResumeState(
                stage: .awaitingComparisonAfter
            )
        )
        try SSSDocumentPackage.save(
            document: controller.editableDocument,
            previewImage: capture.image,
            to: packageURL,
            includeUIMapSearchText: false
        )

        let manifestURL = packageURL.appendingPathComponent(
            SSSDocumentPackage.manifestFilename
        )
        var manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: manifestURL)
            ) as? [String: Any]
        )
        var session = try XCTUnwrap(manifest["session"] as? [String: Any])
        var currentSnapshot = try XCTUnwrap(
            session["currentSnapshot"] as? [String: Any]
        )
        currentSnapshot["documentPurpose"] = "futurePurpose"
        session["currentSnapshot"] = currentSnapshot
        manifest["session"] = session
        manifest["workflow"] = ["stage": "futureStage"]
        try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: manifestURL, options: .atomic)

        let loaded = try SSSDocumentPackage.load(from: packageURL)

        XCTAssertEqual(
            loaded.session.currentSnapshot.documentPurpose,
            .screenshot
        )
        XCTAssertEqual(loaded.workflowResumeState.stage, .editing)
    }
}

@MainActor
final class IntentDrivenEditorStateTests: XCTestCase {
    func testPurposeChangeIsUndoableAndNormalizesStage() {
        let controller = retainForTestLifetime(
            EditorController(capture: makeCapturedScreenshot())
        )

        controller.setDocumentPurpose(.collection, layoutMode: .auto)

        XCTAssertEqual(controller.documentPurpose, .collection)
        XCTAssertEqual(controller.workflowStage, .arranging)
        XCTAssertEqual(controller.snapshot.composition?.layout.mode, .auto)
        XCTAssertEqual(controller.snapshot.composition?.isActivated, true)

        controller.undo()

        XCTAssertEqual(controller.documentPurpose, .screenshot)
        XCTAssertEqual(controller.workflowStage, .editing)
        XCTAssertEqual(controller.snapshot.composition?.isActivated, false)
    }

    func testFirstAddUndoAndRedoRestoreTheGoalFocusedWorkspace() throws {
        let controller = EditorController(
            capture: makeCapturedScreenshot(sourceName: "Before"),
            capabilities: testCapabilities
        )

        controller.beginCoalescedEditorGesture()
        _ = try controller.appendCaptureToComposition(
            makeCapturedScreenshot(sourceName: "After"),
            isPrivate: false
        )
        controller.setDocumentPurpose(.comparison, layoutMode: .compare)
        controller.endCoalescedEditorGesture()
        controller.setWorkflowStage(.reviewingComparison)
        controller.setWorkspaceMode(.presentation)

        controller.undo()

        XCTAssertEqual(controller.documentPurpose, .screenshot)
        XCTAssertEqual(controller.workflowStage, .editing)
        XCTAssertEqual(controller.workspaceMode, .edit)
        XCTAssertFalse(controller.hasComposition)

        controller.redo()

        XCTAssertEqual(controller.documentPurpose, .comparison)
        XCTAssertEqual(controller.workflowStage, .reviewingComparison)
        XCTAssertEqual(controller.workspaceMode, .presentation)
        XCTAssertTrue(controller.hasComposition)
    }

    func testOneItemComparisonWaitsForAfterAndScreenshotDemotionDeactivatesComposition() {
        let controller = retainForTestLifetime(
            EditorController(capture: makeCapturedScreenshot())
        )

        controller.setDocumentPurpose(.comparison, layoutMode: .compare)
        controller.setWorkflowStage(.awaitingComparisonAfter)

        XCTAssertEqual(controller.documentPurpose, .comparison)
        XCTAssertEqual(
            controller.snapshot.composition?.layout.mode,
            .compare
        )
        XCTAssertEqual(
            controller.snapshot.composition?.isActivated,
            false,
            "A Before-only comparison must not activate the two-panel renderer."
        )

        controller.setDocumentPurpose(.screenshot)
        controller.setWorkflowStage(.editing)

        XCTAssertEqual(controller.documentPurpose, .screenshot)
        XCTAssertEqual(controller.snapshot.composition?.isActivated, false)
    }

    func testPolishNavigationDoesNotChangeAutosaveFingerprint() {
        let controller = retainForTestLifetime(
            EditorController(capture: makeCapturedScreenshot())
        )
        controller.applyPresentationPreset(.lifted)
        let documentURL = URL(fileURLWithPath: "/tmp/WorkflowStage.sss")
        let baseline = AutosaveState(
            controller: controller,
            documentURL: documentURL
        )

        controller.enterPolish()

        XCTAssertEqual(controller.workflowStage, .polishing)
        XCTAssertEqual(controller.currentWorkspaceOutputAppearance, .styled)
        XCTAssertEqual(
            AutosaveState(controller: controller, documentURL: documentURL),
            baseline
        )

        controller.leavePolish()

        XCTAssertEqual(controller.workflowStage, .editing)
        XCTAssertEqual(controller.currentWorkspaceOutputAppearance, .plain)
    }

    func testPolishConfigurationLabelDistinguishesSavedTreatment() {
        let controller = EditorController(
            capture: makeCapturedScreenshot(),
            capabilities: testCapabilities
        )

        XCTAssertEqual(
            controller.polishConfigurationLabel,
            "No Polish configured"
        )

        controller.applyPresentationPreset(.lifted)

        XCTAssertTrue(
            controller.polishConfigurationLabel
                .hasPrefix("Polish configured ·")
        )
    }

    func testRestoringWorkflowNavigationUsesGoalFocusedWorkspace() throws {
        let screenshot = EditorController(
            capture: makeCapturedScreenshot(),
            capabilities: testCapabilities,
            documentPurpose: .screenshot,
            workflowResumeState: ScreenshotWorkflowResumeState(
                stage: .editing
            )
        )
        screenshot.presentationInspectorTab = .style
        screenshot.setWorkspaceMode(.presentation)
        screenshot.restoreWorkflowWorkspace()
        XCTAssertEqual(screenshot.workspaceMode, .edit)
        XCTAssertEqual(screenshot.presentationInspectorTab, .layout)

        let comparisonBefore = EditorController(
            capture: makeCapturedScreenshot(),
            capabilities: testCapabilities,
            documentPurpose: .comparison,
            workflowResumeState: ScreenshotWorkflowResumeState(
                stage: .awaitingComparisonAfter
            )
        )
        comparisonBefore.presentationInspectorTab = .style
        comparisonBefore.setWorkspaceMode(.presentation)
        comparisonBefore.restoreWorkflowWorkspace()
        XCTAssertEqual(comparisonBefore.workspaceMode, .edit)
        XCTAssertEqual(
            comparisonBefore.presentationInspectorTab,
            .layout
        )

        let comparisonReady = EditorController(
            capture: makeCapturedScreenshot(sourceName: "Before"),
            capabilities: testCapabilities
        )
        _ = try comparisonReady.appendCaptureToComposition(
            makeCapturedScreenshot(sourceName: "After"),
            isPrivate: false
        )
        comparisonReady.setDocumentPurpose(
            .comparison,
            layoutMode: .compare
        )
        comparisonReady.setWorkflowStage(.reviewingComparison)
        comparisonReady.setWorkspaceMode(.edit)
        comparisonReady.presentationInspectorTab = .style
        comparisonReady.restoreWorkflowWorkspace()
        XCTAssertEqual(comparisonReady.workspaceMode, .presentation)
        XCTAssertEqual(
            comparisonReady.presentationInspectorTab,
            .layout
        )

        for purpose in [
            ScreenshotDocumentPurpose.steps,
            .collection,
        ] {
            let content = EditorController(
                capture: makeCapturedScreenshot(),
                capabilities: testCapabilities,
                documentPurpose: purpose,
                workflowResumeState: ScreenshotWorkflowResumeState(
                    stage: purpose == .steps ? .collecting : .arranging
                )
            )
            content.setWorkspaceMode(.edit)
            content.presentationInspectorTab = .style
            content.restoreWorkflowWorkspace()
            XCTAssertEqual(content.workspaceMode, .presentation)
            XCTAssertEqual(content.presentationInspectorTab, .layout)
        }
    }

    func testRestoringPolishUsesPolishedWorkspaceAcrossGoals() {
        let returnStages: [
            ScreenshotDocumentPurpose: ScreenshotWorkflowStage
        ] = [
            .screenshot: .editing,
            .comparison: .awaitingComparisonAfter,
            .steps: .collecting,
            .collection: .arranging,
        ]

        for purpose in ScreenshotDocumentPurpose.allCases {
            let controller = EditorController(
                capture: makeCapturedScreenshot(),
                capabilities: testCapabilities,
                documentPurpose: purpose,
                workflowResumeState: ScreenshotWorkflowResumeState(
                    stage: .polishing,
                    returnStage: returnStages[purpose]
                )
            )
            controller.applyPresentationPreset(.lifted)
            controller.presentationInspectorTab = .layout
            controller.setWorkspaceMode(.edit)

            controller.restoreWorkflowWorkspace()

            XCTAssertEqual(controller.workflowStage, .polishing)
            XCTAssertEqual(controller.workspaceMode, .presentation)
            XCTAssertEqual(controller.presentationInspectorTab, .style)
            XCTAssertEqual(
                controller.currentWorkspaceOutputAppearance,
                .styled
            )
        }
    }

    func testAutosaveFingerprintTracksCompositionContentAndAssetRevisionButNotSelection() {
        let controller = retainForTestLifetime(
            EditorController(capture: makeCapturedScreenshot())
        )
        controller.setDocumentPurpose(.collection, layoutMode: .auto)
        let documentURL = URL(fileURLWithPath: "/tmp/CompositionState.sss")
        let baseline = AutosaveState(
            controller: controller,
            documentURL: documentURL
        )
        let itemID = try! XCTUnwrap(controller.snapshot.composition?.items.first?.id)
        let assetID = try! XCTUnwrap(controller.snapshot.composition?.items.first?.assetID)

        controller.selectCompositionItems([])
        XCTAssertEqual(
            AutosaveState(controller: controller, documentURL: documentURL),
            baseline
        )

        controller.updateCompositionItem(itemID: itemID) {
            $0.caption = "A persisted caption"
        }
        let captionState = AutosaveState(
            controller: controller,
            documentURL: documentURL
        )
        XCTAssertNotEqual(captionState, baseline)

        let uiMap = UIMapSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_100),
            sourceRect: CGRect(x: 0, y: 0, width: 64, height: 48),
            elements: []
        )
        controller.attachUIMap(uiMap, toCompositionAsset: assetID)

        XCTAssertNotEqual(
            AutosaveState(controller: controller, documentURL: documentURL),
            captionState
        )
    }

    func testPurposeAndStageLabelsAreStableForContextualSessionHeader() {
        XCTAssertEqual(ScreenshotDocumentPurpose.screenshot.label, "Screenshot")
        XCTAssertEqual(ScreenshotDocumentPurpose.comparison.label, "Comparison")
        XCTAssertEqual(ScreenshotDocumentPurpose.steps.label, "Steps")
        XCTAssertEqual(ScreenshotDocumentPurpose.collection.label, "Combined Image")
        XCTAssertEqual(ScreenshotWorkflowStage.awaitingComparisonAfter.label, "Capture After")
        XCTAssertEqual(ScreenshotWorkflowStage.reviewingComparison.label, "Review")
        XCTAssertEqual(ScreenshotWorkflowStage.polishing.label, "Polish")
        XCTAssertEqual(
            ScreenshotDocumentPurpose.steps.stageLabel(for: .collecting),
            "Add Step"
        )
        XCTAssertEqual(
            ScreenshotDocumentPurpose.steps.stageLabel(for: .arranging),
            "Order & Caption"
        )
        XCTAssertEqual(
            ScreenshotDocumentPurpose.collection.stageLabel(for: .collecting),
            "Add Image"
        )
        XCTAssertEqual(
            ScreenshotDocumentPurpose.collection.stageLabel(for: .arranging),
            "Arrange"
        )
        XCTAssertEqual(
            ScreenshotDocumentPurpose.steps.sessionTitle(
                stage: .collecting,
                includedItemCount: 3
            ),
            "Steps · 3 steps"
        )
        XCTAssertEqual(
            ScreenshotDocumentPurpose.collection.sessionTitle(
                stage: .arranging,
                includedItemCount: 4
            ),
            "Combined Image · 4 images"
        )
        XCTAssertEqual(
            ScreenshotDocumentPurpose.collection.sessionTitle(
                stage: .polishing,
                includedItemCount: 4
            ),
            "Combined Image · Polish"
        )
    }
}
