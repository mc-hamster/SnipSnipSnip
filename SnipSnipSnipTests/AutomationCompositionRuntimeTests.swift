import Foundation
import XCTest
@testable import SnipSnipSnip

final class AutomationCompositionRuntimeTests: XCTestCase {
    @MainActor
    func testCompositionExecutorAppliesCompleteStepsConfigurationAsOneUndoableChange() throws {
        let suiteName = "AutomationCompositionRuntimeTests.\(UUID().uuidString)"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = EditorController(
            capture: makeCapturedScreenshot(sourceName: "First"),
            defaults: defaults,
            capabilities: testCapabilities
        )
        try controller.appendCaptureToComposition(
            makeCapturedScreenshot(sourceName: "Second"),
            isPrivate: false
        )
        let previous = try XCTUnwrap(controller.composition)

        let summary = try EditorCompositionAutomationExecutor().apply(
            .setLayout(AutomationCompositionLayoutCommand(
                layout: .steps,
                axis: .horizontal,
                gridColumns: 3,
                targetAspectRatio: 16 / 9,
                freeformCanvasWidth: 1_600,
                freeformCanvasHeight: 900,
                stepNumberingStyle: .uppercaseRoman,
                stepStartIndex: 3,
                stepShowsCaptions: false,
                stepConnectorStyle: .line
            )),
            to: controller
        )

        let updated = try XCTUnwrap(controller.composition)
        XCTAssertEqual(summary.documentID, controller.documentGenerationID)
        XCTAssertEqual(summary.itemCount, 2)
        XCTAssertEqual(summary.layout, .steps)
        XCTAssertNil(summary.compareMode)
        XCTAssertEqual(updated.layout.mode, .steps)
        XCTAssertEqual(updated.layout.gridColumns, 3)
        XCTAssertEqual(updated.layout.targetAspectRatio, 16 / 9)
        XCTAssertEqual(updated.layout.freeformCanvasSize, CGSize(width: 1_600, height: 900))
        XCTAssertEqual(updated.steps.axis, .horizontal)
        XCTAssertEqual(updated.steps.numberingStyle, .uppercaseRoman)
        XCTAssertEqual(updated.steps.startIndex, 3)
        XCTAssertFalse(updated.steps.showsCaptions)
        XCTAssertEqual(updated.steps.connectorStyle, .line)
        XCTAssertEqual(controller.documentPurpose, .steps)

        controller.undo()
        XCTAssertEqual(controller.composition, previous)
        XCTAssertEqual(controller.documentPurpose, .screenshot)
    }

    @MainActor
    func testCompositionExecutorMapsCompleteComparisonConfigurationAndPairSelection() throws {
        let suiteName = "AutomationCompositionRuntimeTests.\(UUID().uuidString)"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = EditorController(
            capture: makeCapturedScreenshot(sourceName: "Before"),
            defaults: defaults,
            capabilities: testCapabilities
        )
        try controller.appendCaptureToComposition(
            makeCapturedScreenshot(sourceName: "After"),
            isPrivate: true
        )
        let items = try XCTUnwrap(controller.composition?.items)

        let summary = try EditorCompositionAutomationExecutor().apply(
            .setCompareMode(AutomationCompositionCompareCommand(
                mode: .changeHighlight,
                firstItemID: items[1].id,
                secondItemID: items[0].id,
                axis: .vertical,
                wipePosition: 0.37,
                overlayOpacity: 0.41,
                blinkInterval: 1.25,
                differenceIntensity: 0.82,
                changeHighlightColorHex: "#3366CC80",
                changeHighlightThreshold: 0.18,
                primaryLabel: "New",
                secondaryLabel: "Old"
            )),
            to: controller
        )

        let updated = try XCTUnwrap(controller.composition)
        XCTAssertEqual(summary.layout, .compare)
        XCTAssertEqual(summary.compareMode, .changeHighlight)
        XCTAssertTrue(summary.isPrivate)
        XCTAssertEqual(updated.comparison.primaryItemID, items[1].id)
        XCTAssertEqual(updated.comparison.secondaryItemID, items[0].id)
        XCTAssertEqual(updated.comparison.axis, .vertical)
        XCTAssertEqual(updated.comparison.wipePosition, 0.37)
        XCTAssertEqual(updated.comparison.overlayOpacity, 0.41)
        XCTAssertEqual(updated.comparison.blinkInterval, 1.25)
        XCTAssertEqual(updated.comparison.differenceIntensity, 0.82)
        XCTAssertEqual(updated.comparison.changeThreshold, 0.18)
        XCTAssertEqual(updated.comparison.changeHighlightColor.red, 0x33 / 255, accuracy: 0.000_001)
        XCTAssertEqual(updated.comparison.changeHighlightColor.green, 0x66 / 255, accuracy: 0.000_001)
        XCTAssertEqual(updated.comparison.changeHighlightColor.blue, 0xCC / 255, accuracy: 0.000_001)
        XCTAssertEqual(updated.comparison.changeHighlightColor.alpha, 0x80 / 255, accuracy: 0.000_001)
        XCTAssertEqual(updated.comparison.primaryLabel, "New")
        XCTAssertEqual(updated.comparison.secondaryLabel, "Old")
        XCTAssertEqual(controller.documentPurpose, .comparison)
    }

    @MainActor
    func testCompositionExecutorAppliesCompatibleTemplateByStableID() throws {
        let suiteName = "AutomationCompositionRuntimeTests.\(UUID().uuidString)"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = EditorController(
            capture: makeCapturedScreenshot(sourceName: "First"),
            defaults: defaults,
            capabilities: testCapabilities
        )
        try controller.appendCaptureToComposition(
            makeCapturedScreenshot(sourceName: "Second"),
            isPrivate: false
        )

        let summary = try EditorCompositionAutomationExecutor().apply(
            .applyTemplate(AutomationCompositionTemplateCommand(
                id: "builtin.numbered-steps"
            )),
            to: controller
        )

        XCTAssertEqual(summary.layout, .steps)
        XCTAssertEqual(controller.composition?.layout.mode, .steps)
        XCTAssertEqual(controller.documentPurpose, .steps)
        XCTAssertEqual(
            controller.composition?.steps.numberingStyle,
            .decimal
        )
        XCTAssertEqual(
            controller.composition?.steps.connectorStyle,
            .arrow
        )
    }

    @MainActor
    func testCompositionExecutorMapsActionableRuntimeErrors() throws {
        let suiteName = "AutomationCompositionRuntimeTests.\(UUID().uuidString)"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = EditorController(
            capture: makeCapturedScreenshot(),
            defaults: defaults,
            capabilities: testCapabilities
        )
        let promoted = try EditorCompositionAutomationExecutor().apply(
            .setLayout(AutomationCompositionLayoutCommand(layout: .grid)),
            to: controller
        )
        XCTAssertEqual(promoted.itemCount, 1)
        XCTAssertEqual(promoted.layout, .grid)
        XCTAssertEqual(controller.documentPurpose, .collection)
        XCTAssertTrue(controller.hasComposition)

        controller.undo()
        XCTAssertEqual(controller.documentPurpose, .screenshot)
        XCTAssertFalse(controller.hasComposition)

        try controller.appendCaptureToComposition(
            makeCapturedScreenshot(sourceName: "Second"),
            isPrivate: false
        )
        controller.excludeSelectedCompositionItems(true)
        XCTAssertThrowsError(
            try EditorCompositionAutomationExecutor().apply(
                .setCompareMode(AutomationCompositionCompareCommand(mode: .wipe)),
                to: controller
            )
        ) {
            XCTAssertEqual(($0 as? AutomationExecutionError)?.code, .compositionRequiresMultipleItems)
        }

        controller.excludeSelectedCompositionItems(false)
        XCTAssertThrowsError(
            try EditorCompositionAutomationExecutor().apply(
                .setCompareMode(AutomationCompositionCompareCommand(
                    mode: .wipe,
                    wipePosition: 1.1
                )),
                to: controller
            )
        ) {
            XCTAssertEqual(($0 as? AutomationExecutionError)?.code, .invalidRequest)
        }

        XCTAssertThrowsError(
            try EditorCompositionAutomationExecutor().apply(
                .setCompareMode(AutomationCompositionCompareCommand(
                    mode: .wipe,
                    firstItemID: UUID(),
                    secondItemID: UUID()
                )),
                to: controller
            )
        ) {
            XCTAssertEqual(($0 as? AutomationExecutionError)?.code, .compositionItemNotFound)
        }
    }

    @MainActor
    func testCaptureDestinationContextMapsAndVerifiesAppendAndReplace() throws {
        let suiteName = "AutomationCompositionRuntimeTests.\(UUID().uuidString)"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = EditorController(
            capture: makeCapturedScreenshot(sourceName: "Root"),
            defaults: defaults,
            capabilities: testCapabilities
        )
        let appendRequest = captureRequest(destination: .append)
        let append = try AutomationCaptureDestinationContext(
            request: appendRequest,
            controller: controller
        )
        let rootItemID = try XCTUnwrap(controller.composition?.items.first?.id)
        XCTAssertEqual(
            append.intent,
            .append(
                documentGenerationID: controller.documentGenerationID,
                afterItemID: rootItemID
            )
        )

        let insertion = try controller.appendCaptureToComposition(
            makeCapturedScreenshot(sourceName: "Added"),
            isPrivate: false
        )
        XCTAssertEqual(
            try append.verifyCompletion(in: controller),
            insertion.itemID
        )

        let selectedAppend = try AutomationCaptureDestinationContext(
            request: appendRequest,
            controller: controller
        )
        XCTAssertEqual(
            selectedAppend.intent,
            .append(
                documentGenerationID: controller.documentGenerationID,
                afterItemID: insertion.itemID
            )
        )

        let firstItemID = try XCTUnwrap(controller.composition?.items.first?.id)
        let targetedAppend = try AutomationCaptureDestinationContext(
            request: captureRequest(
                destination: .append,
                appendAfterItemID: firstItemID
            ),
            controller: controller
        )
        XCTAssertEqual(
            targetedAppend.intent,
            .append(
                documentGenerationID: controller.documentGenerationID,
                afterItemID: firstItemID
            )
        )
        let targetedInsertion = try controller.appendCaptureToComposition(
            makeCapturedScreenshot(sourceName: "Inserted"),
            isPrivate: false,
            afterItemID: firstItemID
        )
        XCTAssertEqual(
            try targetedAppend.verifyCompletion(in: controller),
            targetedInsertion.itemID
        )

        let replace = try AutomationCaptureDestinationContext(
            request: captureRequest(
                destination: .replace,
                replaceItemID: insertion.itemID
            ),
            controller: controller
        )
        XCTAssertEqual(
            replace.intent,
            .replace(
                documentGenerationID: controller.documentGenerationID,
                itemID: insertion.itemID
            )
        )
        try controller.replaceCompositionItem(
            itemID: insertion.itemID,
            with: makeCapturedScreenshot(sourceName: "Replacement"),
            isPrivate: false
        )
        XCTAssertEqual(
            try replace.verifyCompletion(in: controller),
            insertion.itemID
        )
    }

    @MainActor
    func testCaptureDestinationContextRejectsMissingDocumentAndItem() throws {
        XCTAssertThrowsError(
            try AutomationCaptureDestinationContext(
                request: captureRequest(destination: .append),
                controller: nil
            )
        ) {
            XCTAssertEqual(($0 as? AutomationExecutionError)?.code, .noActiveComposition)
        }

        let suiteName = "AutomationCompositionRuntimeTests.\(UUID().uuidString)"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = EditorController(
            capture: makeCapturedScreenshot(),
            defaults: defaults,
            capabilities: testCapabilities
        )
        XCTAssertThrowsError(
            try AutomationCaptureDestinationContext(
                request: captureRequest(
                    destination: .replace,
                    replaceItemID: UUID()
                ),
                controller: controller
            )
        ) {
            XCTAssertEqual(($0 as? AutomationExecutionError)?.code, .noActiveComposition)
        }

        try controller.appendCaptureToComposition(
            makeCapturedScreenshot(sourceName: "Second"),
            isPrivate: false
        )
        XCTAssertThrowsError(
            try AutomationCaptureDestinationContext(
                request: captureRequest(
                    destination: .replace,
                    replaceItemID: UUID()
                ),
                controller: controller
            )
        ) {
            XCTAssertEqual(($0 as? AutomationExecutionError)?.code, .compositionItemNotFound)
        }

        XCTAssertThrowsError(
            try AutomationCaptureDestinationContext(
                request: captureRequest(
                    destination: .append,
                    appendAfterItemID: UUID()
                ),
                controller: controller
            )
        ) {
            XCTAssertEqual(($0 as? AutomationExecutionError)?.code, .compositionItemNotFound)
        }
    }

    @MainActor
    func testCaptureDestinationContextMapsChangedGenerationAndRemovedAnchorToStaleDestination() throws {
        let suiteName = "AutomationCompositionRuntimeTests.\(UUID().uuidString)"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = EditorController(
            capture: makeCapturedScreenshot(sourceName: "First"),
            defaults: defaults,
            capabilities: testCapabilities
        )
        try controller.appendCaptureToComposition(
            makeCapturedScreenshot(sourceName: "Second"),
            isPrivate: false
        )
        let firstItemID = try XCTUnwrap(controller.composition?.items.first?.id)
        let targetedAppend = try AutomationCaptureDestinationContext(
            request: captureRequest(
                destination: .append,
                appendAfterItemID: firstItemID
            ),
            controller: controller
        )
        let targetedReplace = try AutomationCaptureDestinationContext(
            request: captureRequest(
                destination: .replace,
                replaceItemID: firstItemID
            ),
            controller: controller
        )

        let replacementController = EditorController(
            capture: makeCapturedScreenshot(sourceName: "Different document"),
            defaults: defaults,
            capabilities: testCapabilities
        )
        XCTAssertThrowsError(
            try targetedAppend.verifyCompletion(in: replacementController)
        ) {
            XCTAssertEqual(($0 as? AutomationExecutionError)?.code, .staleDestination)
        }

        controller.removeCompositionLayerItems([firstItemID])
        XCTAssertThrowsError(try targetedAppend.verifyCompletion(in: controller)) {
            XCTAssertEqual(($0 as? AutomationExecutionError)?.code, .staleDestination)
        }
        XCTAssertThrowsError(try targetedReplace.verifyCompletion(in: controller)) {
            XCTAssertEqual(($0 as? AutomationExecutionError)?.code, .staleDestination)
        }
    }

    @MainActor
    func testCompletedCaptureWithRemovedAppendAnchorNeverMutatesTheActiveComposition() throws {
        let suiteName = "AutomationCompositionRuntimeTests.\(UUID().uuidString)"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            defaults: defaults,
            recoveryStore: DocumentRecoveryStore(baseURL: nil),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )
        let controller = EditorController(
            capture: makeCapturedScreenshot(sourceName: "First"),
            defaults: defaults,
            capabilities: testCapabilities
        )
        try controller.appendCaptureToComposition(
            makeCapturedScreenshot(sourceName: "Second"),
            isPrivate: false
        )
        model.documents.installEditorController(
            controller,
            documentURL: nil,
            savedSession: nil,
            shouldCreateRecoverySession: false
        )
        let removedAnchorID = try XCTUnwrap(
            controller.composition?.items.first?.id
        )
        controller.removeCompositionLayerItems([removedAnchorID])
        let snapshotBeforeCompletion = controller.snapshot
        let assetIDsBeforeCompletion = Set(
            controller.compositionAssetRepository.assetIDs
        )
        let completedCapture = makeCapturedScreenshot(
            sourceName: "Late automation capture"
        )
        let result = CaptureWorkflowResult(
            capture: completedCapture,
            uiMapSourceCapture: completedCapture,
            request: .fullscreen,
            runOptions: CaptureRunOptions(),
            isPrivateCapture: false,
            checkpointLabel: "Fullscreen Capture",
            shouldAttemptUIMapCapture: false,
            shouldProcessUIMap: false,
            uiMapSkipReason: nil,
            workflowPreset: nil,
            intent: .append(
                documentGenerationID: controller.documentGenerationID,
                afterItemID: removedAnchorID
            )
        )

        _ = model.documents.installCapturedScreenshot(result)

        XCTAssertEqual(controller.snapshot, snapshotBeforeCompletion)
        XCTAssertEqual(
            Set(controller.compositionAssetRepository.assetIDs),
            assetIDsBeforeCompletion
        )
    }

    private nonisolated func captureRequest(
        destination: AutomationCaptureDestination,
        appendAfterItemID: UUID? = nil,
        replaceItemID: UUID? = nil
    ) -> AutomationRequest {
        AutomationRequest(
            source: AutomationSource(kind: .internalCommand),
            command: .capture(CaptureAutomationCommand(
                target: .fullscreen(FullscreenCaptureTarget())
            )),
            captureDestination: destination,
            appendAfterCompositionItemID: appendAfterItemID,
            replaceCompositionItemID: replaceItemID,
            output: .none
        )
    }
}
