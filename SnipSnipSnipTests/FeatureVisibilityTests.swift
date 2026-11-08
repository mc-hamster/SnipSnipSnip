import AppKit
import SwiftUI
import XCTest
@testable import SnipSnipSnip

@MainActor
final class FeatureVisibilityTests: XCTestCase {
    func testSavedShortcutPreferenceCannotExposeUnsupportedAccessibilitySetup() {
        let name = "FeatureVisibilityTests.legacyShortcuts.\(UUID())"
        let defaults = makeDefaults(named: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = VideoPreferenceStore(storage: defaults)
        var saved = VideoRecordingPreferences()
        saved.recordsKeyboardShortcuts = true
        preferences.saveRecordingPreferences(saved)
        let restored = preferences.loadRecordingPreferences()
        XCTAssertEqual(restored.recordsKeyboardShortcuts, true, "Preserve the preference for an edition that supports it")
        for target in [BuildTarget.release, .internalTesting, .externalTesting] {
            XCTAssertFalse(PermissionSettingsAvailability.showsAccessibility(
                capabilities: BuildTargetCapabilityProvider().snapshot(for: target),
                uiMapEnabled: true, recordsKeyboardShortcuts: restored.recordsKeyboardShortcuts == true))
        }
        let keyboardOnly = AppCapabilitySnapshot(buildTarget: .dev, enabledCapabilities: [.videoShortcutCapture])
        XCTAssertTrue(PermissionSettingsAvailability.showsAccessibility(
            capabilities: keyboardOnly, uiMapEnabled: false, recordsKeyboardShortcuts: true))
        XCTAssertFalse(PermissionSettingsAvailability.showsAccessibility(
            capabilities: keyboardOnly, uiMapEnabled: false, recordsKeyboardShortcuts: false))
    }

    func testHelpAdvertisesOnlySupportedCaptureAndAutomationFeatures() throws {
        for enabled in [false, true] {
            let capabilities = AppCapabilitySnapshot(buildTarget: enabled ? .selfRelease : .release,
                enabledCapabilities: enabled ? [.guideCapture, .videoShortcutCapture, .scrollingCapture] : [])
            let articles = HelpGuideView.categories(for: capabilities, fullscreenDisplayMode: .currentDisplay).flatMap(\.articles)
            let shortcuts = try XCTUnwrap(articles.first { $0.id == "keyboard-shortcuts" })
            XCTAssertEqual(shortcuts.sections.flatMap(\.bullets).contains { $0.contains("Start or stop Guide") }, enabled)
            let automation = try XCTUnwrap(articles.first { $0.id == "automation-shortcuts" })
            XCTAssertEqual(automation.sections.flatMap(\.bullets).contains { $0.contains("export a Guide") }, enabled)
            let videoPrivacy = try XCTUnwrap(articles.flatMap(\.sections).first { $0.title == "Cursor, sound, and shortcut privacy" })
            XCTAssertEqual(videoPrivacy.body?.contains("enable Record Keyboard Shortcuts"), enabled)
            let quickCapture = try XCTUnwrap(articles.first { $0.id == "get-started" })
            XCTAssertEqual(quickCapture.sections.flatMap(\.steps).contains { $0.contains(", Scroll,") }, enabled)
            if !enabled {
                XCTAssertTrue(articles.flatMap(\.sections).contains { $0.title == "Open a Guide" }, "Keep shared Guide document workflows")
            }
        }
    }

    func testCreateInstructionsDescriptionMatchesAvailableMethods() async throws {
        for enabled in [false, true] {
            let capabilities = AppCapabilitySnapshot(buildTarget: .dev, enabledCapabilities:
                enabled ? [.guideCapture, .regionCapture] : [.regionCapture])
            let creation = CreationWorkflowModel(capabilities: capabilities,
                draft: CreationDraft(goal: .instructions(.addCaptures)))
            let view = NSHostingView(rootView: CreationQuickStartView(creation: creation))
            let window = HostedViewTestSupport.host(view, size: CGSize(width: 620, height: 560))
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(100))
            view.layoutSubtreeIfNeeded()
            let description = try XCTUnwrap(HostedViewTestSupport.find("creation.goal.detail", in: view))
            let text = try XCTUnwrap(description.accessibilityValue() as? String ?? description.accessibilityLabel())
            XCTAssertEqual(text.contains("Record a Guide"), enabled)
            XCTAssertTrue(text.contains("Steps"))
        }
    }

    func testGuideIntentDiscoverabilityIsPresentInExtractedBuildMetadata() throws {
        let expected = BuildTargetCapabilityProvider().currentSnapshot().isEnabled(.guideCapture)
        XCTAssertEqual(GuideActionIntent.isDiscoverable, expected)
        let url = try XCTUnwrap(Bundle.main.resourceURL)
            .appendingPathComponent("Metadata.appintents/extract.actionsdata")
        let metadata = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let actions: [[String: Any]]
        if let keyedActions = metadata["actions"] as? [String: [String: Any]] {
            actions = Array(keyedActions.values)
        } else {
            actions = try XCTUnwrap(metadata["actions"] as? [[String: Any]])
        }
        let guide = try XCTUnwrap(actions.first { $0["identifier"] as? String == "GuideActionIntent" })
        XCTAssertEqual(guide["isDiscoverable"] as? Bool, expected)
        let visibility = try XCTUnwrap(guide["visibilityMetadata"] as? [String: Any])
        XCTAssertEqual(visibility["isDiscoverable"] as? Bool, expected)
    }
}
