import CoreGraphics
import Foundation
import XCTest
@testable import SnipSnipSnip

@MainActor
final class IntentDrivenCreationWorkflowTests: XCTestCase {
    func testCreateExposesOneSnipLibrarySourceWithoutRemovingLegacyCases() {
        let capabilities = AppCapabilitySnapshot(
            buildTarget: .dev,
            enabledCapabilities: Set(AppCapability.allCases)
        )
        let workflow = CreationWorkflowModel(capabilities: capabilities)

        XCTAssertEqual(
            workflow.availableExistingSources,
            [.files, .clipboard, .captureHistory]
        )
        XCTAssertEqual(
            CreationExistingSource.allCases,
            [.files, .clipboard, .recentSnips, .captureHistory, .archive]
        )
    }

    func testCreateKeepsSnipLibraryAvailableForArchiveOnlyCapabilities() {
        let capabilities = AppCapabilitySnapshot(
            buildTarget: .dev,
            enabledCapabilities: [.editor, .archive]
        )
        let workflow = CreationWorkflowModel(capabilities: capabilities)

        XCTAssertEqual(
            workflow.availableExistingSources,
            [.files, .clipboard, .archive]
        )
    }

    func testCreateUsesSourceSpecificActionVerbsForExistingImages() {
        let options = CaptureOneShotOptions(
            captureDelay: .immediate,
            includesCursor: false,
            privateCapture: false,
            windowUIMapEnabled: false
        )

        XCTAssertEqual(
            CreationPlan(
                goal: .screenshot,
                source: .existing(.files),
                captureOptions: options
            ).primaryActionTitle,
            "Import Image"
        )
        XCTAssertEqual(
            CreationPlan(
                goal: .screenshot,
                source: .existing(.clipboard),
                captureOptions: options
            ).primaryActionTitle,
            "Paste Image"
        )
        XCTAssertEqual(
            CreationPlan(
                goal: .screenshot,
                source: .existing(.captureHistory),
                captureOptions: options
            ).primaryActionTitle,
            "Choose Image"
        )
    }

    func testEveryCreationDraftCombinationNormalizesToOneValidPlan() {
        let capabilities = AppCapabilitySnapshot(
            buildTarget: .dev,
            enabledCapabilities: Set(AppCapability.allCases)
        )
        let goals: [CreationGoal] = [
            .screenshot,
            .comparison,
            .instructions(.recordAsIWork),
            .instructions(.addCaptures),
            .combineImages,
        ]
        let sources: [CreationSource] = [
            .region,
            .window,
            .screen,
            .scrolling,
            .connectedDevice,
            .screenInspector,
        ] + CreationExistingSource.allCases.map(CreationSource.existing)
        var combinationCount = 0

        for goal in goals {
            for source in sources {
                for delay in CaptureDelay.allCases {
                    for includesCursor in [false, true] {
                        for privateCapture in [false, true] {
                            for windowUIMapEnabled in [false, true] {
                                combinationCount += 1
                                let draft = CreationDraft(
                                    goal: goal,
                                    source: source,
                                    captureDelay: delay,
                                    includesCursor: includesCursor,
                                    privateCapture: privateCapture,
                                    windowUIMapEnabled:
                                        windowUIMapEnabled
                                )
                                let normalized = draft.normalized(
                                    for: capabilities
                                )
                                let plan = draft.plan(for: capabilities)
                                let context =
                                    "goal=\(goal), source=\(source), "
                                    + "delay=\(delay), cursor=\(includesCursor), "
                                    + "private=\(privateCapture), "
                                    + "uiMap=\(windowUIMapEnabled)"

                                XCTAssertEqual(
                                    normalized.normalized(
                                        for: capabilities
                                    ),
                                    normalized,
                                    "Normalization must be idempotent: \(context)"
                                )
                                XCTAssertEqual(
                                    plan.goal,
                                    normalized.goal,
                                    context
                                )
                                XCTAssertEqual(
                                    plan.source,
                                    normalized.source,
                                    context
                                )
                                XCTAssertEqual(
                                    plan.captureOptions,
                                    CaptureOneShotOptions(
                                        captureDelay:
                                            normalized.captureDelay,
                                        includesCursor:
                                            normalized.includesCursor,
                                        privateCapture:
                                            normalized.privateCapture,
                                        windowUIMapEnabled:
                                            normalized.windowUIMapEnabled
                                    ),
                                    context
                                )

                                if normalized.goal
                                    == .instructions(.recordAsIWork) {
                                    XCTAssertEqual(
                                        normalized.source,
                                        .region,
                                        "Guide owns source selection: \(context)"
                                    )
                                    XCTAssertNil(plan.documentPurpose, context)
                                    XCTAssertNil(
                                        plan.captureCompletionRole,
                                        context
                                    )
                                } else {
                                    XCTAssertNotNil(
                                        plan.documentPurpose,
                                        context
                                    )
                                    XCTAssertNotNil(
                                        plan.captureCompletionRole,
                                        context
                                    )
                                }

                                if !normalized.source.supportsCaptureDelay {
                                    XCTAssertEqual(
                                        normalized.captureDelay,
                                        .immediate,
                                        "A hidden timer must not leak: \(context)"
                                    )
                                }
                                if !normalized.source.supportsPointerCapture {
                                    XCTAssertFalse(
                                        normalized.includesCursor,
                                        "A hidden cursor choice must not leak: \(context)"
                                    )
                                }
                                XCTAssertEqual(
                                    normalized.windowUIMapEnabled,
                                    source == .window
                                        && goal
                                            != .instructions(.recordAsIWork)
                                        && windowUIMapEnabled,
                                    "UI Map is valid only for Window: \(context)"
                                )
                                XCTAssertEqual(
                                    normalized.privateCapture,
                                    privateCapture,
                                    context
                                )
                            }
                        }
                    }
                }
            }
        }

        XCTAssertEqual(combinationCount, 1_760)
    }

    func testEveryUnavailableCreationSourceFallsBackWithoutLeakingChoices() {
        let editorOnlyCapabilities = AppCapabilitySnapshot(
            buildTarget: .dev,
            enabledCapabilities: [.editor]
        )
        let goals: [CreationGoal] = [
            .screenshot,
            .comparison,
            .instructions(.recordAsIWork),
            .instructions(.addCaptures),
            .combineImages,
        ]
        let sources: [CreationSource] = [
            .region,
            .window,
            .screen,
            .scrolling,
            .connectedDevice,
            .screenInspector,
            .existing(.files),
            .existing(.clipboard),
            .existing(.recentSnips),
            .existing(.captureHistory),
            .existing(.archive),
        ]

        for goal in goals {
            for source in sources {
                let normalized = CreationDraft(
                    goal: goal,
                    source: source,
                    captureDelay: .tenSeconds,
                    includesCursor: true,
                    privateCapture: true,
                    windowUIMapEnabled: true
                ).normalized(for: editorOnlyCapabilities)
                let context = "goal=\(goal), source=\(source)"

                XCTAssertEqual(
                    normalized.goal,
                    goal == .instructions(.recordAsIWork)
                        ? .instructions(.addCaptures)
                        : goal,
                    context
                )
                XCTAssertEqual(
                    normalized.source,
                    source == .existing(.files)
                        || source == .existing(.clipboard)
                        ? source
                        : .existing(.files),
                    context
                )
                XCTAssertEqual(normalized.captureDelay, .immediate, context)
                XCTAssertFalse(normalized.includesCursor, context)
                XCTAssertFalse(normalized.privateCapture, context)
                XCTAssertFalse(normalized.windowUIMapEnabled, context)
                XCTAssertNotNil(
                    normalized.plan(
                        for: editorOnlyCapabilities
                    ).documentPurpose,
                    context
                )
            }
        }
    }

    func testDraftNormalizationRemovesHiddenChoices() {
        let normalized = CreationDraft(
            goal: .screenshot,
            source: .region,
            captureDelay: .fiveSeconds,
            includesCursor: true,
            privateCapture: true,
            windowUIMapEnabled: true
        ).normalized(for: testCapabilities)

        XCTAssertEqual(normalized.source, .region)
        XCTAssertEqual(normalized.captureDelay, .fiveSeconds)
        XCTAssertTrue(normalized.includesCursor)
        XCTAssertTrue(normalized.privateCapture)
        XCTAssertFalse(normalized.windowUIMapEnabled)
    }

    func testCreationSourcesExposeOnlySupportedFineTuneControls() {
        XCTAssertTrue(CreationSource.region.supportsCaptureDelay)
        XCTAssertTrue(CreationSource.window.supportsCaptureDelay)
        XCTAssertTrue(CreationSource.screen.supportsCaptureDelay)
        XCTAssertTrue(CreationSource.scrolling.supportsCaptureDelay)
        XCTAssertFalse(CreationSource.connectedDevice.supportsCaptureDelay)
        XCTAssertFalse(CreationSource.screenInspector.supportsCaptureDelay)
        XCTAssertFalse(
            CreationSource.existing(.files).supportsCaptureDelay
        )

        XCTAssertTrue(CreationSource.region.supportsPointerCapture)
        XCTAssertTrue(CreationSource.window.supportsPointerCapture)
        XCTAssertTrue(CreationSource.screen.supportsPointerCapture)
        XCTAssertFalse(CreationSource.scrolling.supportsPointerCapture)
        XCTAssertFalse(CreationSource.connectedDevice.supportsPointerCapture)
        XCTAssertFalse(CreationSource.screenInspector.supportsPointerCapture)
        XCTAssertFalse(
            CreationSource.existing(.clipboard).supportsPointerCapture
        )

        let noOptionalFineTuneCapabilities = AppCapabilitySnapshot(
            buildTarget: .dev,
            enabledCapabilities: Set(AppCapability.allCases).subtracting([
                .privateCapture,
                .uiMap,
            ])
        )
        XCTAssertTrue(
            CreationSource.region.hasFineTuneOptions(
                for: noOptionalFineTuneCapabilities
            )
        )
        XCTAssertTrue(
            CreationSource.scrolling.hasFineTuneOptions(
                for: noOptionalFineTuneCapabilities
            )
        )
        XCTAssertFalse(
            CreationSource.connectedDevice.hasFineTuneOptions(
                for: noOptionalFineTuneCapabilities
            )
        )
        XCTAssertFalse(
            CreationSource.screenInspector.hasFineTuneOptions(
                for: noOptionalFineTuneCapabilities
            )
        )
        XCTAssertFalse(
            CreationSource.existing(.files).hasFineTuneOptions(
                for: testCapabilities
            )
        )
        XCTAssertTrue(
            CreationSource.connectedDevice.hasFineTuneOptions(
                for: testCapabilities
            ),
            "Private Capture is a Fine-tune option for live sources."
        )
    }

    func testUnavailableGuideCreationFallsBackToManualSteps() {
        let capabilities = AppCapabilitySnapshot(
            buildTarget: .dev,
            enabledCapabilities:
                Set(AppCapability.allCases).subtracting([.guideCapture])
        )

        let normalized = CreationDraft(
            goal: .instructions(.recordAsIWork),
            source: .window
        ).normalized(for: capabilities)

        XCTAssertEqual(
            normalized.goal,
            .instructions(.addCaptures)
        )
        XCTAssertEqual(normalized.source, .window)
        XCTAssertEqual(normalized.plan(for: capabilities).documentPurpose, .steps)
    }

    func testConnectedDeviceSelectionRetainsPlanAndCancellationRestoresDraft() {
        let workflow = CreationWorkflowModel(
            capabilities: testCapabilities
        )
        workflow.startHandler = { _ in
            .awaitingConnectedDeviceSelection
        }
        workflow.presentQuickStart(
            prefilledDraft: CreationDraft(
                goal: .comparison,
                source: .connectedDevice,
                captureDelay: .threeSeconds,
                includesCursor: true,
                privateCapture: true
            )
        )

        XCTAssertEqual(
            workflow.commitQuickStart(),
            .awaitingConnectedDeviceSelection
        )
        XCTAssertFalse(workflow.isShowingQuickStart)
        XCTAssertEqual(
            workflow.pendingConnectedDevicePlan?.captureCompletionRole,
            .comparisonBefore
        )
        XCTAssertEqual(
            workflow.pendingConnectedDevicePlan?.captureOptions.captureDelay,
            .immediate
        )
        XCTAssertFalse(
            workflow.pendingConnectedDevicePlan?.captureOptions.includesCursor
                ?? true
        )

        workflow.cancelConnectedDeviceSelection()

        XCTAssertTrue(workflow.isShowingQuickStart)
        XCTAssertNil(workflow.pendingConnectedDevicePlan)
        XCTAssertEqual(workflow.draft.goal, .comparison)
        XCTAssertEqual(workflow.draft.source, .connectedDevice)
    }

    func testSelectingConnectedDeviceUsesExactPendingRoleAndOptions() {
        let workflow = CreationWorkflowModel(
            capabilities: testCapabilities
        )
        workflow.startHandler = { _ in
            .awaitingConnectedDeviceSelection
        }
        var received: (ConnectedAppleDevice, CreationPlan)?
        workflow.connectedDeviceSelectionHandler = { device, plan in
            received = (device, plan)
        }
        workflow.presentQuickStart(
            prefilledDraft: CreationDraft(
                goal: .combineImages,
                source: .connectedDevice,
                privateCapture: true
            )
        )
        _ = workflow.commitQuickStart()
        let device = ConnectedAppleDevice(
            id: "device-1",
            name: "Test iPhone"
        )

        workflow.selectConnectedDevice(device)

        XCTAssertEqual(received?.0, device)
        XCTAssertEqual(received?.1.captureCompletionRole, .collectionItem)
        XCTAssertTrue(received?.1.captureOptions.privateCapture == true)
        XCTAssertNil(workflow.pendingConnectedDevicePlan)
    }

    func testScreenInspectorCloseClearsExactPreparedContext() {
        let capture = CreationCaptureSpy()
        let documents = CreationDocumentSpy()
        let guide = CreationGuideSpy()
        let tools = CreationToolSpy()
        let starter = CreationPlanStarter(
            capture: capture,
            documents: documents,
            guide: guide,
            tools: tools
        )
        let plan = CreationDraft(
            goal: .instructions(.addCaptures),
            source: .screenInspector,
            privateCapture: true
        ).plan(for: testCapabilities)

        XCTAssertEqual(starter.start(plan), .started)
        XCTAssertEqual(capture.preparedContext?.intent, .newDocument)
        XCTAssertEqual(capture.preparedContext?.role, .step)
        XCTAssertEqual(
            capture.preparedContext?.oneShotOptions,
            plan.captureOptions
        )
        let sessionID = capture.preparedContext?
            .persistentSurfaceSessionID
        XCTAssertNotNil(sessionID)

        tools.closeHandler?()

        XCTAssertEqual(capture.resetPersistentSessionIDs, [sessionID])
    }

    func testOneItemIntentControllersStartInSafeGoalLayouts() {
        let comparison = EditorController(
            capture: makeCapturedScreenshot(sourceName: "Before"),
            capabilities: testCapabilities,
            documentPurpose: .comparison,
            workflowResumeState: ScreenshotWorkflowResumeState(
                stage: .awaitingComparisonAfter
            )
        )
        XCTAssertEqual(comparison.documentPurpose, .comparison)
        XCTAssertEqual(comparison.workflowStage, .awaitingComparisonAfter)
        XCTAssertEqual(comparison.composition?.layout.mode, .auto)
        XCTAssertFalse(comparison.hasComposition)
        XCTAssertFalse(comparison.canUndo)

        let steps = EditorController(
            capture: makeCapturedScreenshot(sourceName: "Step 1"),
            capabilities: testCapabilities,
            documentPurpose: .steps,
            workflowResumeState: ScreenshotWorkflowResumeState(
                stage: .collecting
            )
        )
        XCTAssertEqual(steps.composition?.layout.mode, .steps)
        XCTAssertTrue(steps.hasComposition)
        XCTAssertFalse(steps.canUndo)

        let collection = EditorController(
            capture: makeCapturedScreenshot(sourceName: "Image 1"),
            capabilities: testCapabilities,
            documentPurpose: .collection,
            workflowResumeState: ScreenshotWorkflowResumeState(
                stage: .collecting
            )
        )
        XCTAssertEqual(collection.composition?.layout.mode, .auto)
        XCTAssertTrue(collection.hasComposition)
        XCTAssertFalse(collection.canUndo)
    }

    func testCapturedIntentSourcesInstallWithFocusedPurposeStageAndWorkspace() {
        let suiteName =
            "IntentDrivenCreationWorkflowTests.focusedInstallation"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let legacyPreferenceController = EditorController(
            capture: makeCapturedScreenshot(),
            defaults: defaults,
            capabilities: testCapabilities
        )
        legacyPreferenceController.setDefaultPresentationTemplate(
            id: "builtin.drop-shadow"
        )
        let model = AppModel(
            defaults: defaults,
            recoveryStore: DocumentRecoveryStore(baseURL: nil),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )

        let screenshotInstallation =
            model.documents.installCapturedScreenshot(
                captureResult(
                    sourceName: "Screenshot",
                    role: .standalone
                )
            )
        let screenshot = try! XCTUnwrap(
            screenshotInstallation.controller
        )
        XCTAssertEqual(screenshot.documentPurpose, .screenshot)
        XCTAssertEqual(screenshot.workflowStage, .editing)
        XCTAssertEqual(screenshot.workspaceMode, .edit)
        XCTAssertEqual(screenshot.snapshot.presentation, .plain)

        let beforeInstallation = model.documents.installCapturedScreenshot(
            captureResult(
                sourceName: "Before",
                role: .comparisonBefore
            )
        )
        let comparison = try! XCTUnwrap(beforeInstallation.controller)
        XCTAssertEqual(comparison.documentPurpose, .comparison)
        XCTAssertEqual(comparison.workflowStage, .awaitingComparisonAfter)
        XCTAssertEqual(comparison.workspaceMode, .edit)
        XCTAssertFalse(comparison.hasComposition)
        XCTAssertFalse(comparison.canUndo)
        XCTAssertEqual(comparison.snapshot.presentation, .plain)

        let stepsInstallation = model.documents.installCapturedScreenshot(
            captureResult(
                sourceName: "Step 1",
                role: .step
            )
        )
        let steps = try! XCTUnwrap(stepsInstallation.controller)
        XCTAssertEqual(steps.documentPurpose, .steps)
        XCTAssertEqual(steps.workflowStage, .collecting)
        XCTAssertEqual(steps.workspaceMode, .presentation)
        XCTAssertEqual(steps.composition?.layout.mode, .steps)
        XCTAssertTrue(steps.hasComposition)
        XCTAssertFalse(steps.canUndo)
        XCTAssertEqual(steps.snapshot.presentation, .plain)

        let collectionInstallation =
            model.documents.installCapturedScreenshot(
                captureResult(
                    sourceName: "Image 1",
                    role: .collectionItem
                )
            )
        let collection = try! XCTUnwrap(collectionInstallation.controller)
        XCTAssertEqual(collection.documentPurpose, .collection)
        XCTAssertEqual(collection.workflowStage, .collecting)
        XCTAssertEqual(collection.workspaceMode, .presentation)
        XCTAssertEqual(collection.composition?.layout.mode, .auto)
        XCTAssertTrue(collection.hasComposition)
        XCTAssertFalse(collection.canUndo)
        XCTAssertEqual(collection.snapshot.presentation, .plain)
    }

    func testComparisonAfterAppendPromotesAtomicallyAndUndoReturnsToBefore() {
        let suiteName =
            "IntentDrivenCreationWorkflowTests.comparisonAppend"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let model = AppModel(
            defaults: defaults,
            recoveryStore: DocumentRecoveryStore(baseURL: nil),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )
        let initial = model.documents.installCapturedScreenshot(
            captureResult(
                sourceName: "Before",
                role: .comparisonBefore
            )
        )
        let controller = try! XCTUnwrap(initial.controller)

        _ = model.documents.installCapturedScreenshot(
            captureResult(
                sourceName: "After",
                role: .comparisonAfter,
                intent: .append(
                    documentGenerationID:
                        controller.documentGenerationID,
                    afterItemID: nil
                )
            )
        )

        XCTAssertEqual(controller.compositionItemCount, 2)
        XCTAssertEqual(controller.documentPurpose, .comparison)
        XCTAssertEqual(controller.composition?.layout.mode, .compare)
        XCTAssertEqual(controller.workflowStage, .reviewingComparison)
        XCTAssertEqual(controller.workspaceMode, .presentation)

        controller.undo()

        XCTAssertEqual(controller.compositionItemCount, 1)
        XCTAssertEqual(controller.documentPurpose, .comparison)
        XCTAssertEqual(controller.workflowStage, .awaitingComparisonAfter)
        XCTAssertFalse(controller.hasComposition)
    }

    func testNestedBatchRollbackPreservesEarlierValidImports() throws {
        let controller = EditorController(
            capture: makeCapturedScreenshot(sourceName: "Root"),
            capabilities: testCapabilities
        )

        controller.beginCoalescedEditorGesture()
        _ = try controller.appendCaptureToComposition(
            makeCapturedScreenshot(sourceName: "Valid"),
            isPrivate: false
        )
        controller.beginCoalescedEditorGesture()
        _ = try controller.appendCaptureToComposition(
            makeCapturedScreenshot(sourceName: "Failed transaction"),
            isPrivate: false
        )
        controller.cancelCoalescedEditorGesture()

        XCTAssertEqual(controller.compositionItemCount, 2)

        controller.endCoalescedEditorGesture()
        controller.undo()

        XCTAssertEqual(controller.compositionItemCount, 1)
    }

    func testScreenshotExistingEditablePackageIsAlwaysOneFlattenedItem()
        throws
    {
        let fixture = try makeIntentFixture(named: #function)
        defer { fixture.cleanup() }
        let packageURL = fixture.directory.appendingPathComponent(
            "Multi Item.sss",
            isDirectory: true
        )
        let source = EditorController(
            capture: makeCapturedScreenshot(sourceName: "First")
        )
        _ = try source.appendCaptureToComposition(
            makeCapturedScreenshot(sourceName: "Second"),
            isPrivate: false
        )
        try SSSDocumentPackage.save(
            document: source.editableDocument,
            previewImage: source.documentCapture.image,
            to: packageURL
        )
        let entry = intentHistoryEntry(
            packageURL: packageURL,
            title: "Multi Item"
        )
        fixture.model.documents.compositionEditableImportChoiceHandler = {
            _ in
            XCTFail("Screenshot creation must not offer editable import.")
            return .editable
        }

        XCTAssertTrue(
            fixture.model.documents.createDocument(
                from: entry,
                flattened: false,
                completionRole: .standalone
            )
        )

        let controller = try XCTUnwrap(
            fixture.model.documents.editorController
        )
        XCTAssertEqual(controller.documentPurpose, .screenshot)
        XCTAssertEqual(controller.compositionItemCount, 1)
        XCTAssertFalse(controller.hasComposition)
        XCTAssertEqual(controller.workspaceMode, .edit)
    }

    func testAllInvalidExistingBatchReportsEveryFailure() throws {
        let fixture = try makeIntentFixture(named: #function)
        defer { fixture.cleanup() }
        let first = fixture.directory.appendingPathComponent("First.png")
        let second = fixture.directory.appendingPathComponent("Second.png")
        try Data("invalid one".utf8).write(to: first)
        try Data("invalid two".utf8).write(to: second)
        let existingController = EditorController(
            capture: makeCapturedScreenshot(sourceName: "Existing")
        )
        fixture.model.documents.installEditorController(
            existingController,
            documentURL: nil,
            savedSession: nil,
            shouldCreateRecoverySession: false
        )

        XCTAssertFalse(
            fixture.model.documents.createDocumentFromFiles(
                [first, second],
                completionRole: .collectionItem,
                options: intentOneShotOptions
            )
        )

        XCTAssertTrue(
            fixture.model.documents.editorController === existingController
        )
        let message = try XCTUnwrap(fixture.model.lifecycle.errorMessage)
        XCTAssertTrue(message.contains("Added: 0. Failed: 2."))
        XCTAssertTrue(message.contains("First.png"))
        XCTAssertTrue(message.contains("Second.png"))
    }

    func testPasteAndHistoryAdditionsRouteToFocusedWorkspace() throws {
        let fixture = try makeIntentFixture(named: #function)
        defer { fixture.cleanup() }
        let controller = EditorController(
            capture: makeCapturedScreenshot(sourceName: "Root")
        )
        fixture.model.documents.installEditorController(
            controller,
            documentURL: nil,
            savedSession: nil,
            shouldCreateRecoverySession: false
        )

        fixture.model.documents.pasteImageIntoCurrentComposition(
            makeSolidImage(
                width: 12,
                height: 8,
                color: PixelSample(
                    red: 20,
                    green: 40,
                    blue: 60,
                    alpha: 255
                )
            ),
            completionRole: .step
        )

        XCTAssertEqual(controller.documentPurpose, .steps)
        XCTAssertEqual(controller.workflowStage, .collecting)
        XCTAssertEqual(controller.workspaceMode, .presentation)

        let packageURL = fixture.directory.appendingPathComponent(
            "History.sss",
            isDirectory: true
        )
        let historySource = EditorController(
            capture: makeCapturedScreenshot(sourceName: "History")
        )
        try SSSDocumentPackage.save(
            document: historySource.editableDocument,
            previewImage: historySource.documentCapture.image,
            to: packageURL
        )
        controller.setWorkspaceMode(.edit)
        fixture.model.documents.addHistoryEntryToCurrentComposition(
            intentHistoryEntry(
                packageURL: packageURL,
                title: "History"
            ),
            flattened: true,
            completionRole: .collectionItem
        )

        XCTAssertEqual(controller.documentPurpose, .collection)
        XCTAssertEqual(controller.workflowStage, .arranging)
        XCTAssertEqual(controller.workspaceMode, .presentation)
    }

    func testScreenInspectorStepsSessionAdvancesIntoSeamlessAppendLoop() {
        let suiteName =
            "IntentDrivenCreationWorkflowTests.screenInspectorLoop"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let model = AppModel(
            defaults: defaults,
            recoveryStore: DocumentRecoveryStore(baseURL: nil),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )
        let initialContext =
            model.capture.prepareScreenInspectorCaptureIntent(
                .newDocument,
                completionRole: .step,
                oneShotOptions: intentOneShotOptions
            )
        let sessionID = initialContext.persistentSurfaceSessionID

        model.capture.completeScreenInspectorSnip(
            screenInspectorSample(red: 20)
        )

        let controller = try! XCTUnwrap(
            model.documents.editorController
        )
        XCTAssertEqual(controller.documentPurpose, .steps)
        XCTAssertEqual(controller.compositionItemCount, 1)
        XCTAssertEqual(
            model.capture.screenInspectorCaptureContext?.role,
            .step
        )
        XCTAssertEqual(
            model.capture.screenInspectorCaptureContext?
                .persistentSurfaceSessionID,
            sessionID
        )
        guard case .append(let generationID, _) =
            model.capture.screenInspectorCaptureContext?.intent else {
            return XCTFail("Steps should continue with an append intent.")
        }
        XCTAssertEqual(generationID, controller.documentGenerationID)

        model.capture.completeScreenInspectorSnip(
            screenInspectorSample(red: 80)
        )

        XCTAssertEqual(controller.compositionItemCount, 2)
        XCTAssertEqual(controller.documentPurpose, .steps)
        XCTAssertEqual(controller.workflowStage, .collecting)
        XCTAssertEqual(
            model.capture.screenInspectorCaptureContext?.role,
            .step
        )
    }

    func testAsyncCaptureCompletionUsesOwnedContextWhenActiveSlotChanges()
        async throws
    {
        let suiteName =
            "IntentDrivenCreationWorkflowTests.contextOwnership"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let environment = AppEnvironment(
            defaults: defaults,
            permissions: TestCapturePermissionService()
        )
        let model = AppModel(
            defaults: defaults,
            environment: environment,
            recoveryStore: DocumentRecoveryStore(baseURL: nil),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )
        let initial = model.documents.installCapturedScreenshot(
            captureResult(sourceName: "Step 1", role: .step)
        )
        let controller = try XCTUnwrap(initial.controller)
        let ownedContext = CaptureCompletionContext(
            intent: .append(
                documentGenerationID: controller.documentGenerationID,
                afterItemID: controller.composition?.items.last?.id
            ),
            role: .step,
            oneShotOptions: intentOneShotOptions
        )
        let replacementActiveContext = CaptureCompletionContext(
            intent: .newDocument,
            role: .standalone,
            oneShotOptions: nil
        )
        let gate = AsyncCaptureCompletionGate()

        let captureTask = Task { @MainActor in
            await model.capture.performCapture(
                request: .fullscreen,
                runOptions: CaptureRunOptions(),
                completionContext: ownedContext
            ) {
                try await gate.waitForCapture()
            }
        }
        while !gate.isWaiting {
            await Task.yield()
        }

        model.capture.activeCaptureContext =
            replacementActiveContext
        gate.complete(
            with: makeCapturedScreenshot(
                kind: .fullscreen,
                sourceName: "Step 2"
            )
        )

        let didComplete = await captureTask.value
        XCTAssertTrue(didComplete)
        XCTAssertEqual(controller.compositionItemCount, 2)
        XCTAssertEqual(controller.documentPurpose, .steps)
        XCTAssertEqual(controller.workflowStage, .collecting)
        XCTAssertTrue(model.documents.editorController === controller)
        XCTAssertEqual(
            model.capture.activeCaptureContext,
            replacementActiveContext
        )
    }

    func testAddingCaptureFromPolishReturnsEveryGoalToFocusedContent() {
        struct Case {
            let initialRole: CaptureCompletionRole
            let appendRole: CaptureCompletionRole
            let expectedPurpose: ScreenshotDocumentPurpose
            let expectedStage: ScreenshotWorkflowStage
        }
        let cases = [
            Case(
                initialRole: .comparisonBefore,
                appendRole: .comparisonAfter,
                expectedPurpose: .comparison,
                expectedStage: .reviewingComparison
            ),
            Case(
                initialRole: .step,
                appendRole: .step,
                expectedPurpose: .steps,
                expectedStage: .collecting
            ),
            Case(
                initialRole: .collectionItem,
                appendRole: .collectionItem,
                expectedPurpose: .collection,
                expectedStage: .arranging
            ),
        ]

        for testCase in cases {
            let suiteName =
                "IntentDrivenCreationWorkflowTests.addFromPolish."
                + UUID().uuidString
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            defer {
                defaults.removePersistentDomain(forName: suiteName)
            }
            let model = AppModel(
                defaults: defaults,
                recoveryStore: DocumentRecoveryStore(baseURL: nil),
                shouldCheckCompatibilityOnLaunch: false,
                shouldStartArchiveMaintenance: false
            )
            let initial = model.documents.installCapturedScreenshot(
                captureResult(
                    sourceName: "First",
                    role: testCase.initialRole
                )
            )
            let controller = try! XCTUnwrap(initial.controller)
            controller.applyPresentationPreset(.lifted)
            controller.enterPolish()
            controller.restoreWorkflowWorkspace()

            XCTAssertEqual(controller.workflowStage, .polishing)
            XCTAssertEqual(
                controller.currentWorkspaceOutputAppearance,
                .styled
            )

            _ = model.documents.installCapturedScreenshot(
                captureResult(
                    sourceName: "Added",
                    role: testCase.appendRole,
                    intent: .append(
                        documentGenerationID:
                            controller.documentGenerationID,
                        afterItemID:
                            controller.composition?.items.last?.id
                    )
                )
            )

            XCTAssertEqual(controller.compositionItemCount, 2)
            XCTAssertEqual(
                controller.documentPurpose,
                testCase.expectedPurpose
            )
            XCTAssertEqual(
                controller.workflowStage,
                testCase.expectedStage
            )
            XCTAssertNil(controller.workflowResumeState.returnStage)
            XCTAssertEqual(controller.workspaceMode, .presentation)
            XCTAssertEqual(controller.presentationInspectorTab, .layout)
            XCTAssertEqual(
                controller.currentWorkspaceOutputAppearance,
                .plain,
                "Add Capture must never leave output in Polish."
            )
        }
    }

    private func captureResult(
        sourceName: String,
        role: CaptureCompletionRole,
        intent: CaptureIntent = .newDocument
    ) -> CaptureWorkflowResult {
        let capture = makeCapturedScreenshot(sourceName: sourceName)
        return CaptureWorkflowResult(
            capture: capture,
            uiMapSourceCapture: capture,
            request: .fullscreen,
            runOptions: CaptureRunOptions(),
            isPrivateCapture: false,
            checkpointLabel: "Capture",
            shouldAttemptUIMapCapture: false,
            shouldProcessUIMap: false,
            uiMapSkipReason: nil,
            workflowPreset: nil,
            intent: intent,
            completionRole: role
        )
    }

    private var intentOneShotOptions: CaptureOneShotOptions {
        CaptureOneShotOptions(
            captureDelay: .immediate,
            includesCursor: false,
            privateCapture: false,
            windowUIMapEnabled: false
        )
    }

    private func screenInspectorSample(red: UInt8) -> ScreenInspectorSample {
        ScreenInspectorSample(
            image: makeSolidImage(
                width: 10,
                height: 8,
                color: PixelSample(
                    red: red,
                    green: 30,
                    blue: 40,
                    alpha: 255
                )
            ),
            cursorLocation: CGPoint(x: 2, y: 3),
            sourceRect: CGRect(x: 10, y: 20, width: 10, height: 8),
            color: ScreenInspectorPixelColor(
                red: red,
                green: 30,
                blue: 40,
                alpha: 255
            )
        )
    }

    private func makeIntentFixture(named name: String) throws
        -> IntentCreationFixture
    {
        let suiteName = "IntentDrivenCreationWorkflowTests.\(name)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let model = retainForTestLifetime(
            AppModel(
                defaults: defaults,
                recoveryStore: DocumentRecoveryStore(baseURL: nil),
                shouldCheckCompatibilityOnLaunch: false,
                shouldStartArchiveMaintenance: false
            )
        )
        return IntentCreationFixture(
            model: model,
            defaults: defaults,
            suiteName: suiteName,
            directory: directory
        )
    }

    private func intentHistoryEntry(
        packageURL: URL,
        title: String
    ) -> DocumentHistoryEntry {
        DocumentHistoryEntry(
            id: UUID(),
            sessionID: UUID(),
            title: title,
            label: "Capture",
            changeSummary: nil,
            savedAt: Date(timeIntervalSince1970: 1_700_000_000),
            packageURL: packageURL,
            previewAssetURL: nil,
            sourceDocumentURL: nil,
            hasUnsavedChanges: false,
            searchableText: title,
            packageSizeBytes: nil,
            deletedAt: nil
        )
    }
}

@MainActor
private final class CreationCaptureSpy: CreationCaptureWorkflowPort {
    var preparedContext: CaptureCompletionContext?
    var resetContexts: [CaptureCompletionContext] = []
    var resetPersistentSessionIDs: [UUID?] = []

    func captureRegion(
        intent: CaptureIntent,
        completionRole: CaptureCompletionRole,
        oneShotOptions: CaptureOneShotOptions?
    ) {}

    func presentWindowPicker(
        intent: CaptureIntent,
        completionRole: CaptureCompletionRole,
        oneShotOptions: CaptureOneShotOptions?
    ) {}

    func captureCurrentDisplay(
        intent: CaptureIntent,
        completionRole: CaptureCompletionRole,
        oneShotOptions: CaptureOneShotOptions?
    ) {}

    func captureScrollingArea(
        intent: CaptureIntent,
        completionRole: CaptureCompletionRole,
        oneShotOptions: CaptureOneShotOptions?
    ) {}

    func prepareCaptureIntent(
        _ intent: CaptureIntent,
        completionRole: CaptureCompletionRole,
        oneShotOptions: CaptureOneShotOptions?
    ) {
        preparedContext = CaptureCompletionContext(
            intent: intent,
            role: completionRole,
            oneShotOptions: oneShotOptions
        )
    }

    func preparePersistentCaptureSurfaceIntent(
        _ intent: CaptureIntent,
        completionRole: CaptureCompletionRole,
        oneShotOptions: CaptureOneShotOptions?
    ) -> CaptureCompletionContext {
        let context = CaptureCompletionContext(
            intent: intent,
            role: completionRole,
            oneShotOptions: oneShotOptions,
            persistentSurfaceSessionID: UUID()
        )
        preparedContext = context
        return context
    }

    func prepareScreenInspectorCaptureIntent(
        _ intent: CaptureIntent,
        completionRole: CaptureCompletionRole,
        oneShotOptions: CaptureOneShotOptions?
    ) -> CaptureCompletionContext {
        preparePersistentCaptureSurfaceIntent(
            intent,
            completionRole: completionRole,
            oneShotOptions: oneShotOptions
        )
    }

    func resetPreparedCaptureContext(
        ifMatching context: CaptureCompletionContext
    ) {
        resetContexts.append(context)
        if preparedContext == context {
            preparedContext = nil
        }
    }

    func resetPersistentCaptureSurfaceSession(_ sessionID: UUID) {
        resetPersistentSessionIDs.append(sessionID)
        if preparedContext?.persistentSurfaceSessionID == sessionID {
            preparedContext = nil
        }
    }
}

@MainActor
private final class CreationDocumentSpy: CreationDocumentWorkflowPort {
    func createDocumentFromFiles(
        completionRole: CaptureCompletionRole,
        options: CaptureOneShotOptions
    ) -> Bool {
        false
    }

    func createDocumentFromClipboard(
        completionRole: CaptureCompletionRole,
        options: CaptureOneShotOptions
    ) -> Bool {
        false
    }
}

@MainActor
private final class CreationGuideSpy: CreationGuideWorkflowPort {
    func presentQuickStart() {}
}

@MainActor
private final class CreationToolSpy: CreationToolWorkflowPort {
    var closeHandler: (() -> Void)?

    func presentScreenInspector(onClose: (() -> Void)?) {
        closeHandler = onClose
    }
}

@MainActor
private struct IntentCreationFixture {
    let model: AppModel
    let defaults: UserDefaults
    let suiteName: String
    let directory: URL

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class AsyncCaptureCompletionGate {
    private var continuation:
        CheckedContinuation<CapturedScreenshot, Error>?

    var isWaiting: Bool {
        continuation != nil
    }

    func waitForCapture() async throws -> CapturedScreenshot {
        try await withCheckedThrowingContinuation {
            continuation = $0
        }
    }

    func complete(with capture: CapturedScreenshot) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: capture)
    }
}
