import CoreGraphics
import Foundation
import XCTest
@testable import SnipSnipSnip

@MainActor
final class UXAccessibilityReleaseTests: XCTestCase {
    func testRegionCommitModeMapsOntoCompatibleBooleans() {
        var preferences = RegionCapturePreferences()

        preferences.commitMode = .captureImmediately
        XCTAssertFalse(preferences.showsActionControls)
        XCTAssertFalse(preferences.advancedControlsEnabled)

        preferences.commitMode = .showCaptureAndCancel
        XCTAssertTrue(preferences.showsActionControls)
        XCTAssertFalse(preferences.advancedControlsEnabled)

        preferences.commitMode = .showPrecisionControls
        XCTAssertFalse(preferences.showsActionControls)
        XCTAssertTrue(preferences.advancedControlsEnabled)
    }

    func testNewInstallRetentionDefaultsToThirtyDays() {
        withDefaults(named: #function) { defaults in
            let store = ArchivePreferenceStore(storage: defaults)

            XCTAssertEqual(store.loadRecycleBinRetentionDays(), 30)
            XCTAssertTrue(defaults.bool(forKey: AppModelPreferenceKey.recycleBinRetentionDefaultMigrationCompleted))
        }
    }

    func testExistingInstallWithoutStoredRetentionKeepsLegacyTwoDayDefaultOnce() {
        withDefaults(named: #function) { defaults in
            defaults.set(1, forKey: AppModelPreferenceKey.completedOnboardingVersion)
            let store = ArchivePreferenceStore(storage: defaults)

            XCTAssertEqual(store.loadRecycleBinRetentionDays(), 2)

            defaults.removeObject(forKey: AppModelPreferenceKey.recycleBinRetentionDays)
            XCTAssertEqual(store.loadRecycleBinRetentionDays(), 30)
        }
    }

    func testRetentionLoadsAndSavesWithinOneThroughOneHundredEightyDays() {
        withDefaults(named: #function) { defaults in
            let store = ArchivePreferenceStore(storage: defaults)

            defaults.set(-20, forKey: AppModelPreferenceKey.recycleBinRetentionDays)
            XCTAssertEqual(store.loadRecycleBinRetentionDays(), 1)

            defaults.set(999, forKey: AppModelPreferenceKey.recycleBinRetentionDays)
            XCTAssertEqual(store.loadRecycleBinRetentionDays(), 180)

            defaults.set("malformed", forKey: AppModelPreferenceKey.recycleBinRetentionDays)
            XCTAssertEqual(store.loadRecycleBinRetentionDays(), 1)

            store.saveRecycleBinRetentionDays(75)
            XCTAssertEqual(store.loadRecycleBinRetentionDays(), 75)
        }
    }

    func testOnboardingCheckpointAndClipboardAcknowledgementRoundTrip() {
        withDefaults(named: #function) { defaults in
            let store = LifecyclePreferenceStore(storage: defaults)

            XCTAssertNil(store.loadOnboardingResumeCheckpoint())
            XCTAssertFalse(store.loadOnboardingClipboardChoiceAcknowledged())
            XCTAssertFalse(store.loadPostOnboardingDiscoveryPending())

            store.saveOnboardingResumeCheckpoint(.clipboard)
            store.saveOnboardingClipboardChoiceAcknowledged(true)
            store.savePostOnboardingDiscoveryPending(true)
            XCTAssertEqual(store.loadOnboardingResumeCheckpoint(), .clipboard)
            XCTAssertTrue(store.loadOnboardingClipboardChoiceAcknowledged())
            XCTAssertTrue(store.loadPostOnboardingDiscoveryPending())

            defaults.set("firstSnip", forKey: AppModelPreferenceKey.onboardingResumeCheckpoint)
            XCTAssertEqual(store.loadOnboardingResumeCheckpoint()?.currentStep, .clipboard)

            store.saveOnboardingResumeCheckpoint(nil)
            store.savePostOnboardingDiscoveryPending(false)
            XCTAssertNil(store.loadOnboardingResumeCheckpoint())
            XCTAssertFalse(store.loadPostOnboardingDiscoveryPending())
        }
    }

    func testFirstRunOnboardingRequiresCaptureAccessAndClipboardChoiceButReplayDoesNotBlock() {
        XCTAssertFalse(OnboardingCompletionPolicy.canComplete(
            mode: .firstRun,
            hasScreenRecording: false,
            hasMadeClipboardChoice: true
        ))
        XCTAssertFalse(OnboardingCompletionPolicy.canComplete(
            mode: .firstRun,
            hasScreenRecording: true,
            hasMadeClipboardChoice: false
        ))
        XCTAssertTrue(OnboardingCompletionPolicy.canComplete(
            mode: .firstRun,
            hasScreenRecording: true,
            hasMadeClipboardChoice: true
        ))
        XCTAssertTrue(OnboardingCompletionPolicy.canComplete(
            mode: .replay,
            hasScreenRecording: false,
            hasMadeClipboardChoice: false
        ))
    }

    func testSettingsDestinationsAndLibraryPagesMatchReleaseInformationArchitecture() {
        XCTAssertEqual(
            AppSettingsTab.allCases,
            [.general, .capture, .presets, .editorOutput, .shortcuts, .recording, .guide, .library, .privacy]
        )
        XCTAssertEqual(LibrarySettingsSection.allCases, [.snips, .clipboard])
    }

    func testShortcutDefaultsAndLiveCatalogUseCurrentPreferences() {
        XCTAssertEqual(GlobalHotKeyAction.defaultKeys[.repeatLastCapture], .seven)
        XCTAssertEqual(GlobalHotKeyAction.defaultKeys[.screenInspector], .eight)
        XCTAssertEqual(GlobalHotKeyAction.defaultKeys[.guide], .nine)

        let preferences = CaptureAutomationPreferences(
            repeatLastCaptureHotkey: .r,
            screenInspectorHotkey: .i,
            guideHotkey: .g
        )
        let entries = AppShortcut.catalogSections(
            preferences: preferences,
            includesGuideCapture: true
        )
        .first(where: { $0.title == "Default Global Capture" })?
        .entries ?? []

        XCTAssertTrue(entries.contains(.init(keys: "Command-Shift-R", action: "Repeat Last Capture")))
        XCTAssertTrue(entries.contains(.init(keys: "Command-Shift-I", action: "Open Screen Inspector")))
        XCTAssertTrue(entries.contains(.init(keys: "Command-Shift-G", action: "Start or stop Guide")))
        XCTAssertNotNil(GlobalHotKeyKey.three.knownSystemConflictWarning)
        XCTAssertNil(GlobalHotKeyKey.seven.knownSystemConflictWarning)
    }

    func testCommandWDispositionNeverClosesOrTerminatesAWindow() {
        XCTAssertEqual(
            AppOpenBridge.closeShortcutDisposition(for: [.titled, .miniaturizable]),
            .miniaturize
        )
        XCTAssertEqual(
            AppOpenBridge.closeShortcutDisposition(for: [.titled]),
            .orderOut
        )
        XCTAssertEqual(
            AppOpenBridge.closeShortcutDisposition(for: nil),
            .hideApplication
        )
    }

    func testNativeFilePanelsSuspendCaptureKeyEquivalents() {
        XCTAssertTrue(NativePanelShortcutPolicy.suspendsCaptureKeyEquivalents(for: NSOpenPanel()))
        XCTAssertTrue(NativePanelShortcutPolicy.suspendsCaptureKeyEquivalents(for: NSSavePanel()))
        XCTAssertFalse(NativePanelShortcutPolicy.suspendsCaptureKeyEquivalents(for: NSWindow()))
    }

    func testHelpSearchRetainsMatchesSelectsFirstAndRestoresPreviousArticle() {
        let retained = HelpSearchSelectionPolicy.resolve(
            currentID: "permissions",
            preSearchID: nil,
            oldQuery: "",
            newQuery: "screen",
            matchingIDs: ["permissions", "capture"],
            defaultID: "get-started"
        )
        XCTAssertEqual(retained, .init(selectedID: "permissions", preSearchID: "permissions"))

        let changed = HelpSearchSelectionPolicy.resolve(
            currentID: retained.selectedID,
            preSearchID: retained.preSearchID,
            oldQuery: "screen",
            newQuery: "export",
            matchingIDs: ["copy-save-export"],
            defaultID: "get-started"
        )
        XCTAssertEqual(changed, .init(selectedID: "copy-save-export", preSearchID: "permissions"))

        let noResults = HelpSearchSelectionPolicy.resolve(
            currentID: changed.selectedID,
            preSearchID: changed.preSearchID,
            oldQuery: "export",
            newQuery: "no matches",
            matchingIDs: [],
            defaultID: "get-started"
        )
        XCTAssertNil(noResults.selectedID)

        let cleared = HelpSearchSelectionPolicy.resolve(
            currentID: noResults.selectedID,
            preSearchID: noResults.preSearchID,
            oldQuery: "no matches",
            newQuery: "",
            matchingIDs: [],
            defaultID: "get-started"
        )
        XCTAssertEqual(cleared, .init(selectedID: "permissions", preSearchID: nil))
    }

    func testAnnotationAccessibilityDescriptorIncludesSafeTextGeometryAndActions() {
        let annotation = Annotation.makeText(at: CGPoint(x: 12, y: 18)).updatingText("Review this")
        let descriptor = AnnotationAccessibilityDescriptor(
            annotation: annotation,
            isSelected: true,
            layerPosition: 2,
            layerCount: 4,
            canGroup: true
        )

        XCTAssertTrue(descriptor.label.contains("Review this"))
        XCTAssertTrue(descriptor.value.contains("Selected"))
        XCTAssertTrue(descriptor.value.contains("layer 2 of 4"))
        XCTAssertTrue(descriptor.supportedActions.contains(.editText))
        XCTAssertTrue(descriptor.supportedActions.contains(.duplicate))
        XCTAssertTrue(descriptor.supportedActions.contains(.group))
    }

    func testRedactionAccessibilityDescriptorNeverExposesContent() {
        let annotation = Annotation.makeSolidRedaction(in: CGRect(x: 4, y: 8, width: 90, height: 30))
        let descriptor = AnnotationAccessibilityDescriptor(
            annotation: annotation,
            isSelected: false,
            layerPosition: 1,
            layerCount: 1
        )

        XCTAssertNil(descriptor.visibleText)
        XCTAssertEqual(descriptor.label, "Redact")
    }

    func testOutputAppearancesUseDistinctFilenameSuffixes() {
        XCTAssertEqual(
            ImageExporter.editedFilename(
                suggestedFilename: "Capture.png",
                format: .png,
                appearance: .plain
            ),
            "Capture-edited.png"
        )
        XCTAssertEqual(
            ImageExporter.editedFilename(
                suggestedFilename: "Capture.png",
                format: .png,
                appearance: .styled
            ),
            "Capture-styled.png"
        )
    }

    private func withDefaults(
        named name: String,
        operation: (UserDefaults) -> Void
    ) {
        let suiteName = "UXAccessibilityReleaseTests.\(name)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        operation(defaults)
    }
}
