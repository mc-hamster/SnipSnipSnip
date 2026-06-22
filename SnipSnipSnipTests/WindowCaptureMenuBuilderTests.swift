import AppKit
import XCTest
@testable import SnipSnipSnip

@MainActor
final class WindowCaptureMenuBuilderTests: XCTestCase {
    private func makeContext(
        windows: [CaptureWindowSummary] = [],
        isActionEnabled: Bool = true,
        isUIMapEnabled: Bool = false
    ) -> WindowCaptureMenuContext {
        WindowCaptureMenuContext(
            windows: windows,
            isActionEnabled: isActionEnabled,
            isUIMapEnabled: isUIMapEnabled
        )
    }

    func testQuickMenuIncludesPickSuggestedWindowsAndMoreWindows() {
        let windows = (1...6).map { makeWindow(id: $0) }
        let menu = buildMenu(context: makeContext(windows: windows))

        XCTAssertEqual(menu.items.first?.title, "Pick On Screen")
        XCTAssertEqual(menu.items.last?.title, "More Windows…")

        let representedWindows = menu.items.compactMap { $0.representedObject as? CaptureWindowSummary }
        XCTAssertEqual(representedWindows.map(\.id), windows.prefix(WindowCaptureMenuBuilder.suggestedWindowLimit).map(\.id))
        XCTAssertEqual(representedWindows.count, WindowCaptureMenuBuilder.suggestedWindowLimit)
    }

    func testQuickMenuKeepsPickAndMoreWindowsWhenNoWindowsAreLoaded() {
        let menu = buildMenu(context: makeContext())

        XCTAssertEqual(menu.items.map(\.title), ["Pick On Screen", "", "More Windows…"])
    }

    func testQuickMenuDisablesActionsWhileCaptureIsWorking() {
        let menu = buildMenu(context: makeContext(windows: [makeWindow(id: 1)], isActionEnabled: false))
        let actionItems = menu.items.filter { !$0.isSeparatorItem }

        XCTAssertFalse(actionItems.isEmpty)
        XCTAssertTrue(actionItems.allSatisfy { !$0.isEnabled })
    }

    private func buildMenu(context: WindowCaptureMenuContext) -> NSMenu {
        WindowCaptureMenuBuilder.makeMenu(
            context: context,
            target: self,
            pickOnScreenAction: #selector(pickWindowOnScreen),
            captureWindowAction: #selector(captureWindow(_:)),
            presentWindowPickerAction: #selector(presentWindowPicker),
            thumbnailSize: NSSize(width: 64, height: 40)
        )
    }

    private func makeWindow(id: Int) -> CaptureWindowSummary {
        makeCaptureWindow(
            id: CGWindowID(id),
            ownerPID: pid_t(id),
            ownerName: "App \(id)",
            title: "Window \(id)",
            focusRank: id,
            frame: CGRect(x: id * 10, y: id * 10, width: 320, height: 200),
            thumbnailSize: CGSize(width: 32, height: 20)
        )
    }

    @objc private func pickWindowOnScreen() {}

    @objc private func captureWindow(_ sender: NSMenuItem) {}

    @objc private func presentWindowPicker() {}
}
