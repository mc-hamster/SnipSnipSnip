import XCTest

/// Asset production only: replaces the old campaign test in a disposable snapshot.
@MainActor
final class AppStoreScreenshotAssetUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--snipsnipsnip-composition-ui-testing",
            "--snipsnipsnip-app-store-screenshots", "-AppleInterfaceStyle", "Light"]
        app.launchEnvironment["SNIPSNIPSNIP_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launchEnvironment["SNIP_CAMPAIGN_DEMO"] = "__CAMPAIGN_DEMO__"
        app.launch()
        app.activate()
    }

    override func tearDown() { app?.terminate() }

    func testCaptureCampaignSources() throws {
        let main = app.windows.firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 15))
        XCTAssertTrue(element("editor.annotationCanvas").waitForExistence(timeout: 15))
        capture(main, "01-screenshot-edit")

        try promote("Compare", waitingFor: "composition.comparison")
        capture(main, "03-comparison")
        try undoPromotion()
        try promote("Add as Step", waitingFor: "composition.steps")
        capture(main, "04-steps")
        try undoPromotion()
        try promote("Combine", waitingFor: "composition.layout")
        capture(main, "05-combined-image")
        try undoPromotion()

        app.typeKey("p", modifierFlags: [.command, .option, .control])
        let polish = element("capture.session.polish")
        XCTAssertTrue(polish.waitForExistence(timeout: 5))
        polish.click()
        XCTAssertTrue(app.buttons["Back to Content"].waitForExistence(timeout: 10))
        app.buttons["Canvas"].firstMatch.click()
        capture(main, "06-polish")
        app.buttons["Back to Content"].click()
        element("editor.backToCapture").click()
        XCTAssertTrue(element("capture.header").waitForExistence(timeout: 10))
        capture(main, "07-capture-home")

        app.buttons["Clipboard History"].firstMatch.click()
        let clipboard = app.windows.matching(identifier: "clipboard-history").firstMatch
        XCTAssertTrue(clipboard.waitForExistence(timeout: 5))
        capture(clipboard, "08-clipboard-history")
        let preview = clipboard.buttons["Preview"].firstMatch
        if preview.exists {
            preview.click()
            capture(clipboard, "08-clipboard-preview")
        }
        clipboard.buttons[XCUIIdentifierCloseWindow].click()
        app.activate()

        let menu = app.menuBars.menuBarItems["Capture"]
        menu.click()
        app.menuItems["Screen Ruler"].hover()
        app.menuItems["New Horizontal Ruler"].click()
        let ruler = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'screen-ruler-'")).firstMatch
        XCTAssertTrue(ruler.waitForExistence(timeout: 5), app.debugDescription)
        capture(ruler, "09-screen-ruler")
        ruler.buttons["Close this ruler."].click()
        menu.click()
        app.menuItems["Screen Inspector"].hover()
        app.menuItems["Open Screen Inspector"].click()
        let inspector = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'screen-inspector-'")).firstMatch
        XCTAssertTrue(inspector.waitForExistence(timeout: 5))
        capture(inspector, "10-screen-inspector")
        if inspector.buttons[XCUIIdentifierCloseWindow].exists {
            inspector.buttons[XCUIIdentifierCloseWindow].click()
        }
        app.activate()

        app.typeKey("v", modifierFlags: [.command, .option, .control])
        XCTAssertTrue(element("video.commandBar").waitForExistence(timeout: 20))
        capture(main, "11-video-review")
        let trim = element("video.tool.Trim")
        XCTAssertTrue(trim.waitForExistence(timeout: 5))
        trim.click(); capture(main, "12-video-trim")
    }

    private func promote(_ title: String, waitingFor identifier: String) throws {
        app.typeKey("a", modifierFlags: [.command, .option])
        let chooser = app.sheets.firstMatch
        XCTAssertTrue(chooser.waitForExistence(timeout: 5))
        chooser.buttons[title].click()
        XCTAssertTrue(element(identifier).waitForExistence(timeout: 10))
        if element("editor.notice").exists {
            XCTAssertTrue(element("editor.notice").waitForNonExistence(timeout: 8))
        }
    }

    private func undoPromotion() throws {
        app.buttons["Undo"].firstMatch.click()
        XCTAssertTrue(element("editor.annotationCanvas").waitForExistence(timeout: 10))
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func capture(_ element: XCUIElement, _ name: String) {
        Thread.sleep(forTimeInterval: 1.2)
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
