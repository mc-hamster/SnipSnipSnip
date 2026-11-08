import CoreGraphics
import XCTest
@testable import SnipSnipSnip

final class WindowCaptureEligibilityTests: XCTestCase {
    private let excludedPID: pid_t = 900_099

    func testExplicitSelectionIncludesEntireApplicationBandWhileAutomaticRemainsNormalOnly() {
        let normal = Int(CGWindowLevelForKey(.normalWindow))
        let dock = Int(CGWindowLevelForKey(.dockWindow))
        for level in normal..<dock {
            let window = makeScreenWindowSnapshot(layer: level)
            XCTAssertTrue(WindowCaptureEligibility.explicitWindow.allows(window, excluding: excludedPID), "Application level \(level)")
            XCTAssertEqual(WindowCaptureEligibility.automaticFrontmost.allows(window, excluding: excludedPID), level == normal)
        }
    }

    func testExplicitSelectionExcludesDesktopAndHigherOverlayBands() {
        let keys: [CGWindowLevelKey] = [
            .desktopWindow, .desktopIconWindow, .dockWindow, .mainMenuWindow,
            .statusWindow, .popUpMenuWindow, .overlayWindow, .helpWindow,
            .draggingWindow, .screenSaverWindow, .cursorWindow, .assistiveTechHighWindow
        ]
        for key in keys {
            XCTAssertFalse(WindowCaptureEligibility.explicitWindow.allows(
                makeScreenWindowSnapshot(layer: Int(CGWindowLevelForKey(key))), excluding: excludedPID
            ))
        }
        XCTAssertFalse(WindowCaptureEligibility.explicitWindow.allows(
            makeScreenWindowSnapshot(layer: Int(CGWindowLevelForKey(.normalWindow)) - 1), excluding: excludedPID
        ))
    }

    func testBothPoliciesKeepOwnProcessVisibilityAndMinimumSizeRules() {
        let windows = [
            makeScreenWindowSnapshot(ownerPID: excludedPID),
            makeScreenWindowSnapshot(isOnScreen: false),
            makeScreenWindowSnapshot(frame: CGRect(x: 0, y: 0, width: 59, height: 40)),
            makeScreenWindowSnapshot(frame: CGRect(x: 0, y: 0, width: 60, height: 39))
        ]
        for policy in [WindowCaptureEligibility.explicitWindow, .automaticFrontmost] {
            for window in windows { XCTAssertFalse(policy.allows(window, excluding: excludedPID)) }
            XCTAssertTrue(policy.allows(makeScreenWindowSnapshot(frame: CGRect(x: 0, y: 0, width: 60, height: 40)), excluding: excludedPID))
        }
    }

    func testExplicitSelectionRequiresValidOwnershipAndFiniteGeometryButNotATitle() {
        XCTAssertFalse(WindowCaptureEligibility.explicitWindow.allows(makeScreenWindowSnapshot(ownerPID: 0), excluding: excludedPID))
        XCTAssertFalse(WindowCaptureEligibility.explicitWindow.allows(makeScreenWindowSnapshot(ownerPID: -1), excluding: excludedPID))
        XCTAssertFalse(WindowCaptureEligibility.explicitWindow.allows(
            makeScreenWindowSnapshot(frame: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 80)), excluding: excludedPID
        ))
        XCTAssertTrue(WindowCaptureEligibility.explicitWindow.allows(
            makeScreenWindowSnapshot(bundleIdentifier: nil, title: "", layer: Int(CGWindowLevelForKey(.modalPanelWindow))), excluding: excludedPID
        ))
    }

    func testSystemSurfaceOwnersAreExcludedEvenAtNormalLevelAndFinderIsAllowed() {
        for bundleID in ["com.apple.dock", "com.apple.systemuiserver", "com.apple.controlcenter", "com.apple.WindowManager", "com.apple.loginwindow", "com.apple.notificationcenterui", "com.apple.Spotlight"] {
            XCTAssertFalse(WindowCaptureEligibility.explicitWindow.allows(makeScreenWindowSnapshot(bundleIdentifier: bundleID), excluding: excludedPID))
        }
        for owner in ["Dock", "Window Server", "SystemUIServer", "Control Center", "NotificationCenter", "Spotlight"] {
            XCTAssertFalse(WindowCaptureEligibility.explicitWindow.allows(makeScreenWindowSnapshot(ownerName: owner, bundleIdentifier: nil), excluding: excludedPID))
        }
        XCTAssertTrue(WindowCaptureEligibility.explicitWindow.allows(makeScreenWindowSnapshot(ownerName: "Finder", bundleIdentifier: "com.apple.finder"), excluding: excludedPID))
        XCTAssertTrue(WindowCaptureEligibility.explicitWindow.allows(makeScreenWindowSnapshot(ownerName: "Dock", bundleIdentifier: "com.example.dock"), excluding: excludedPID))
    }

    func testWindowListAndTargetResolutionIncludeFloatingModalAndUtilityPanelsWithoutAccessibility() async throws {
        let windows = [
            makeScreenWindowSnapshot(id: 900_001, title: "Document"),
            makeScreenWindowSnapshot(id: 900_002, title: "Inspector", layer: Int(CGWindowLevelForKey(.floatingWindow))),
            makeScreenWindowSnapshot(id: 900_003, title: "Reminders", layer: Int(CGWindowLevelForKey(.modalPanelWindow))),
            makeScreenWindowSnapshot(id: 900_004, title: "Utility", layer: Int(CGWindowLevelForKey(.utilityWindow))),
            makeScreenWindowSnapshot(id: 900_005, title: "Menu", layer: Int(CGWindowLevelForKey(.popUpMenuWindow))),
            makeScreenWindowSnapshot(id: 900_006, bundleIdentifier: "com.apple.dock")
        ]
        let service = ScreenCaptureService(
            permissions: TestCapturePermissionService(status: CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: false)),
            windows: windows
        )
        let candidates = try await service.listWindows(excluding: excludedPID, includeThumbnails: false)
        XCTAssertEqual(Set(candidates.map(\.id)), Set([900_001, 900_002, 900_003, 900_004]))
        let reminder = try XCTUnwrap(candidates.first { $0.id == 900_003 })
        let resolved = try await service.resolveWindowTarget(reminder, excluding: excludedPID)
        XCTAssertEqual(resolved.id, reminder.id)
        XCTAssertEqual(RegionSelectionWindowHover.resolve(at: CGPoint(x: 40, y: 40), in: [reminder], selectionRect: nil, isInteracting: false)?.window.id, reminder.id)
    }

    func testAutomaticFrontmostCaptureAndFallbackIgnoreFloatingPanels() async throws {
        let windows = [
            makeScreenWindowSnapshot(id: 900_001, title: "Z Document"),
            makeScreenWindowSnapshot(id: 900_002, title: "A Inspector", layer: Int(CGWindowLevelForKey(.floatingWindow)))
        ]
        let frontmostPIDs: [pid_t?] = [windows[0].ownerPID, nil, 900_050]
        for frontmostPID in frontmostPIDs {
            let service = ScreenCaptureService(permissions: TestCapturePermissionService(), windows: windows, frontmostApplicationProcessIdentifier: frontmostPID)
            let frontmost = try await service.frontmostWindow(excluding: excludedPID)
            XCTAssertEqual(frontmost.id, windows[0].id)
        }
    }

    func testAutomaticFrontmostCaptureDoesNotFallBackToPanelWhenNoNormalWindowExists() async {
        let service = ScreenCaptureService(permissions: TestCapturePermissionService(), windows: [makeScreenWindowSnapshot(layer: Int(CGWindowLevelForKey(.modalPanelWindow)))])
        do {
            _ = try await service.frontmostWindow(excluding: excludedPID)
            XCTFail("A panel must not replace a normal window in automatic capture.")
        } catch ScreenCaptureError.noWindowsAvailable {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
