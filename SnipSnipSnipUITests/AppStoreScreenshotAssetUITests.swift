import XCTest

/// Captures privacy-safe App Store campaign source images from the real app UI.
///
/// Run this suite by itself. It launches one isolated app process with the
/// production App Store feature gates and deterministic capture inputs.
@MainActor
final class AppStoreScreenshotAssetUITests: XCTestCase {
    private var app: XCUIApplication!
    private var outputDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false

        let runIdentifier = UUID().uuidString
        app = XCUIApplication()
        app.launchArguments = [
            "--snipsnipsnip-composition-ui-testing",
            "--snipsnipsnip-app-store-screenshots",
            "-AppleInterfaceStyle",
            "Light",
        ]
        app.launchEnvironment["SNIPSNIPSNIP_UI_TEST_RUN_ID"] = runIdentifier
        app.launch()
        app.activate()

        outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnipSnip-AppStore-Screenshots", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        app?.terminate()
        app = nil
        outputDirectory = nil
    }

    func testCaptureCampaignSources() throws {
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 15))
        XCTAssertTrue(element("editor.annotationCanvas").waitForExistence(timeout: 10))

        try capture(mainWindow, named: "01-screenshot-edit")

        let create = element("creation.present")
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).click()
        XCTAssertTrue(element("creation.quickStart").waitForExistence(timeout: 5))
        try capture(mainWindow, named: "02-create")
        app.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(element("editor.annotationCanvas").waitForExistence(timeout: 5))

        try promote(to: "Compare", waitingFor: "composition.comparison")
        try dismissEditorNotice()
        try capture(mainWindow, named: "03-comparison")
        try returnToScreenshot()

        try promote(to: "Add as Step", waitingFor: "composition.steps")
        try dismissEditorNotice()
        try capture(mainWindow, named: "04-steps")
        try returnToScreenshot()

        try promote(to: "Combine", waitingFor: "composition.layout")
        try dismissEditorNotice()
        try capture(mainWindow, named: "05-combined-image")
        try returnToScreenshot()

        let polish = element("capture.session.polish")
        XCTAssertTrue(polish.waitForExistence(timeout: 5))
        polish.click()
        XCTAssertTrue(app.buttons["Back to Content"].waitForExistence(timeout: 10))
        try capture(mainWindow, named: "06-polish")
        app.buttons["Back to Content"].click()

        let discard = element("editor.discard")
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        discard.click()
        if app.sheets.firstMatch.waitForExistence(timeout: 2) {
            let confirmation = app.sheets.firstMatch.buttons["Discard Changes"].firstMatch
            if confirmation.exists {
                confirmation.click()
            }
        }
        XCTAssertTrue(element("capture.header").waitForExistence(timeout: 10))
        try capture(mainWindow, named: "07-capture-home")

        let clipboard = app.buttons["Clipboard History"].firstMatch
        XCTAssertTrue(clipboard.waitForExistence(timeout: 5))
        clipboard.click()
        let clipboardWindow = app.windows.matching(identifier: "clipboard-history").firstMatch
        XCTAssertTrue(clipboardWindow.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Release comparison – 1.1.3"].waitForExistence(timeout: 5))
        try capture(clipboardWindow, named: "08-clipboard-history")
        let closeClipboard = clipboardWindow.buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(closeClipboard.waitForExistence(timeout: 5))
        closeClipboard.click()
        XCTAssertFalse(clipboardWindow.waitForExistence(timeout: 5))
        app.activate()
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))

        let captureMenu = app.menuBars.menuBarItems["Capture"]
        XCTAssertTrue(captureMenu.waitForExistence(timeout: 5))
        captureMenu.click()
        let ruler = app.menuItems["Screen Ruler"]
        XCTAssertTrue(ruler.waitForExistence(timeout: 5))
        ruler.hover()
        let horizontal = app.menuItems["New Horizontal Ruler"]
        XCTAssertTrue(horizontal.waitForExistence(timeout: 5))
        horizontal.click()
        waitForPresentation()
        try capture(app, named: "09-screen-ruler")

        captureMenu.click()
        let inspectorMenu = app.menuItems["Screen Inspector"]
        XCTAssertTrue(inspectorMenu.waitForExistence(timeout: 5))
        inspectorMenu.hover()
        let inspector = app.menuItems["Open Screen Inspector"]
        XCTAssertTrue(inspector.waitForExistence(timeout: 5))
        inspector.click()
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Freeze'")
        ).firstMatch.waitForExistence(timeout: 5))
        waitForPresentation()
        try capture(app, named: "10-screen-ruler-inspector")
    }

    private func promote(to title: String, waitingFor identifier: String) throws {
        app.typeKey("a", modifierFlags: [.command, .option])
        let chooser = app.sheets.firstMatch
        XCTAssertTrue(chooser.waitForExistence(timeout: 5))
        let button = chooser.buttons[title]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.click()
        XCTAssertTrue(element(identifier).waitForExistence(timeout: 10))
    }

    private func returnToScreenshot() throws {
        let undo = app.buttons["Undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        undo.click()
        XCTAssertTrue(element("editor.annotationCanvas").waitForExistence(timeout: 10))
    }

    private func dismissEditorNotice() throws {
        let notice = element("editor.notice")
        if notice.exists {
            XCTAssertTrue(
                notice.waitForNonExistence(timeout: 5),
                "The transient composition notice should dismiss before the App Store capture."
            )
        }
        XCTAssertFalse(
            notice.exists,
            "App Store captures must not include transient editor notices."
        )
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    private func capture(_ element: XCUIElement, named name: String) throws {
        let screenshot = element.screenshot()
        let destination = outputDirectory
            .appendingPathComponent("\(name).png", isDirectory: false)
        try screenshot.pngRepresentation.write(to: destination, options: .atomic)

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitForPresentation() {
        Thread.sleep(forTimeInterval: 0.6)
    }
}
