import AppKit
import XCTest
@testable import SnipSnipSnip

@MainActor
final class WindowCaptureMenuBuilderTests: XCTestCase {
    private func makeModel(
        windows: [CaptureWindowSummary] = [],
        isWorking: Bool = false
    ) -> AppModel {
        let suiteName = "WindowCaptureMenuBuilderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let model = AppModel(
            defaults: defaults,
            recoveryStore: DocumentRecoveryStore(baseURL: nil),
            captureService: ScreenCaptureService(),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )
        model.availableWindows = windows
        model.isWorking = isWorking
        return retainForTestLifetime(model)
    }

    func testQuickMenuIncludesPickSuggestedWindowsAndMoreWindows() {
        let windows = (1...6).map { makeWindow(id: $0) }
        let model = makeModel(windows: windows)
        let menu = buildMenu(for: model)

        XCTAssertEqual(menu.items.first?.title, "Pick On Screen")
        XCTAssertEqual(menu.items.last?.title, "More Windows…")

        let representedWindows = menu.items.compactMap { $0.representedObject as? CaptureWindowSummary }
        XCTAssertEqual(representedWindows.map(\.id), windows.prefix(WindowCaptureMenuBuilder.suggestedWindowLimit).map(\.id))
        XCTAssertEqual(representedWindows.count, WindowCaptureMenuBuilder.suggestedWindowLimit)
    }

    func testQuickMenuKeepsPickAndMoreWindowsWhenNoWindowsAreLoaded() {
        let model = makeModel()
        let menu = buildMenu(for: model)

        XCTAssertEqual(menu.items.map(\.title), ["Pick On Screen", "", "More Windows…"])
    }

    func testQuickMenuDisablesActionsWhileCaptureIsWorking() {
        let model = makeModel(windows: [makeWindow(id: 1)], isWorking: true)
        let menu = buildMenu(for: model)
        let actionItems = menu.items.filter { !$0.isSeparatorItem }

        XCTAssertFalse(actionItems.isEmpty)
        XCTAssertTrue(actionItems.allSatisfy { !$0.isEnabled })
    }

    private func buildMenu(for model: AppModel) -> NSMenu {
        WindowCaptureMenuBuilder.makeMenu(
            for: model,
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
