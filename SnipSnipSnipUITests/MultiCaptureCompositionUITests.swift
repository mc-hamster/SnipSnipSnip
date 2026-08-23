import XCTest

@MainActor
final class MultiCaptureCompositionUITests: XCTestCase {
    private enum IntentGoal: Equatable {
        case comparison
        case steps
        case collection

        var chooserTitle: String {
            switch self {
            case .comparison:
                return "Compare"
            case .steps:
                return "Add as Step"
            case .collection:
                return "Combine"
            }
        }

        var inspectorIdentifier: String {
            switch self {
            case .comparison:
                return "composition.comparison"
            case .steps:
                return "composition.steps"
            case .collection:
                return "composition.layout"
            }
        }

        var sessionValueFragment: String {
            switch self {
            case .comparison:
                return "Comparison"
            case .steps:
                return "Steps"
            case .collection:
                return "Combined Image"
            }
        }

        var primarySessionAction: String {
            switch self {
            case .comparison:
                return "Review Changes"
            case .steps:
                return "Add Step"
            case .collection:
                return "Add Image"
            }
        }
    }

    private var app: XCUIApplication!
    private var artifactDirectory: URL!

    override func setUp() async throws {
        try await MainActor.run {
            continueAfterFailure = false

            let runIdentifier = UUID().uuidString
            artifactDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "SnipSnipSnip-CompositionUISmoke-\(runIdentifier)",
                    isDirectory: true
                )
            try FileManager.default.createDirectory(
                at: artifactDirectory,
                withIntermediateDirectories: true
            )

            app = XCUIApplication()
            app.launchArguments.append(
                "--snipsnipsnip-composition-ui-testing"
            )
            app.launchEnvironment["SNIPSNIPSNIP_UI_TEST_RUN_ID"] =
                runIdentifier
            app.launchEnvironment[
                "SNIPSNIPSNIP_UI_TEST_ARTIFACT_DIRECTORY"
            ] = artifactDirectory.path
            app.launch()
            app.activate()
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            app?.terminate()
            app = nil
            artifactDirectory = nil
        }
    }

    func testAddCaptureEntersAutoLayout() {
        verifyDeterministicLaunchAndPromote(to: .collection)
    }

    func testEveryLayoutAndCompositionEditingRoundTrip() {
        verifyDeterministicLaunchAndPromote(to: .collection)
        verifyEveryLayoutAndCompositionEditing()
    }

    func testOutputDragControlRendersOnceWithoutOverlappingFloat() {
        verifyDeterministicLaunchAndPromote(to: .collection)

        let drag = identified("editor.output.drag.current")
        revealInContentCommandBar(drag)
        XCTAssertTrue(
            drag.waitForExistence(timeout: 5),
            "The visible content stage should expose one complete Drag control."
        )
        XCTAssertEqual(
            app.descendants(matching: .any)
                .matching(identifier: "editor.output.drag.current")
                .count,
            1,
            "Only one Drag control may be rendered."
        )
        XCTAssertGreaterThanOrEqual(drag.frame.width, 66)
        XCTAssertLessThanOrEqual(drag.frame.width, 70)

        let float = app.buttons["Float"].firstMatch
        XCTAssertTrue(float.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(
            float.frame.maxX,
            drag.frame.minX,
            "Float and Drag must remain separate, non-overlapping controls."
        )
        XCTAssertFalse(
            app.staticTexts["Drag"].exists,
            "The AppKit drag control already owns its visible label."
        )
    }

    func testCreateFrontDoorOffersFourPlainLanguageGoals() {
        verifyInitialScreenshotSession()

        let create = identified("creation.present")
        XCTAssertTrue(
            create.waitForExistence(timeout: 5),
            "Create should remain available while a screenshot is open."
        )
        create.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).click()

        XCTAssertTrue(
            identified("creation.quickStart").waitForExistence(timeout: 5)
        )
        XCTAssertTrue(identified("creation.goal").exists)
        for goal in [
            "Capture a screenshot",
            "Compare two versions",
            "Explain a process",
            "Combine images",
        ] {
            XCTAssertTrue(
                app.staticTexts[goal].exists || app.radioButtons[goal].exists,
                "Create should offer \(goal) as a durable user goal."
            )
        }
        XCTAssertTrue(identified("creation.source").exists)
        XCTAssertTrue(identified("creation.summary").exists)
        let primaryAction = app.buttons["Capture Screenshot"].firstMatch
        XCTAssertTrue(
            primaryAction.waitForExistence(timeout: 5),
            "Create should expose one plain-language primary action."
        )
        XCTAssertTrue(
            primaryAction.isHittable,
            "The primary Create action must remain visible at the minimum window size."
        )

        app.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(
            identified("editor.annotationCanvas").waitForExistence(timeout: 5),
            "Cancelling Create must leave the current screenshot untouched."
        )
        assertScreenshotInspectorIsolation()
    }

    func testFirstAdditionalImageAsksOnceThenInheritsCombinedImageGoal() {
        verifyDeterministicLaunchAndPromote(to: .collection)

        app.typeKey("a", modifierFlags: [.command, .option])
        XCTAssertFalse(
            app.staticTexts["How do you want to use the second image?"]
                .waitForExistence(timeout: 1),
            "A promoted document must not ask for its goal again."
        )
        XCTAssertTrue(
            app.staticTexts["3 items"].waitForExistence(timeout: 10),
            "Later additions should inherit Combine Images."
        )
        assertPurposeInspectorIsolation(for: .collection)
    }

    func testCancelledFirstAdditionLeavesOriginalScreenshotGoal() {
        verifyInitialScreenshotSession()
        invokeUITestCommand("Cancel Next Add Capture for UI Test")

        app.typeKey("a", modifierFlags: [.command, .option])
        XCTAssertTrue(
            app.staticTexts["How do you want to use the second image?"]
                .waitForExistence(timeout: 5)
        )
        let chooser = app.sheets.firstMatch
        XCTAssertTrue(chooser.waitForExistence(timeout: 5))
        clickChooserButton("Combine", in: chooser)

        XCTAssertTrue(
            identified("editor.annotationCanvas").waitForExistence(timeout: 10)
        )
        XCTAssertFalse(canvasItem(named: "UI Test Added 1").exists)
        assertScreenshotInspectorIsolation()
        waitForLabelContaining(
            "Screenshot",
            of: identified("capture.sessionBar"),
            message:
                "Cancelling capture must not commit the pending Combine Images purpose."
        )
    }

    func testFirstAdditionPromotionIsOneUndoableOperation() {
        verifyDeterministicLaunchAndPromote(to: .comparison)

        let undo = app.buttons["Undo"].firstMatch
        revealInContentCommandBar(undo)
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        undo.click()

        XCTAssertTrue(
            identified("editor.annotationCanvas").waitForExistence(timeout: 10),
            "Undo should return directly to the original screenshot editor."
        )
        XCTAssertFalse(canvasItem(named: "UI Test Added 1").exists)
        assertScreenshotInspectorIsolation()
        waitForLabelContaining(
            "Screenshot",
            of: identified("capture.sessionBar"),
            message:
                "The source, purpose, layout, and stage promotion must undo together."
        )
    }

    func testComparisonPurposeShowsOnlyComparisonControls() {
        verifyDeterministicLaunchAndPromote(to: .comparison)
        assertPurposeInspectorIsolation(for: .comparison)
        XCTAssertTrue(identified("composition.compare.result").exists)
        XCTAssertTrue(identified("composition.compare.primary").exists)
        XCTAssertTrue(identified("composition.compare.secondary").exists)

        let advancedAppearance = identified(
            "composition.canvas.advancedAppearance"
        )
        revealInInspector(advancedAppearance)
        advancedAppearance.click()
        let comparisonDivider = identified(
            "composition.canvas.comparisonDividerWidth"
        )
        revealInInspector(comparisonDivider)
        XCTAssertTrue(
            comparisonDivider.exists,
            "Comparison should retain its complete divider appearance controls."
        )
        XCTAssertFalse(
            identified("composition.canvas.stepBadgeFill").exists
        )
        XCTAssertFalse(
            identified("composition.canvas.connectorWidth").exists,
            "Comparison should not leak Steps appearance controls."
        )
    }

    func testStepsPurposeShowsOnlyStepControls() {
        verifyDeterministicLaunchAndPromote(to: .steps)
        assertPurposeInspectorIsolation(for: .steps)
        XCTAssertTrue(identified("composition.steps.flow").exists)
        XCTAssertTrue(identified("composition.steps.numbering").exists)
        XCTAssertTrue(identified("composition.steps.captions").exists)
        XCTAssertTrue(identified("composition.steps.connectors").exists)

        let advancedAppearance = identified(
            "composition.canvas.advancedAppearance"
        )
        revealInInspector(advancedAppearance)
        advancedAppearance.click()
        XCTAssertTrue(
            identified("composition.canvas.stepBadgeFill").exists
        )
        XCTAssertTrue(
            identified("composition.canvas.connectorWidth").exists,
            "Steps should retain number-badge and connector appearance."
        )
        XCTAssertFalse(
            identified("composition.canvas.comparisonDividerWidth").exists,
            "Steps should not leak comparison-only appearance controls."
        )
    }

    func testChangeGoalPreservesEveryCaptureAndFiltersInspector() {
        verifyDeterministicLaunchAndPromote(to: .collection)

        selectChangeGoal("Compare Two Versions")

        XCTAssertTrue(
            identified("composition.comparison")
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(app.staticTexts["2 items"].exists)
        XCTAssertTrue(canvasItem(named: "UI Test Initial").exists)
        XCTAssertTrue(canvasItem(named: "UI Test Added 1").exists)
        assertPurposeInspectorIsolation(for: .comparison)

        selectChangeGoal("Explain with Steps")

        XCTAssertTrue(
            identified("composition.steps").waitForExistence(timeout: 10)
        )
        XCTAssertTrue(app.staticTexts["2 items"].exists)
        assertPurposeInspectorIsolation(for: .steps)
    }

    func testMultiItemGoalMenuGuardsScreenshotDemotion() {
        verifyDeterministicLaunchAndPromote(to: .collection)

        let addedItem = canvasItem(named: "UI Test Added 1")
        addedItem.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).click()

        let changeGoal = identified("composition.changeGoal")
        revealInInspector(changeGoal, scrollingDown: false)
        changeGoal.click()

        XCTAssertFalse(
            app.menuItems["Use as One Screenshot"].exists,
            "A multi-item result cannot silently discard its document goal."
        )
        let openSelected =
            app.menuItems["Open Selected as New Screenshot"].firstMatch
        XCTAssertTrue(
            openSelected.waitForExistence(timeout: 5),
            "Multi-item results should offer the nondestructive alternative."
        )
        XCTAssertTrue(
            openSelected.isEnabled,
            "The explicitly selected capture should be openable separately."
        )
        app.typeKey(.escape, modifierFlags: [])
    }

    func testNewlyAddedItemDoesNotShowSelectionBoundsUntilCanvasFocus() {
        verifyDeterministicLaunchAndPromote(to: .collection)

        let addedItem = canvasItem(named: "UI Test Added 1")
        XCTAssertTrue(addedItem.waitForExistence(timeout: 5))
        waitForValueContaining(
            "Selection bounds hidden",
            of: addedItem,
            message:
                "A newly added item may be logically selected, but its blue selection bounds must stay hidden."
        )

        addedItem.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).click()
        waitForValueContaining(
            "Selection bounds visible",
            of: addedItem,
            message:
                "Selection bounds should appear only after explicit canvas focus."
        )
    }

    func testVisibleStageDrivesEveryRoutineOutput() {
        verifyDeterministicLaunchAndPromote(to: .collection)

        assertRoutineOutputStage(
            "Content preview",
            message:
                "Arrange should route every routine output to the visible unpolished content."
        )
        assertRoutineOutputUsesPlainLanguage()

        let polish = app.buttons["Polish"].firstMatch
        XCTAssertTrue(
            polish.waitForExistence(timeout: 5),
            "The contextual session bar should make optional Polish easy to find."
        )
        polish.click()

        XCTAssertTrue(
            app.buttons["Back to Content"].waitForExistence(timeout: 10)
        )
        let noPolish = identified("polish.none")
        XCTAssertTrue(
            noPolish.waitForExistence(timeout: 5),
            "Polish must begin with an explicit No Polish choice."
        )
        waitForValue(
            "Selected",
            of: noPolish,
            message:
                "Entering Polish on a plain document must not silently apply a treatment."
        )
        let polishType = identified("polish.type")
        XCTAssertTrue(polishType.exists)
        XCTAssertTrue(
            polishType.descendants(matching: .radioButton)["Look"].exists
                || app.buttons["Look"].exists
        )
        XCTAssertTrue(
            polishType.descendants(matching: .radioButton)["Mockup"].exists
                || app.buttons["Mockup"].exists
        )
        XCTAssertFalse(
            app.buttons["Plain"].exists,
            "No Polish is the only off choice; Look must not duplicate it with a Plain tile."
        )
        assertRoutineOutputStage(
            "Polished preview",
            message:
                "Polish should route every routine output to exactly the preview on screen."
        )
        assertRoutineOutputUsesPlainLanguage()

        app.buttons["Back to Content"].click()
        XCTAssertTrue(
            identified("composition.layout").waitForExistence(timeout: 10)
        )
        assertRoutineOutputStage(
            "Content preview",
            message:
                "Leaving Polish must immediately restore content-stage output for every routine action."
        )
    }

    func testScreenshotHasNoRogueTitlebarSeparatorOrBlankToolbarBandAndUsesInlineInspector() {
        verifyInitialScreenshotSession()

        let window = app.windows.firstMatch
        XCTAssertTrue(
            window.waitForExistence(timeout: 10),
            "The deterministic screenshot editor should open its main window."
        )
        XCTAssertEqual(
            window.toolbars.count,
            0,
            "Screenshot editing must not create an empty native toolbar."
        )

        let captureHeader = identified("capture.header")
        XCTAssertTrue(captureHeader.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(
            captureHeader.frame.minY - window.frame.minY,
            48,
            "The capture header should begin directly below the compact titlebar, without a rogue separator or blank toolbar-height band."
        )

        let toggle = identified("editor.inspector.toggle")
        revealInEditCommandBar(toggle)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        waitForBooleanValue(
            true,
            of: toggle,
            message: "The inline Inspector toggle should reflect the visible inspector."
        )

        let inspector = identified("editor.inspector.scroll")
        XCTAssertTrue(inspector.waitForExistence(timeout: 5))
        toggle.click()
        XCTAssertTrue(
            inspector.waitForNonExistence(timeout: 5),
            "The inline control should hide the inspector."
        )
        waitForBooleanValue(
            false,
            of: toggle,
            message: "The inline Inspector toggle should expose its hidden state."
        )

        toggle.click()
        XCTAssertTrue(
            inspector.waitForExistence(timeout: 5),
            "The inline control should restore the inspector."
        )
        waitForBooleanValue(
            true,
            of: toggle,
            message: "The inline Inspector toggle should expose its shown state."
        )

        app.typeKey("i", modifierFlags: [.command, .option])
        XCTAssertTrue(
            inspector.waitForNonExistence(timeout: 5),
            "Command-Option-I should update the same inspector state."
        )
        waitForBooleanValue(
            false,
            of: toggle,
            message: "The command shortcut and inline toggle must share state."
        )
        app.typeKey("i", modifierFlags: [.command, .option])
        XCTAssertTrue(inspector.waitForExistence(timeout: 5))

        promoteScreenshot(to: .collection)
        let contentToggle = identified("editor.inspector.toggle")
        revealInContentCommandBar(contentToggle)
        XCTAssertTrue(
            contentToggle.isHittable,
            "Arrange should retain the same inline Inspector control."
        )
        XCTAssertEqual(
            window.toolbars.count,
            0,
            "Arrange must not recreate a native toolbar, separator, or blank titlebar band."
        )
    }

    func testKeyboardActionsAndFocusRestoration() {
        verifyDeterministicLaunchAndPromote(to: .collection)
        verifyKeyboardActionsAndFocusRestoration()
    }

    func testCancelledAddCaptureLeavesDocumentAndFocusUnchanged() {
        verifyDeterministicLaunchAndPromote(to: .collection)

        let addedItem = canvasItem(named: "UI Test Added 1")
        addedItem.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).click()
        waitForValueContaining(
            "Selected",
            of: addedItem,
            message: "The item should own keyboard focus before capture."
        )

        invokeUITestCommand("Cancel Next Add Capture for UI Test")
        app.typeKey("a", modifierFlags: [.command, .option])

        XCTAssertTrue(
            app.staticTexts["2 items"].waitForExistence(timeout: 5),
            "Cancelling Add Capture must preserve the item count."
        )
        XCTAssertFalse(
            canvasItem(named: "UI Test Added 2").exists,
            "A cancelled capture must not create source content."
        )
        waitForValueContaining(
            "Selected",
            of: canvasItem(named: "UI Test Added 1"),
            message: "Cancellation should preserve composition selection."
        )

        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(
            editingScopeTitle(containing: "Edit Selected Capture")
                .waitForExistence(timeout: 10),
            "Cancellation should restore focus to the composition event layer."
        )
        app.buttons["Done"].firstMatch.click()
    }

    func testStaleAppendDestinationKeepsCaptureInRecentSnips() {
        verifyDeterministicLaunchAndPromote(to: .collection)

        invokeUITestCommand(
            "Make Next Add Capture Stale for UI Test"
        )
        app.typeKey("a", modifierFlags: [.command, .option])

        let staleMessage =
            "The composition changed before capture finished. "
                + "The capture was kept in Recent Snips."
        let staleNotice = identified("editor.notice")
        XCTAssertTrue(
            staleNotice.waitForExistence(timeout: 10),
            "A stale capture should present an accessible explanation."
        )
        XCTAssertEqual(staleNotice.label, staleMessage)
        XCTAssertTrue(
            app.staticTexts["2 items"].waitForExistence(timeout: 10),
            "A stale destination must not mutate the active composition."
        )
        XCTAssertFalse(
            canvasItem(named: "UI Test Added 2").exists,
            "The stale result must remain unattached."
        )
    }

    func testPrivateReplaceAndUndoPreservePermanentTaint() {
        verifyDeterministicLaunchAndPromote(to: .collection)
        verifyPrivateReplaceAndUndo()
    }

    func testAppearanceThemeAndAdvancedControls() {
        verifyDeterministicLaunchAndPromote(to: .collection)

        let gridLayout = identified("composition.layout.grid")
        revealInInspector(gridLayout)
        gridLayout.click()
        waitForValue(
            "Selected",
            of: gridLayout,
            message: "Grid should become active before testing weighted sections."
        )

        let sectionSizing = identified(
            "composition.canvas.sectionSizing"
        )
        revealInInspector(sectionSizing)
        let weightedSegment = sectionSizing
            .descendants(matching: .radioButton)["Weighted"]
        XCTAssertTrue(
            weightedSegment.waitForExistence(timeout: 5),
            "Structured layouts should expose equal and weighted sizing."
        )
        weightedSegment.click()

        let sectionWeight = identified("composition.selected.weight")
        revealInInspector(sectionWeight)
        XCTAssertTrue(
            sectionWeight.exists,
            "Grid divider weights need an inspector, keyboard, and VoiceOver equivalent."
        )

        let theme = identified("composition.canvas.theme")
        revealInInspector(theme, scrollingDown: false)
        theme.click()
        XCTAssertTrue(app.menuItems["Dark"].waitForExistence(timeout: 5))
        app.menuItems["Dark"].click()

        let advanced = identified(
            "composition.canvas.advancedAppearance"
        )
        revealInInspector(advanced)
        advanced.click()
        let panelFill = identified(
            "composition.canvas.itemFill"
        )
        XCTAssertTrue(
            panelFill.waitForExistence(timeout: 5),
            "Advanced Appearance should expand from its accessible disclosure control."
        )
        XCTAssertFalse(
            identified("composition.canvas.comparisonDividerWidth").exists,
            "Combine Images should not expose comparison-only divider controls."
        )
        XCTAssertFalse(
            identified("composition.canvas.stepBadgeFill").exists
        )
        XCTAssertFalse(
            identified("composition.canvas.connectorWidth").exists,
            "Combine Images should not expose Steps-only appearance controls."
        )
    }

    func testBlinkComparisonExport() throws {
        verifyDeterministicLaunchAndPromote(to: .comparison)
        try verifyBlinkComparisonExport()
    }

    func testAllComparisonModesAndPosterOutput() throws {
        verifyDeterministicLaunchAndPromote(to: .comparison)
        openComparisonMoreOptions()

        let modes: [(String, String?)] = [
            ("Side by Side", nil),
            ("Overlay", "composition.compare.opacity"),
            ("Wipe", "composition.compare.wipePosition"),
            ("Difference", "composition.compare.differenceCues"),
            ("Change Highlight", "composition.compare.differenceCues"),
            ("Blink", "composition.compare.posterFrame"),
        ]
        for (index, entry) in modes.enumerated() {
            let (mode, conditionalControlIdentifier) = entry
            let modePicker = identified(
                "composition.compare.mode"
            )
            revealInInspector(
                modePicker,
                scrollingDown: index == 0
            )
            selectComparisonMode(mode, using: modePicker)
            if let conditionalControlIdentifier {
                let control = identified(conditionalControlIdentifier)
                XCTAssertTrue(
                    control.waitForExistence(timeout: 5),
                    "\(mode) should expose its dedicated accessible controls."
                )
            }
        }

        let posterFrame = identified("composition.compare.posterFrame")
        revealInInspector(posterFrame)
        let beforePoster = posterFrame
            .descendants(matching: .radioButton)["A / Before"]
        XCTAssertTrue(
            beforePoster.waitForExistence(timeout: 5),
            "Static poster selection should expose Before and After."
        )
        beforePoster.click()

        verifyCompositionOutputMenu(
            expectedItems: [
                "PNG…",
                "Animated GIF…",
                "Animated APNG…",
                "Blink MP4…",
                "Interactive HTML…",
            ]
        )

        invokeUITestCommand(
            "Export Comparison Poster for UI Test"
        )
        let posterMarkerURL = artifactURL(
            "comparison-poster.complete"
        )
        waitForFile(at: posterMarkerURL, timeout: 45)
        let posterMarker = try String(
            contentsOf: posterMarkerURL,
            encoding: .utf8
        )
        XCTAssertTrue(
            posterMarker.contains("poster=primary"),
            "The PNG exporter should use the poster chosen in Review Comparison."
        )
        let posterData = try Data(
            contentsOf: artifactURL("comparison-poster.png")
        )
        XCTAssertTrue(
            posterData.starts(with: [
                0x89, 0x50, 0x4E, 0x47,
                0x0D, 0x0A, 0x1A, 0x0A,
            ]),
            "The static comparison poster should be an encoded PNG."
        )

        invokeUITestCommand(
            "Export Blink Comparison for UI Test"
        )
        let animationMarkerURL = artifactURL(
            "comparison-blink.complete"
        )
        waitForFile(at: animationMarkerURL, timeout: 45)
        let animation = try Data(
            contentsOf: artifactURL("comparison-blink.gif")
        )
        XCTAssertTrue(
            String(
                data: animation.prefix(6),
                encoding: .ascii
            )?.hasPrefix("GIF8") == true,
            "The animated comparison should be an encoded GIF."
        )
    }

    func testStepsPaginationAndInteractiveHTMLExport() throws {
        verifyDeterministicLaunchAndPromote(to: .steps)

        XCTAssertTrue(
            identified("composition.steps.flow")
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(identified("composition.steps.numbering").exists)
        XCTAssertTrue(identified("composition.steps.captions").exists)
        XCTAssertTrue(identified("composition.steps.connectors").exists)

        let pagination = identified("composition.steps.pagination")
        revealInInspector(pagination)
        pagination.click()
        let itemsPerPage = identified(
            "composition.steps.itemsPerPage"
        )
        revealInInspector(itemsPerPage)
        XCTAssertTrue(
            itemsPerPage.exists,
            "Paginated Steps should expose the steps-per-page control."
        )

        verifyCompositionOutputMenu(
            expectedItems: [
                "PDF…",
                "Interactive HTML…",
            ]
        )
        invokeUITestCommand("Export Steps Outputs for UI Test")

        let markerURL = artifactURL("steps-export.complete")
        waitForFile(at: markerURL, timeout: 45)
        let marker = try String(
            contentsOf: markerURL,
            encoding: .utf8
        )
        XCTAssertTrue(
            marker.contains("pdfPages=2"),
            "Two items at one step per page should create two PDF pages."
        )

        let pdf = try Data(
            contentsOf: artifactURL("steps-paginated.pdf")
        )
        XCTAssertTrue(
            String(data: pdf.prefix(5), encoding: .ascii)
                == "%PDF-"
        )
        let html = try String(
            contentsOf: artifactURL("steps-interactive.html"),
            encoding: .utf8
        )
        XCTAssertTrue(html.contains("data-step-layout"))
        XCTAssertTrue(html.contains("data-step-count=\"2\""))
        XCTAssertTrue(
            html.contains("Content-Security-Policy"),
            "Interactive Steps HTML must retain the offline CSP."
        )
    }

    func testDropRoutingAddsHereAndReplacesItem() throws {
        verifyDeterministicLaunchAndPromote(to: .collection)

        invokeUITestCommand(
            "Simulate Add-Here Drop for UI Test"
        )
        waitForFile(
            at: artifactURL("drop-add.complete"),
            timeout: 10
        )
        XCTAssertTrue(
            app.staticTexts["3 items"].waitForExistence(timeout: 10)
        )
        let addition = canvasItem(
            named: "UI Test Dropped Addition 2"
        )
        XCTAssertTrue(
            addition.waitForExistence(timeout: 10),
            "Dropping between items should insert the image as a new item."
        )

        addition.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).click()
        invokeUITestCommand(
            "Simulate Replace-Item Drop for UI Test"
        )
        waitForFile(
            at: artifactURL("drop-replace.complete"),
            timeout: 10
        )
        XCTAssertTrue(
            app.staticTexts["3 items"].waitForExistence(timeout: 10),
            "Dropping over an item should replace without changing count."
        )
        XCTAssertFalse(addition.exists)
        XCTAssertTrue(
            canvasItem(named: "UI Test Dropped Replacement 3")
                .waitForExistence(timeout: 10),
            "Replace Item should retain the panel and install the new source."
        )
    }

    func testEditableSaveAndReopen() throws {
        verifyDeterministicLaunchAndPromote(to: .comparison)
        verifyPrivateReplaceAndUndo()
        try verifyEditableSaveAndReopen()
    }

    private func verifyInitialScreenshotSession() {
        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: 10),
            "The UI-test launch mode should present the real main window."
        )
        XCTAssertTrue(
            identified("editor.annotationCanvas")
                .waitForExistence(timeout: 5),
            "The deterministic initial screenshot should be visible."
        )
        let sessionBar = identified("capture.sessionBar")
        XCTAssertTrue(
            sessionBar.waitForExistence(timeout: 10),
            "An open screenshot should replace global capture chrome with a contextual session bar."
        )
        waitForLabelContaining(
            "Screenshot",
            of: sessionBar,
            message: "The session bar must identify Screenshot · Editing."
        )
        let primaryAction = identified("capture.session.primary")
        XCTAssertTrue(primaryAction.waitForExistence(timeout: 5))
        XCTAssertEqual(
            primaryAction.label,
            "Add…",
            "Screenshot editing should lead with the single low-friction Add action."
        )
        assertDiscardAvailableInCurrentDocumentStage()
        assertScreenshotInspectorIsolation()
        assertRoutineOutputUsesPlainLanguage()
    }

    private func verifyDeterministicLaunchAndPromote(
        to goal: IntentGoal
    ) {
        XCTContext.runActivity(
            named:
                "Launch and choose \(goal.chooserTitle) for the first added image"
        ) { _ in
            verifyInitialScreenshotSession()
            promoteScreenshot(to: goal)

            XCTAssertTrue(
                app.staticTexts["2 items"].waitForExistence(timeout: 5),
                "The composition should contain both deterministic captures."
            )
            XCTAssertTrue(
                canvasItem(named: "UI Test Added 1")
                    .waitForExistence(timeout: 10),
                "The added capture should be represented on the canvas."
            )
            assertPurposeInspectorIsolation(for: goal)
            assertRoutineOutputUsesPlainLanguage()
            assertDiscardAvailableInCurrentDocumentStage()
            XCTAssertEqual(
                app.staticTexts.matching(
                    NSPredicate(format: "label CONTAINS[c] %@", "Presentation")
                ).count,
                0,
                "Presentation must disappear from the primary user-facing workflow."
            )
            XCTAssertFalse(
                identified("presentation.canvas.workspace.layout").exists,
                "The canvas must not repeat a redundant mode badge."
            )

            if goal == .collection {
                let autoLayout = identified("composition.layout.auto")
                XCTAssertTrue(
                    autoLayout.waitForExistence(timeout: 10),
                    "Combine Images should enter Arrange with Auto selected."
                )
                waitForValue(
                    "Selected",
                    of: autoLayout,
                    message: "The first Combined Image arrangement must be Auto."
                )
            }

            let canvas = identified("composition.canvas")
            let addedItem = canvasItem(named: "UI Test Added 1")
            XCTAssertTrue(canvas.waitForExistence(timeout: 5))
            XCTAssertTrue(
                canvas.frame.contains(addedItem.frame),
                "The selected-item accessibility frame must stay inside the composition canvas."
            )
        }
    }

    private func assertDiscardAvailableInCurrentDocumentStage(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let discard = identified("editor.discard")
        XCTAssertTrue(
            discard.waitForExistence(timeout: 5),
            "Every screenshot-document stage should expose Discard.",
            file: file,
            line: line
        )
        XCTAssertEqual(discard.label, "Discard", file: file, line: line)
    }

    private func promoteScreenshot(to goal: IntentGoal) {
        XCTAssertTrue(
            identified("capture.session.primary").waitForExistence(timeout: 10),
            "The seeded screenshot session should expose Add…."
        )
        app.typeKey("a", modifierFlags: [.command, .option])

        XCTAssertTrue(
            app.staticTexts["How do you want to use the second image?"]
                .waitForExistence(timeout: 5),
            "The first extra image should ask for intent exactly once."
        )
        let chooser = app.sheets.firstMatch
        XCTAssertTrue(
            chooser.waitForExistence(timeout: 5),
            "The first-add choices should remain scoped to one compact chooser."
        )
        for title in [
            "Compare",
            "Add as Step",
            "Combine",
        ] {
            XCTAssertTrue(
                chooser.buttons[title].exists,
                "The first-add chooser should offer \(title)."
            )
        }
        XCTAssertGreaterThanOrEqual(
            chooser.frame.width,
            520,
            "The first-add chooser should be wide enough to explain every choice."
        )
        XCTAssertGreaterThanOrEqual(
            chooser.frame.height,
            400,
            "The first-add chooser should be tall enough to keep every explanation readable."
        )
        clickChooserButton(goal.chooserTitle, in: chooser)

        XCTAssertTrue(
            identified(goal.inspectorIdentifier)
                .waitForExistence(timeout: 10),
            "The chosen goal should open its focused content stage."
        )
        waitForLabelContaining(
            goal.sessionValueFragment,
            of: identified("capture.sessionBar"),
            message: "The contextual session bar should name the chosen goal."
        )
        let primaryAction = identified("capture.session.primary")
        XCTAssertTrue(
            primaryAction.waitForExistence(timeout: 5),
            "Each goal should expose one obvious next action."
        )
        XCTAssertEqual(
            primaryAction.label,
            goal.primarySessionAction,
            "The session bar should lead with the goal’s next useful action."
        )
    }

    private func verifyEveryLayoutAndCompositionEditing() {
        XCTContext.runActivity(
            named: "Every Combine Images arrangement applies live"
        ) { _ in
            let modes = [
                "auto",
                "row",
                "column",
                "grid",
                "freeform",
            ]
            for mode in modes {
                let tile = identified("composition.layout.\(mode)")
                revealInInspector(tile)
                tile.click()
                waitForValue(
                    "Selected",
                    of: tile,
                    message: "\(mode) should become the active layout."
                )
                XCTAssertTrue(
                    app.staticTexts["2 items"].exists,
                    "Changing layout must preserve every source item."
                )
            }
            assertPurposeInspectorIsolation(for: .collection)
        }

        XCTContext.runActivity(
            named: "Annotate Result has an explicit Done round trip"
        ) { _ in
            let annotateResult = identified(
                "composition.editComposition"
            )
            revealInInspector(annotateResult, scrollingDown: false)
            XCTAssertTrue(
                annotateResult.waitForExistence(timeout: 5),
                "Arrange should expose the explicit Annotate Result action."
            )
            XCTAssertEqual(annotateResult.label, "Annotate Result")
            annotateResult.click()

            XCTAssertTrue(
                editingScopeTitle(containing: "Annotate Result")
                    .waitForExistence(timeout: 10),
                "The whole-composition editing scope should be visible."
            )
            XCTAssertTrue(
                app.buttons["Done"].firstMatch
                    .waitForExistence(timeout: 5)
            )
            app.buttons["Done"].firstMatch.click()

            XCTAssertTrue(
                identified("composition.layout")
                    .waitForExistence(timeout: 10),
                "Done should return to Arrange without changing layout."
            )

            let annotateFromCanvas = identified("editor.backToEdit")
            XCTAssertTrue(annotateFromCanvas.waitForExistence(timeout: 5))
            XCTAssertEqual(annotateFromCanvas.label, "Annotate Result")
            annotateFromCanvas.click()
            XCTAssertTrue(
                editingScopeTitle(containing: "Annotate Result")
                    .waitForExistence(timeout: 10),
                "Annotate Result should enter the explicit composed-content editor."
            )
            XCTAssertFalse(
                identified("editor.output.export.current").exists,
                "Scoped composition editing must not export pixels different from the visible editing canvas."
            )
            assertDocumentOutputMenusHaveEnabledState(false)
            app.buttons["Done"].firstMatch.click()
            XCTAssertTrue(
                identified("composition.layout")
                    .waitForExistence(timeout: 10)
            )
            assertDocumentOutputMenusHaveEnabledState(true)
        }
    }

    private func clickChooserButton(
        _ title: String,
        in chooser: XCUIElement
    ) {
        let button = chooser.buttons[title]
        XCTAssertTrue(
            button.waitForExistence(timeout: 5),
            "The first-add chooser should expose \(title)."
        )

        for _ in 0..<3 {
            app.activate()
            let hittable = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "hittable == true"),
                object: button
            )
            if XCTWaiter.wait(for: [hittable], timeout: 2) == .completed {
                button.click()
                return
            }
        }

        XCTFail(
            "The first-add chooser should be active before selecting \(title)."
        )
    }

    private func assertScreenshotInspectorIsolation(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            identified("composition.layout").exists,
            "Screenshot must not expose Combine Images arrangements.",
            file: file,
            line: line
        )
        XCTAssertFalse(
            identified("composition.comparison").exists,
            "Screenshot must not expose Comparison controls.",
            file: file,
            line: line
        )
        XCTAssertFalse(
            identified("composition.steps").exists,
            "Screenshot must not expose Steps controls.",
            file: file,
            line: line
        )
        XCTAssertFalse(
            identified("composition.layout.auto").exists,
            "Screenshot must remain a focused one-image editor.",
            file: file,
            line: line
        )
    }

    private func assertPurposeInspectorIsolation(
        for goal: IntentGoal,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            identified(goal.inspectorIdentifier)
                .waitForExistence(timeout: 5),
            "The selected purpose should expose its focused inspector.",
            file: file,
            line: line
        )

        let unrelatedIdentifiers = [
            "composition.comparison",
            "composition.steps",
            "composition.layout",
        ].filter { $0 != goal.inspectorIdentifier }
        for identifier in unrelatedIdentifiers {
            XCTAssertFalse(
                identified(identifier).exists,
                "\(goal.sessionValueFragment) must not expose unrelated purpose controls.",
                file: file,
                line: line
            )
        }

        switch goal {
        case .comparison:
            XCTAssertFalse(
                identified("composition.layout.grid").exists,
                "Comparison must not expose Grid.",
                file: file,
                line: line
            )
            XCTAssertFalse(
                identified("composition.steps.flow").exists,
                "Comparison must not expose Steps.",
                file: file,
                line: line
            )
        case .steps:
            XCTAssertFalse(
                identified("composition.compare.result").exists,
                "Steps must not expose comparison choices.",
                file: file,
                line: line
            )
            XCTAssertFalse(
                identified("composition.layout.grid").exists,
                "Steps must not expose general arrangements.",
                file: file,
                line: line
            )
        case .collection:
            XCTAssertFalse(
                identified("composition.compare.result").exists,
                "Combine Images must not expose comparison controls.",
                file: file,
                line: line
            )
            XCTAssertFalse(
                identified("composition.steps.flow").exists,
                "Combine Images must not expose Steps controls.",
                file: file,
                line: line
            )
        }

        for identifier in [
            "editor.output.copy.current",
            "editor.output.export.current",
            "editor.output.share.current",
            "editor.output.float.current",
            "editor.output.drag.current",
        ] {
            let control = identified(identifier)
            guard control.exists else {
                continue
            }
            let accessibilityValue = String(
                describing: control.value ?? ""
            )
            XCTAssertFalse(
                accessibilityValue.localizedCaseInsensitiveContains("plain")
                    || accessibilityValue.localizedCaseInsensitiveContains(
                        "styled"
                    ),
                "VoiceOver must use visible-stage language, not Plain/Styled.",
                file: file,
                line: line
            )
        }
    }

    private func assertRoutineOutputUsesPlainLanguage(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for title in [
            "Copy Plain",
            "Copy Styled",
            "Export Plain",
            "Export Styled",
            "Share Plain",
            "Share Styled",
            "Float Plain",
            "Float Styled",
            "Drag Plain",
            "Drag Styled",
        ] {
            XCTAssertFalse(
                app.buttons[title].exists || app.staticTexts[title].exists,
                "Routine UI must use stage-based output, not \(title).",
                file: file,
                line: line
            )
        }
    }

    private func assertRoutineOutputStage(
        _ expectedValue: String,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for identifier in [
            "editor.output.copy.current",
            "editor.output.export.current",
            "editor.output.share.current",
            "editor.output.float.current",
            "editor.output.drag.current",
        ] {
            let control = identified(identifier)
            revealInContentCommandBar(
                control,
                file: file,
                line: line
            )
            waitForValue(
                expectedValue,
                of: control,
                message: "\(message) Failed control: \(identifier)."
            )
        }
    }

    private func openComparisonMoreOptions(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let mode = identified("composition.compare.mode")
        if mode.exists {
            return
        }
        let moreOptions = identified("composition.compare.moreOptions")
        revealInInspector(
            moreOptions,
            file: file,
            line: line
        )
        XCTAssertTrue(
            moreOptions.waitForExistence(timeout: 5),
            "Comparison should keep advanced methods under More Options.",
            file: file,
            line: line
        )
        moreOptions.click()
        revealInInspector(mode)
        XCTAssertTrue(
            mode.waitForExistence(timeout: 5),
            "More Options should reveal Overlay, Wipe, Difference, and Blink.",
            file: file,
            line: line
        )
    }

    private func assertDocumentOutputMenusHaveEnabledState(
        _ expectedIsEnabled: Bool
    ) {
        let fileMenu = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 5))
        fileMenu.click()
        let export = app.menuItems["Export"].firstMatch
        let share = app.menuItems["Share"].firstMatch
        XCTAssertTrue(export.waitForExistence(timeout: 3))
        XCTAssertTrue(share.waitForExistence(timeout: 3))
        XCTAssertEqual(export.isEnabled, expectedIsEnabled)
        XCTAssertEqual(share.isEnabled, expectedIsEnabled)
        app.typeKey(.escape, modifierFlags: [])

        let editMenu = app.menuBars.menuBarItems["Edit"]
        XCTAssertTrue(editMenu.waitForExistence(timeout: 5))
        editMenu.click()
        let copy = app.menuItems["Copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 3))
        XCTAssertEqual(copy.isEnabled, expectedIsEnabled)
        app.typeKey(.escape, modifierFlags: [])

        let referenceMenu = app.menuBars.menuBarItems["Reference"]
        XCTAssertTrue(referenceMenu.waitForExistence(timeout: 5))
        referenceMenu.click()
        let float = app.menuItems["Float Current Screenshot"].firstMatch
        XCTAssertTrue(float.waitForExistence(timeout: 3))
        XCTAssertEqual(float.isEnabled, expectedIsEnabled)
        app.typeKey(.escape, modifierFlags: [])
    }

    private func verifyKeyboardActionsAndFocusRestoration() {
        XCTContext.runActivity(
            named: "Keyboard actions and Edit Selected Capture focus restoration"
        ) { _ in
            let rowLayout = identified("composition.layout.row")
            revealInInspector(rowLayout)
            rowLayout.click()
            waitForValue(
                "Selected",
                of: rowLayout,
                message: "Row should be active for the keyboard smoke."
            )

            let addedItem = canvasItem(named: "UI Test Added 1")
            XCTAssertTrue(addedItem.waitForExistence(timeout: 10))

            let editSelected = identified("composition.selected.edit")
            revealInInspector(editSelected)
            XCTAssertEqual(
                editSelected.label,
                "Edit Selected Capture",
                "The item scope should use plain source-oriented terminology."
            )

            // A pointer selects the canvas event layer once; composition
            // manipulation and both editing entries below are keyboard-only.
            addedItem.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            ).click()
            waitForValueContaining(
                "Selected",
                of: addedItem,
                message: "The accessible canvas item should become selected."
            )

            app.typeKey("d", modifierFlags: [.command])
            XCTAssertTrue(
                app.staticTexts["3 items"].waitForExistence(timeout: 5),
                "Command-D should duplicate the selected item."
            )
            let undo = app.buttons["Undo"].firstMatch
            XCTAssertTrue(undo.waitForExistence(timeout: 5))
            undo.click()
            XCTAssertTrue(
                app.staticTexts["2 items"].waitForExistence(timeout: 5),
                "Undo should restore the two-item composition."
            )

            // Re-select after undo because the restored snapshot owns the
            // canonical selection, then enter editing solely with Return.
            let restoredAddedItem = canvasItem(
                named: "UI Test Added 1"
            )
            restoredAddedItem.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            ).click()
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(
                editingScopeTitle(containing: "Edit Selected Capture")
                    .waitForExistence(timeout: 10),
                "Return should enter Edit Selected Capture."
            )

            app.buttons["Done"].firstMatch.click()
            XCTAssertTrue(
                identified("composition.canvas")
                    .waitForExistence(timeout: 10),
                "Done should return to the scroll-independent content canvas."
            )
            waitForValueContaining(
                "Selected",
                of: canvasItem(named: "UI Test Added 1"),
                message: "Done should retain the selected item."
            )

            // No intervening pointer action: this verifies that leaving Edit
            // Item restored focus to the composition event layer.
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(
                editingScopeTitle(containing: "Edit Selected Capture")
                    .waitForExistence(timeout: 10),
                "Restored focus should make Return re-enter Edit Selected Capture."
            )
            app.buttons["Done"].firstMatch.click()

            let layoutItem = canvasItem(
                named: "UI Test Added 1"
            )
            layoutItem.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            ).click()
            app.typeKey(.return, modifierFlags: [.option])
            waitForValueContaining(
                "framing",
                of: layoutItem,
                message: "Option-Return should enter explicit item framing."
            )
            app.typeKey(.escape, modifierFlags: [])
            waitForValueNotContaining(
                "framing",
                of: layoutItem,
                message: "Escape should finish explicit item framing."
            )

            app.typeKey(.leftArrow, modifierFlags: [])
            waitForValueContaining(
                "item 1 of 2",
                of: canvasItem(named: "UI Test Added 1"),
                message: "Arrow keys should reorder structured items."
            )

            app.typeKey(.delete, modifierFlags: [])
            XCTAssertTrue(
                app.staticTexts["1 item"].waitForExistence(timeout: 5),
                "Delete should remove the selected item."
            )
            app.typeKey(.delete, modifierFlags: [])
            app.typeKey("d", modifierFlags: [.command])
            XCTAssertTrue(
                app.staticTexts["2 items"].waitForExistence(timeout: 5),
                "The protected final item should remain selected and duplicable."
            )
        }
    }

    private func verifyPrivateReplaceAndUndo() {
        XCTContext.runActivity(
            named: "Private Replace is atomic and undo preserves taint"
        ) { _ in
            invokeUITestCommand(
                "Enable Private Capture for UI Test"
            )

            let addedItem = canvasItem(named: "UI Test Added 1")
            XCTAssertTrue(addedItem.waitForExistence(timeout: 10))
            addedItem.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            ).click()

            let replace = identified("composition.selected.replace")
            revealInInspector(replace)
            replace.click()

            XCTAssertTrue(
                canvasItem(named: "UI Test Added 2")
                    .waitForExistence(timeout: 10),
                "Replace should retain the item while swapping its source."
            )
            let privateStatus = privateCompositionStatus
            revealInInspector(
                privateStatus,
                scrollingDown: false
            )
            XCTAssertTrue(
                privateStatus.exists,
                "A private replacement should permanently taint the document."
            )

            let undo = app.buttons["Undo"].firstMatch
            XCTAssertTrue(undo.waitForExistence(timeout: 5))
            undo.click()
            XCTAssertTrue(
                canvasItem(named: "UI Test Added 1")
                    .waitForExistence(timeout: 10),
                "Undo should restore the replaced source."
            )
            XCTAssertTrue(
                privateStatus.exists,
                "Undoing replacement must not clear permanent privacy taint."
            )
            XCTAssertTrue(
                app.staticTexts["2 items"].exists,
                "Replace and undo must not change item count."
            )
        }
    }

    private func verifyBlinkComparisonExport() throws {
        try XCTContext.runActivity(
            named: "Blink comparison exports through the real renderer"
        ) { _ in
            openComparisonMoreOptions()

            let comparisonMode = identified("composition.compare.mode")
            revealInInspector(comparisonMode)
            selectComparisonMode("Blink", using: comparisonMode)

            let posterFrame = identified(
                "composition.compare.posterFrame"
            )
            revealInInspector(posterFrame)
            XCTAssertTrue(posterFrame.isHittable)
            XCTAssertTrue(
                identified("composition.compare.blinkInterval").exists
            )
            XCTAssertTrue(
                identified("composition.compare.blinkLoops").exists
            )

            let exportControl = identified(
                "editor.output.export.current"
            )
            revealInContentCommandBar(exportControl)
            exportControl.click()
            XCTAssertTrue(
                app.menuItems["Animated GIF…"]
                    .waitForExistence(timeout: 5)
            )
            XCTAssertFalse(app.menuItems["Styled"].exists)
            app.typeKey(.escape, modifierFlags: [])

            invokeUITestCommand(
                "Export Blink Comparison for UI Test"
            )
            let markerURL = artifactURL(
                "comparison-blink.complete"
            )
            waitForFile(at: markerURL, timeout: 45)

            let outputURL = artifactURL("comparison-blink.gif")
            XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
            let data = try Data(contentsOf: outputURL)
            XCTAssertGreaterThan(data.count, 128)
            XCTAssertTrue(
                String(
                    data: data.prefix(6),
                    encoding: .ascii
                )?.hasPrefix("GIF8") == true,
                "The comparison output should be an encoded GIF."
            )
        }
    }

    private func verifyEditableSaveAndReopen() throws {
        try XCTContext.runActivity(
            named: "Editable v7 save and reopen preserves composition state"
        ) { _ in
            invokeUITestCommand(
                "Save and Reopen Composition for UI Test"
            )
            let markerURL = artifactURL(
                "composition-round-trip.complete"
            )
            waitForFile(at: markerURL, timeout: 45)

            let packageURL = artifactURL(
                "composition-round-trip.sss"
            )
            var isDirectory: ObjCBool = false
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: packageURL.path,
                    isDirectory: &isDirectory
                )
            )
            XCTAssertTrue(
                isDirectory.boolValue,
                "An editable .sss must be a package, not a flattened image."
            )

            let marker = try String(
                contentsOf: markerURL,
                encoding: .utf8
            )
            XCTAssertTrue(marker.contains("items=2"))
            XCTAssertTrue(marker.contains("layout=compare"))
            XCTAssertTrue(marker.contains("private=true"))

            XCTAssertTrue(
                app.staticTexts["2 items"].waitForExistence(timeout: 10)
            )
            XCTAssertTrue(
                identified("composition.comparison")
                    .waitForExistence(timeout: 10),
                "Reopen should restore the Comparison purpose and focused review controls."
            )
            assertPurposeInspectorIsolation(for: .comparison)
            let privateStatus = privateCompositionStatus
            revealInInspector(
                privateStatus,
                scrollingDown: false
            )
            XCTAssertTrue(
                privateStatus.exists,
                "Reopen should preserve permanent privacy status."
            )
            XCTAssertTrue(
                canvasItem(named: "UI Test Initial").exists
            )
            XCTAssertTrue(
                canvasItem(named: "UI Test Added 1").exists
            )
        }
    }

    private var privateCompositionStatus: XCUIElement {
        identified("composition.privateStatus")
    }

    private func identified(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    private func canvasItem(named name: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@ AND label == %@",
                    "composition.canvas.item.",
                    name
                )
            )
            .firstMatch
    }

    private func editingScopeTitle(
        containing title: String
    ) -> XCUIElement {
        app.staticTexts
            .matching(
                NSPredicate(
                    format: "label CONTAINS %@ OR value CONTAINS %@",
                    title,
                    title
                )
            )
            .firstMatch
    }

    private func revealInInspector(
        _ element: XCUIElement,
        scrollingDown: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        app.activate()
        let inspector = identified("editor.inspector.scroll")
        XCTAssertTrue(
            inspector.waitForExistence(timeout: 5),
            "The editor inspector scroll view should be available.",
            file: file,
            line: line
        )

        for direction in [scrollingDown, !scrollingDown] {
            for _ in 0..<14 {
                if app.state != .runningForeground {
                    app.activate()
                    XCTAssertTrue(
                        inspector.waitForExistence(timeout: 5),
                        "The editor inspector should survive foreground restoration.",
                        file: file,
                        line: line
                    )
                }
                guard !isCenteredInInspectorViewport(
                    element,
                    inspector: inspector
                ) else {
                    return
                }
                inspector.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
                ).scroll(
                    byDeltaX: 0,
                    deltaY: direction ? -360 : 360
                )
            }
        }
        XCTAssertTrue(
            isCenteredInInspectorViewport(
                element,
                inspector: inspector
            ),
            "The requested inspector control center should become visible inside the inset inspector viewport.",
            file: file,
            line: line
        )
    }

    private func isCenteredInInspectorViewport(
        _ element: XCUIElement,
        inspector: XCUIElement
    ) -> Bool {
        guard element.exists, element.isHittable else {
            return false
        }

        let inspectorFrame = inspector.frame
        let elementFrame = element.frame
        guard !inspectorFrame.isEmpty,
              !inspectorFrame.isNull,
              !inspectorFrame.isInfinite,
              !elementFrame.isEmpty,
              !elementFrame.isNull,
              !elementFrame.isInfinite else {
            return false
        }

        let viewport = inspectorFrame.insetBy(dx: 8, dy: 16)
        let center = CGPoint(
            x: elementFrame.midX,
            y: elementFrame.midY
        )
        return viewport.contains(center)
    }

    private func selectChangeGoal(
        _ menuItemTitle: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for _ in 0..<3 {
            if app.menuItems[menuItemTitle].firstMatch.exists {
                app.typeKey(.escape, modifierFlags: [])
                _ = app.menuItems[menuItemTitle].firstMatch
                    .waitForNonExistence(timeout: 1)
            }

            // Activating while a cached menu remains open can leave XCTest
            // targeting its stale accessibility tree. Retry dismissal first.
            guard !app.menuItems[menuItemTitle].firstMatch.exists else {
                continue
            }

            app.activate()

            // Reacquire both elements on every attempt. SwiftUI replaces the
            // goal button when the focused inspector changes.
            let changeGoal = identified("composition.changeGoal")
            revealInInspector(
                changeGoal,
                scrollingDown: false,
                file: file,
                line: line
            )
            guard changeGoal.waitForExistence(timeout: 2),
                  changeGoal.isHittable else {
                continue
            }
            changeGoal.click()

            let menuItem = app.menuItems[menuItemTitle].firstMatch
            guard menuItem.waitForExistence(timeout: 2),
                  menuItem.isEnabled,
                  menuItem.isHittable else {
                app.typeKey(.escape, modifierFlags: [])
                _ = app.menuItems[menuItemTitle].firstMatch
                    .waitForNonExistence(timeout: 1)
                continue
            }

            menuItem.click()
            return
        }

        XCTFail(
            "Change Goal should expose the \(menuItemTitle) menu item.",
            file: file,
            line: line
        )
    }

    private func revealInContentCommandBar(
        _ element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let commandBar = identified(
            "editor.commandBar.presentation.scroll"
        )
        XCTAssertTrue(
            commandBar.waitForExistence(timeout: 5),
            "The active content-stage command bar should be available.",
            file: file,
            line: line
        )

        let horizontalDeltas: [CGFloat] = [-360, 360]
        for deltaX in horizontalDeltas {
            for _ in 0..<14 {
                guard !element.isHittable else {
                    return
                }
                commandBar.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
                ).scroll(
                    byDeltaX: deltaX,
                    deltaY: 0
                )
            }
        }
        XCTAssertTrue(
            element.isHittable,
            "The requested content-stage command should become visible.",
            file: file,
            line: line
        )
    }

    private func revealInEditCommandBar(
        _ element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let commandBar = identified(
            "editor.commandBar.edit.secondary.scroll"
        )
        XCTAssertTrue(
            commandBar.waitForExistence(timeout: 5),
            "The Edit command bar should be available.",
            file: file,
            line: line
        )

        for deltaX in [CGFloat(-360), CGFloat(360)] {
            for _ in 0..<14 {
                guard !element.isHittable else {
                    return
                }
                commandBar.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
                ).scroll(
                    byDeltaX: deltaX,
                    deltaY: 0
                )
            }
        }
        XCTAssertTrue(
            element.isHittable,
            "The requested Edit command should become visible.",
            file: file,
            line: line
        )
    }

    private func invokeUITestCommand(
        _ title: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let menu = app.menuBars.menuBarItems["UI Testing"]
        XCTAssertTrue(
            menu.waitForExistence(timeout: 5),
            "The Debug-only UI Testing menu should be installed.",
            file: file,
            line: line
        )
        menu.click()

        let command = app.menuItems[title]
        XCTAssertTrue(
            command.waitForExistence(timeout: 5),
            "The requested UI Testing command should be present.",
            file: file,
            line: line
        )
        XCTAssertTrue(
            command.isEnabled,
            "The requested UI Testing command should be enabled.",
            file: file,
            line: line
        )
        command.click()
    }

    private func artifactURL(_ name: String) -> URL {
        artifactDirectory.appendingPathComponent(name)
    }

    private func waitForFile(
        at url: URL,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: url.path)
            },
            object: url as NSURL
        )
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [expectation],
                timeout: timeout
            ),
            .completed,
            "Expected \(url.lastPathComponent) to be created.",
            file: file,
            line: line
        )
    }

    private func waitForValue(
        _ expectedValue: String,
        of element: XCUIElement,
        message: String,
        timeout: TimeInterval = 5
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value == %@",
                expectedValue
            ),
            object: element
        )
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [expectation],
                timeout: timeout
            ),
            .completed,
            message
        )
    }

    private func waitForBooleanValue(
        _ expectedValue: Bool,
        of element: XCUIElement,
        message: String,
        timeout: TimeInterval = 5
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else {
                    return false
                }
                if let number = element.value as? NSNumber {
                    return number.boolValue == expectedValue
                }
                let value = String(describing: element.value ?? "")
                    .lowercased()
                return expectedValue
                    ? value == "1" || value == "true" || value == "shown"
                    : value == "0" || value == "false" || value == "hidden"
            },
            object: element
        )
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [expectation],
                timeout: timeout
            ),
            .completed,
            message
        )
    }

    private func selectComparisonMode(
        _ mode: String,
        using picker: XCUIElement
    ) {
        app.activate()
        let option = app.menuItems[mode].firstMatch
        var selectedThroughMenu = false
        for attempt in 0..<2 {
            picker.click()
            if option.waitForExistence(timeout: 2) {
                option.click()
                selectedThroughMenu = true
                break
            }
            if attempt == 0 {
                app.typeKey(.escape, modifierFlags: [])
                app.activate()
            }
        }
        if !selectedThroughMenu {
            // Focused macOS pop-up buttons support type-ahead even when a
            // transient menu is not exposed to accessibility automation.
            app.typeKey(
                String(mode.prefix(1)).lowercased(),
                modifierFlags: []
            )
            if !reachesValue(mode, of: picker, timeout: 1) {
                app.typeKey(.return, modifierFlags: [])
            }
        }
        waitForValue(
            mode,
            of: picker,
            message: "\(mode) should become the active comparison mode."
        )
    }

    private func reachesValue(
        _ expectedValue: String,
        of element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value == %@",
                expectedValue
            ),
            object: element
        )
        return XCTWaiter.wait(
            for: [expectation],
            timeout: timeout
        ) == .completed
    }

    private func waitForValueContaining(
        _ expectedFragment: String,
        of element: XCUIElement,
        message: String,
        timeout: TimeInterval = 5
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value CONTAINS %@",
                expectedFragment
            ),
            object: element
        )
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [expectation],
                timeout: timeout
            ),
            .completed,
            message
        )
    }

    private func waitForLabelContaining(
        _ expectedFragment: String,
        of element: XCUIElement,
        message: String,
        timeout: TimeInterval = 5
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label CONTAINS %@",
                expectedFragment
            ),
            object: element
        )
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [expectation],
                timeout: timeout
            ),
            .completed,
            message
        )
    }

    private func waitForValueNotContaining(
        _ excludedFragment: String,
        of element: XCUIElement,
        message: String,
        timeout: TimeInterval = 5
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "NOT (value CONTAINS %@)",
                excludedFragment
            ),
            object: element
        )
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [expectation],
                timeout: timeout
            ),
            .completed,
            message
        )
    }

    private func verifyCompositionOutputMenu(
        expectedItems: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let exportControl = identified(
            "editor.output.export.current"
        )
        revealInContentCommandBar(
            exportControl,
            file: file,
            line: line
        )
        exportControl.click()

        for title in expectedItems {
            let outputItem = exportControl
                .descendants(matching: .menuItem)[title]
                .firstMatch
            XCTAssertTrue(
                outputItem.waitForExistence(timeout: 5),
                "\(title) should be available for this composition.",
                file: file,
                line: line
            )
            XCTAssertTrue(
                outputItem.isEnabled,
                "\(title) should be enabled for this composition.",
                file: file,
                line: line
            )
        }
        app.typeKey(.escape, modifierFlags: [])
    }
}
