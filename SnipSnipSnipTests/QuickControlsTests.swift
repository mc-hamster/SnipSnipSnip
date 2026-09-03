import AppKit
import CoreGraphics
import XCTest
@testable import SnipSnipSnip

@MainActor
final class QuickControlsTests: XCTestCase {
    func testQuickControlsPresentationContextPreservesDisplayAndCompactCancellation() {
        let context = WorkflowPresentationContext.quickControls(displayID: 42)

        XCTAssertEqual(context.origin, .quickControls)
        XCTAssertEqual(context.displayID, 42)
        XCTAssertFalse(context.shouldHideApplicationWindowForCapture)
        XCTAssertFalse(context.shouldReturnToMainWindowAfterCancellation)
    }

    func testApplicationPresentationContextRetainsExistingWindowBehavior() {
        let context = WorkflowPresentationContext.application

        XCTAssertEqual(context.origin, .application)
        XCTAssertNil(context.displayID)
        XCTAssertTrue(context.shouldHideApplicationWindowForCapture)
        XCTAssertTrue(context.shouldReturnToMainWindowAfterCancellation)
    }

    func testCaptureCompletionContextCarriesPresentationOriginThroughDeferredWork() {
        let presentationContext = WorkflowPresentationContext.quickControls(
            displayID: 7
        )
        let context = CaptureCompletionContext(
            presentationContext: presentationContext
        )

        XCTAssertEqual(context.presentationContext, presentationContext)
    }

    func testDefaultPreferencesShowDockAtStartupWithUniqueControls() {
        let preferences = QuickControlsPreferences.default

        XCTAssertTrue(preferences.isVisible)
        XCTAssertTrue(preferences.resolvedShowsOnAppLaunch)
        XCTAssertFalse(preferences.items.isEmpty)
        XCTAssertEqual(
            Set(preferences.items.map(\.kind)).count,
            preferences.items.count
        )
        XCTAssertEqual(
            preferences.items.map(\.kind),
            [.captureRegion, .captureWindow, .captureScreen,
             .repeatLastCapture, .capturePresets, .recordRegion, .timer]
        )
        XCTAssertEqual(preferences.resolvedPanelSize, QuickControlsPreferences.defaultPanelSize)
        XCTAssertEqual(preferences.resolvedDockState, .expanded)
        XCTAssertEqual(preferences.resolvedDockEdge, .right)
    }

    func testSanitizationPreservesVisibilityDeduplicatesControlsAndFitsFrameToContent() {
        let preferences = QuickControlsPreferences(
            isVisible: true,
            items: [
                QuickControlItem(kind: .captureRegion),
                QuickControlItem(kind: .captureRegion, size: .wide),
                QuickControlItem(kind: .screenInspector),
            ],
            panelFrame: QuickControlsPanelFrame(
                CGRect(x: 10, y: 20, width: 2_000, height: 40)
            )
        ).sanitized()

        XCTAssertTrue(preferences.isVisible)
        XCTAssertEqual(preferences.items.map(\.kind), [.captureRegion, .screenInspector])
        XCTAssertEqual(preferences.items.first?.size, .compact)
        XCTAssertEqual(preferences.panelFrame?.width, QuickControlsDockMetrics.expandedWidth)
        XCTAssertEqual(preferences.panelFrame?.height, preferences.resolvedPanelSize.height)
    }

    func testPreferenceStoreRoundTripsLayoutVisibilityAndFrame() {
        let defaults = makeDefaults(named: "QuickControlsTests.preferenceStore")
        let store = QuickControlsPreferenceStore(storage: defaults)
        let items = [
            QuickControlItem(kind: .repeatLastCapture, size: .wide),
            QuickControlItem(kind: .timer, size: .compact),
            QuickControlItem(kind: .clipboardHistory, size: .standard),
        ]
        let height = QuickControlsDockMetrics.naturalHeight(
            itemCount: items.count,
            sectionCount: QuickControlsDockGrouping.sections(for: items).count,
            presentation: .compact
        )
        let expected = QuickControlsPreferences(
            isVisible: true,
            items: items,
            panelFrame: QuickControlsPanelFrame(
                CGRect(x: 320, y: 240, width: QuickControlsDockMetrics.compactWidth, height: height)
            ),
            preferredPanelSize: QuickControlsPanelSize(
                CGSize(width: QuickControlsDockMetrics.compactWidth, height: height)
            ),
            dockState: .compact,
            dockEdge: .left
        )

        store.savePreferences(expected)

        XCTAssertEqual(
            QuickControlsPreferenceStore(storage: defaults).loadPreferences(),
            expected
        )
    }

    func testControlCatalogFollowsBuildCapabilitiesWithoutChangingSavedIdentity() {
        let release = BuildTargetCapabilityProvider().snapshot(for: .release)
        let development = BuildTargetCapabilityProvider().snapshot(for: .dev)

        XCTAssertFalse(QuickControlKind.captureScrollingContent.isAvailable(in: release))
        XCTAssertFalse(QuickControlKind.recordGuide.isAvailable(in: release))
        XCTAssertTrue(QuickControlKind.captureScrollingContent.isAvailable(in: development))
        XCTAssertTrue(QuickControlKind.recordGuide.isAvailable(in: development))
        XCTAssertEqual(
            QuickControlItem(kind: .captureScrollingContent).kind,
            .captureScrollingContent
        )
    }

    func testCatalogSeparatesScreenshotCreationAndRecordingActions() {
        XCTAssertEqual(QuickControlKind.captureRegion.category, .screenshot)
        XCTAssertEqual(QuickControlKind.createComparison.category, .create)
        XCTAssertEqual(QuickControlKind.recordRegion.category, .record)
        XCTAssertEqual(QuickControlKind.captureRegion.label, "Capture Region")
        XCTAssertEqual(QuickControlKind.recordRegion.label, "Record Region")
        XCTAssertEqual(QuickControlKind.captureRegion.intentDescription, "Select part of the screen")
        XCTAssertEqual(QuickControlKind.recordRegion.intentDescription, "Select an area to record")
        XCTAssertTrue(
            QuickControlKind.allCases.allSatisfy {
                !$0.intentDescription.isEmpty && $0.intentDescription != $0.category.label
            }
        )
        XCTAssertTrue(
            QuickControlDropCompatibility.allows(.captureRegion, relativeTo: .captureWindow)
        )
        XCTAssertFalse(
            QuickControlDropCompatibility.allows(.captureRegion, relativeTo: .recordRegion)
        )
        XCTAssertFalse(
            QuickControlDropCompatibility.allows(.captureRegion, relativeTo: .captureRegion)
        )
    }

    func testCustomizationLibraryKeepsCaptureOptionsLast() {
        XCTAssertEqual(
            QuickControlCategory.customizationLibraryOrder.last,
            .captureOptions
        )
        XCTAssertEqual(
            Set(QuickControlCategory.customizationLibraryOrder),
            Set(QuickControlCategory.allCases)
        )
    }

    func testRestoreDefaultsReinstatesFirstInstallControlsAndDockConfiguration() {
        let suiteName = "QuickControlsTests.restoreDefaults"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            defaults: defaults,
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        ).quickControls
        var preferences = model.preferences
        preferences.items = [QuickControlItem(kind: .screenInspector)]
        preferences.dockState = .compact
        preferences.dockEdge = .left
        preferences.isVisible = true
        model.preferences = preferences

        model.restoreDefaultLayout()

        XCTAssertEqual(model.preferences.items, QuickControlsPreferences.defaultItems)
        XCTAssertEqual(model.preferences.resolvedDockState, .expanded)
        XCTAssertEqual(model.preferences.resolvedDockEdge, .right)
        XCTAssertTrue(model.preferences.isVisible)
    }

    func testVisiblePaletteIsPreservedInsteadOfOrderedFrontAgain() {
        XCTAssertEqual(
            QuickControlsPaletteVisibilityDecision.resolve(
                isRequestedVisible: true,
                isPanelVisible: true
            ),
            .preserve
        )
        XCTAssertEqual(
            QuickControlsPaletteVisibilityDecision.resolve(
                isRequestedVisible: true,
                isPanelVisible: false
            ),
            .show
        )
        XCTAssertEqual(
            QuickControlsPaletteVisibilityDecision.resolve(
                isRequestedVisible: false,
                isPanelVisible: true
            ),
            .hide
        )
    }

    func testTimerTileStateIsSharedByPaletteAndPreview() {
        let suiteName = "QuickControlsTests.timerTileState"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            defaults: defaults,
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        ).quickControls

        XCTAssertEqual(
            model.tileState(for: .timer),
            QuickControlTileState(
                isOn: false,
                detail: "No delay",
                showsMenuIndicator: true
            )
        )

        model.capture.captureDelay = .fiveSeconds

        XCTAssertEqual(
            model.tileState(for: .timer),
            QuickControlTileState(
                isOn: true,
                detail: "5-second delay",
                showsMenuIndicator: true
            )
        )
    }

    func testDockSizeIgnoresStoredDimensionsAndFitsConfiguredControls() {
        var preferences = QuickControlsPreferences.default
        preferences.preferredPanelSize = QuickControlsPanelSize(CGSize(width: 999, height: 512))

        XCTAssertEqual(preferences.resolvedPanelSize, QuickControlsPreferences.defaultPanelSize)

        preferences.dockState = .compact
        let compactHeight = QuickControlsDockMetrics.naturalHeight(
            itemCount: preferences.items.count,
            sectionCount: QuickControlsDockGrouping.sections(for: preferences.items).count,
            presentation: .compact
        )
        XCTAssertEqual(preferences.resolvedPanelSize, CGSize(width: 64, height: compactHeight))

        preferences.items.append(QuickControlItem(kind: .clipboardHistory))
        XCTAssertGreaterThan(preferences.resolvedPanelSize.height, compactHeight)

        preferences.dockState = .expanded
        let baselineWidth = preferences.resolvedPanelSize.width
        preferences.items.append(QuickControlItem(kind: .captureScrollingContent))
        XCTAssertGreaterThan(preferences.resolvedPanelSize.width, baselineWidth)
    }

    func testLegacyDefaultPanelMigratesToStudioDockWithoutChangingItsPosition() {
        var preferences = QuickControlsPreferences.default
        preferences.preferredPanelSize = QuickControlsPanelSize(
            QuickControlsPreferences.legacyDefaultPanelSize
        )
        preferences.panelFrame = QuickControlsPanelFrame(
            CGRect(origin: CGPoint(x: 240, y: 180), size: QuickControlsPreferences.legacyDefaultPanelSize)
        )
        preferences.densityVersion = nil

        let migrated = preferences.migratedToCurrentDock()

        XCTAssertEqual(migrated.resolvedPanelSize, QuickControlsPreferences.defaultPanelSize)
        XCTAssertEqual(migrated.panelFrame?.x, 240)
        XCTAssertEqual(migrated.panelFrame?.y, 180)
        XCTAssertEqual(migrated.densityVersion, QuickControlsPreferences.currentDensityVersion)
    }

    func testDockMigrationReplacesAUserResizedHeightWithContentHeight() {
        var preferences = QuickControlsPreferences.default
        preferences.preferredPanelSize = QuickControlsPanelSize(CGSize(width: 412, height: 276))
        preferences.densityVersion = nil

        let migrated = preferences.migratedToCurrentDock()

        XCTAssertEqual(migrated.resolvedPanelSize, QuickControlsPreferences.defaultPanelSize)
        XCTAssertEqual(migrated.densityVersion, QuickControlsPreferences.currentDensityVersion)
    }

    func testDockGroupingPreservesSectionAndInternalControlOrder() {
        let items = [
            QuickControlItem(kind: .captureRegion),
            QuickControlItem(kind: .captureScreen),
            QuickControlItem(kind: .recordRegion),
            QuickControlItem(kind: .recordScreen),
            QuickControlItem(kind: .timer),
            QuickControlItem(kind: .captureWindow),
        ]

        let sections = QuickControlsDockGrouping.sections(for: items)

        XCTAssertEqual(sections.map(\.category), [.screenshot, .record, .captureOptions])
        XCTAssertEqual(
            sections.flatMap(\.items).map(\.kind),
            [.captureRegion, .captureScreen, .captureWindow,
             .recordRegion, .recordScreen, .timer]
        )
    }

    func testMovingASectionKeepsItsControlsTogetherAndInOrder() {
        let defaults = makeDefaults(named: "QuickControlsTests.sectionOrdering")
        defer { defaults.removePersistentDomain(forName: "QuickControlsTests.sectionOrdering") }
        let model = AppModel(
            defaults: defaults,
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        ).quickControls
        var preferences = model.preferences
        preferences.items = [
            QuickControlItem(kind: .captureRegion),
            QuickControlItem(kind: .timer),
            QuickControlItem(kind: .captureWindow),
            QuickControlItem(kind: .recordRegion),
            QuickControlItem(kind: .includeCursor),
            QuickControlItem(kind: .recordScreen),
        ]
        model.preferences = preferences

        model.moveSection(.record, before: .screenshot)

        XCTAssertEqual(
            model.preferences.items.map(\.kind),
            [.recordRegion, .recordScreen,
             .captureRegion, .captureWindow,
             .timer, .includeCursor]
        )

        model.moveSection(.record, by: 1)

        XCTAssertEqual(
            QuickControlsDockGrouping.sections(for: model.preferences.items).map(\.category),
            [.screenshot, .record, .captureOptions]
        )
    }

    func testControlReorderingStaysInsideItsSection() {
        let defaults = makeDefaults(named: "QuickControlsTests.controlSectionOrdering")
        defer { defaults.removePersistentDomain(forName: "QuickControlsTests.controlSectionOrdering") }
        let model = AppModel(
            defaults: defaults,
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        ).quickControls
        var preferences = model.preferences
        preferences.items = [
            QuickControlItem(kind: .captureRegion),
            QuickControlItem(kind: .captureWindow),
            QuickControlItem(kind: .timer),
            QuickControlItem(kind: .includeCursor),
        ]
        model.preferences = preferences

        XCTAssertFalse(model.moveItem(.captureRegion, before: .timer))
        model.moveItem(.captureWindow, by: -1)

        XCTAssertEqual(
            model.preferences.items.map(\.kind),
            [.captureWindow, .captureRegion, .timer, .includeCursor]
        )

        XCTAssertTrue(model.moveItem(.captureWindow, after: .captureRegion))
        XCTAssertEqual(
            model.preferences.items.map(\.kind),
            [.captureRegion, .captureWindow, .timer, .includeCursor]
        )
    }

    func testVisibilityCanToggleWithoutAnEnablementGate() {
        let defaults = makeDefaults(named: "QuickControlsTests.visibility")
        defer { defaults.removePersistentDomain(forName: "QuickControlsTests.visibility") }
        let model = AppModel(
            defaults: defaults,
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        ).quickControls

        XCTAssertTrue(model.isVisible)

        model.setVisible(false)
        XCTAssertFalse(model.isVisible)

        model.toggleVisibility()
        XCTAssertTrue(model.isVisible)
    }

    func testStartupPreferenceControlsInitialVisibilityWithoutChangingShowHideNow() {
        let suiteName = "QuickControlsTests.startupVisibility"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = QuickControlsPreferenceStore(storage: defaults)
        var saved = QuickControlsPreferences.default
        saved.isVisible = true
        saved.showsOnAppLaunch = false
        store.savePreferences(saved)

        let optedOut = AppModel(
            defaults: defaults,
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        ).quickControls

        XCTAssertFalse(optedOut.isVisible)
        XCTAssertFalse(optedOut.showsOnAppLaunch)

        optedOut.setVisible(true)
        XCTAssertTrue(optedOut.isVisible)
        XCTAssertFalse(optedOut.showsOnAppLaunch)

        optedOut.setShowsOnAppLaunch(true)
        optedOut.setVisible(false)

        let optedIn = AppModel(
            defaults: defaults,
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        ).quickControls

        XCTAssertTrue(optedIn.isVisible)
        XCTAssertTrue(optedIn.showsOnAppLaunch)
    }

    func testAddingUsesSelectedInsertionPointAndEveryControlCanBeRemoved() {
        let defaults = makeDefaults(named: "QuickControlsTests.layoutEditing")
        defer { defaults.removePersistentDomain(forName: "QuickControlsTests.layoutEditing") }
        let model = AppModel(
            defaults: defaults,
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        ).quickControls

        XCTAssertTrue(model.add(.clipboardHistory, after: .captureWindow))
        XCTAssertEqual(
            model.preferences.items.map(\.kind),
            [.captureRegion, .captureWindow, .clipboardHistory, .captureScreen,
             .repeatLastCapture, .capturePresets, .timer]
        )

        for kind in model.preferences.items.dropFirst().map(\.kind) {
            XCTAssertTrue(model.remove(kind))
        }

        XCTAssertEqual(model.preferences.items.count, 1)
        XCTAssertTrue(model.remove(.captureRegion))
        XCTAssertTrue(model.preferences.items.isEmpty)

        let sanitized = model.preferences.sanitized()
        XCTAssertTrue(sanitized.items.isEmpty)
        XCTAssertFalse(model.remove(.captureRegion))
    }

    func testCustomizationRemainsOpenWhileDockSettingsChange() {
        let suiteName = "QuickControlsTests.customizationSettings"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appModel = AppModel(
            defaults: defaults,
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )
        let model = appModel.quickControls
        let coordinator = appModel.quickControlsCoordinator

        coordinator.activate()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        coordinator.showCustomization()

        guard let window = NSApp.windows.first(where: { $0.title == "Customize Quick Controls" }) else {
            return XCTFail("Expected the Quick Controls customization window to open.")
        }
        defer { window.close() }

        model.setDockState(.compact)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(model.preferences.resolvedDockState, .compact)
    }

}
