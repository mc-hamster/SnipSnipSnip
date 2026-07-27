import Foundation
import WebKit
import XCTest
@testable import SnipSnipSnip

final class CompositionHTMLLocalFileBrowserTests: XCTestCase {
    @MainActor
    func testGeneratedLocalFileInInstalledGoogleChrome() throws {
        try validateGeneratedLocalFile(in: "chrome")
    }

    @MainActor
    func testGeneratedLocalFileInInstalledFirefox() throws {
        try validateGeneratedLocalFile(in: "firefox")
    }

    @MainActor
    func testLocalFileRunsHashPinnedEnhancementAndKeepsRTLStepsOperable() async throws {
        let html = try CompositionHTMLExporter.html(for: CompositionHTMLDocument(
            title: "مراجعة الإصدار",
            layout: .steps,
            items: [
                item(
                    title: "افتح الإعدادات",
                    caption: "اختر المشروع.",
                    stepLabel: "iv"
                ),
                item(
                    title: "Review Build",
                    caption: "Confirm the version.",
                    stepLabel: "v"
                ),
                item(
                    title: "פרסום",
                    caption: "אשר את הגרסה.",
                    stepLabel: "vi"
                ),
            ]
        ))
        let fixture = try LocalHTMLFixture(html: html)
        defer { fixture.remove() }

        let configuration = browserConfiguration(allowsContentJavaScript: true)
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1_024, height: 768),
            configuration: configuration
        )
        let browserHost = LocalBrowserHost(webView: webView)
        defer { browserHost.close() }
        let navigation = LocalFileNavigationWaiter()
        try await navigation.load(fixture.url, in: webView)

        let initial = try await evaluateJSON(
            """
            JSON.stringify({
              protocol: location.protocol,
              enhanced: document.documentElement.classList.contains("is-enhanced"),
              rootDirection: getComputedStyle(document.documentElement).direction,
              titleDirection: getComputedStyle(document.querySelector("h1")).direction,
              loadedImages: Array.from(document.images).every((image) =>
                image.complete && image.naturalWidth === 4 && image.naturalHeight === 3
              ),
              visibleSteps: Array.from(document.querySelectorAll("[data-step]"))
                .filter((step) => !step.hidden)
                .map((step) => Number(step.dataset.step)),
              status: document.querySelector("[data-step-status]").textContent.trim(),
              labels: Array.from(document.querySelectorAll("[data-step-label]"))
                .map((step) => step.dataset.stepLabel),
              listStyles: Array.from(document.querySelectorAll(".step-navigation li"))
                .map((item) => getComputedStyle(item).listStyleType),
              externalResources: performance.getEntriesByType("resource")
                .map((entry) => entry.name)
                .filter((url) => !url.startsWith("data:")),
              cspViolations: window.__compositionCSPViolations || []
            })
            """,
            in: webView
        )

        XCTAssertEqual(initial["protocol"] as? String, "file:")
        XCTAssertEqual(initial["enhanced"] as? Bool, true)
        XCTAssertEqual(initial["rootDirection"] as? String, "rtl")
        XCTAssertEqual(initial["titleDirection"] as? String, "rtl")
        XCTAssertEqual(initial["loadedImages"] as? Bool, true)
        XCTAssertEqual(initial["visibleSteps"] as? [Int], [0])
        XCTAssertEqual(initial["status"] as? String, "iv (1 of 3)")
        XCTAssertEqual(initial["labels"] as? [String], ["iv", "v", "vi"])
        XCTAssertEqual(initial["listStyles"] as? [String], ["none", "none", "none"])
        XCTAssertEqual(initial["externalResources"] as? [String], [])
        XCTAssertEqual(initial["cspViolations"] as? [String], [])

        let afterNext = try await evaluateJSON(
            """
            document.querySelector("[data-step-next]").click();
            JSON.stringify({
              hash: location.hash,
              visibleSteps: Array.from(document.querySelectorAll("[data-step]"))
                .filter((step) => !step.hidden)
                .map((step) => Number(step.dataset.step)),
              status: document.querySelector("[data-step-status]").textContent.trim(),
              currentLabel: document.querySelector("[aria-current=step]").textContent.trim()
            })
            """,
            in: webView
        )

        XCTAssertEqual(afterNext["hash"] as? String, "#step-2")
        XCTAssertEqual(afterNext["visibleSteps"] as? [Int], [1])
        XCTAssertEqual(afterNext["status"] as? String, "v (2 of 3)")
        XCTAssertEqual(afterNext["currentLabel"] as? String, "v. Review Build")

        let afterKeyboard = try await evaluateJSON(
            """
            document.querySelector("[data-step-layout]").dispatchEvent(
              new KeyboardEvent("keydown", { key: "ArrowLeft", bubbles: true })
            );
            JSON.stringify({
              hash: location.hash,
              visibleSteps: Array.from(document.querySelectorAll("[data-step]"))
                .filter((step) => !step.hidden)
                .map((step) => Number(step.dataset.step)),
              status: document.querySelector("[data-step-status]").textContent.trim(),
              nextDisabled: document.querySelector("[data-step-next]").disabled
            })
            """,
            in: webView
        )

        XCTAssertEqual(afterKeyboard["hash"] as? String, "#step-3")
        XCTAssertEqual(afterKeyboard["visibleSteps"] as? [Int], [2])
        XCTAssertEqual(afterKeyboard["status"] as? String, "vi (3 of 3)")
        XCTAssertEqual(afterKeyboard["nextDisabled"] as? Bool, true)
    }

    @MainActor
    func testLocalFileDisplaysFullyRenderedComparisonResultsAtFullFidelity() async throws {
        let cases: [(CompositionHTMLComparisonMode, String, String)] = [
            (.renderedDifference, "difference", "Difference"),
            (.renderedChangeHighlight, "change-highlight", "Change Highlight"),
        ]

        for (mode, expectedMode, expectedCaption) in cases {
            let html = try CompositionHTMLExporter.html(for: CompositionHTMLDocument(
                title: expectedCaption,
                layout: .comparison(CompositionHTMLComparison(mode: mode)),
                items: [
                    item(title: "Before", stepLabel: "1"),
                    item(title: "After", stepLabel: "2"),
                ],
                renderedDifference: item(
                    title: expectedCaption,
                    stepLabel: "3"
                )
            ))
            let fixture = try LocalHTMLFixture(html: html)
            defer { fixture.remove() }

            let webView = WKWebView(
                frame: CGRect(x: 0, y: 0, width: 1_024, height: 768),
                configuration: browserConfiguration(allowsContentJavaScript: true)
            )
            let browserHost = LocalBrowserHost(webView: webView)
            defer { browserHost.close() }
            let navigation = LocalFileNavigationWaiter()
            try await navigation.load(fixture.url, in: webView)

            let initial = try await evaluateJSON(
                """
                (() => {
                  const comparison = document.querySelector("[data-comparison]");
                  const result = comparison.querySelector(".comparison-difference-rendered");
                  return JSON.stringify({
                    mode: comparison.dataset.comparisonMode,
                    enhanced: document.documentElement.classList.contains("is-enhanced"),
                    imageCount: comparison.querySelectorAll("img").length,
                    loadedImages: Array.from(comparison.querySelectorAll("img")).every(
                      (image) => image.complete && image.naturalWidth === 4
                    ),
                    resultOpacity: getComputedStyle(result).opacity,
                    afterVisibility: getComputedStyle(
                      comparison.querySelector(".comparison-after")
                    ).visibility,
                    resultCaption: result.querySelector("figcaption").textContent.trim(),
                    resultRange: comparison.querySelector("[data-result-range]").value,
                    legacyDifferenceRange: comparison.querySelector("[data-difference-range]") !== null,
                    cspViolations: window.__compositionCSPViolations || []
                  });
                })()
                """,
                in: webView
            )

            XCTAssertEqual(initial["mode"] as? String, expectedMode)
            XCTAssertEqual(initial["enhanced"] as? Bool, true)
            XCTAssertEqual(initial["imageCount"] as? Int, 3)
            XCTAssertEqual(initial["loadedImages"] as? Bool, true)
            XCTAssertEqual(initial["resultOpacity"] as? String, "1")
            XCTAssertEqual(initial["afterVisibility"] as? String, "hidden")
            XCTAssertEqual(initial["resultCaption"] as? String, expectedCaption)
            XCTAssertEqual(initial["resultRange"] as? String, "100")
            XCTAssertEqual(initial["legacyDifferenceRange"] as? Bool, false)
            XCTAssertEqual(initial["cspViolations"] as? [String], [])

            let adjusted = try await evaluateJSON(
                """
                (() => {
                  const range = document.querySelector("[data-result-range]");
                  range.value = "43";
                  range.dispatchEvent(new Event("input", { bubbles: true }));
                  const comparison = document.querySelector("[data-comparison]");
                  return JSON.stringify({
                    className: comparison.className,
                    rangeValue: range.value,
                    comparisonValue: getComputedStyle(comparison)
                      .getPropertyValue("--comparison-value").trim()
                  });
                })()
                """,
                in: webView
            )
            XCTAssertTrue(
                try XCTUnwrap(adjusted["className"] as? String)
                    .contains("comparison-value-43")
            )
            XCTAssertEqual(adjusted["rangeValue"] as? String, "43")
            XCTAssertEqual(adjusted["comparisonValue"] as? String, "0.43")
            let renderedStyle = try await evaluateJSON(
                """
                (() => {
                  const comparison = document.querySelector("[data-comparison]");
                  const result = document.querySelector(
                    ".comparison-difference-rendered"
                  );
                  const opacityRules = Array.from(document.styleSheets)
                    .flatMap((sheet) => Array.from(sheet.cssRules))
                    .filter((rule) =>
                      rule.type === CSSRule.STYLE_RULE &&
                      rule.style.opacity &&
                      result.matches(rule.selectorText)
                    )
                    .map((rule) => rule.cssText);
                  return JSON.stringify({
                    inheritedValue: getComputedStyle(result)
                      .getPropertyValue("--comparison-value").trim(),
                    directSelectorMatches: result.matches(
                      `.${comparison.classList[1]}.comparison-value-43 .comparison-difference-rendered`
                    ),
                    opacityRules
                  });
                })()
                """,
                in: webView
            )
            XCTAssertEqual(renderedStyle["inheritedValue"] as? String, "0.43")
            XCTAssertEqual(renderedStyle["directSelectorMatches"] as? Bool, true)
            XCTAssertTrue(
                try XCTUnwrap(renderedStyle["opacityRules"] as? [String])
                    .contains { $0.contains("opacity: 0.43") },
                "\(renderedStyle)"
            )
        }
    }

    @MainActor
    func testLocalFileWithoutJavaScriptShowsEveryStepAndNoScriptFallback() async throws {
        let html = try CompositionHTMLExporter.html(for: CompositionHTMLDocument(
            title: "Offline steps",
            layout: .steps,
            items: [
                item(title: "First", stepLabel: "A"),
                item(title: "Second", stepLabel: "B"),
                item(title: "Third", stepLabel: "C"),
            ]
        ))
        XCTAssertTrue(
            html.contains(
                "<noscript><p>Use the step links to move through this composition.</p></noscript>"
            )
        )
        let fixture = try LocalHTMLFixture(html: html)
        defer { fixture.remove() }

        let configuration = browserConfiguration(allowsContentJavaScript: false)
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1_024, height: 768),
            configuration: configuration
        )
        let browserHost = LocalBrowserHost(webView: webView)
        defer { browserHost.close() }
        let navigation = LocalFileNavigationWaiter()
        try await navigation.load(fixture.url, in: webView)

        let result = try await evaluateJSON(
            """
            JSON.stringify({
              enhanced: document.documentElement.classList.contains("is-enhanced"),
              hiddenSteps: Array.from(document.querySelectorAll("[data-step]"))
                .filter((step) => step.hidden)
                .length,
              links: Array.from(document.querySelectorAll("[data-step-link]"))
                .map((link) => link.getAttribute("href")),
              listStyles: Array.from(document.querySelectorAll(".step-navigation li"))
                .map((item) => getComputedStyle(item).listStyleType),
              printRules: Array.from(document.styleSheets)
                .flatMap((sheet) => Array.from(sheet.cssRules))
                .filter((rule) => rule.type === CSSRule.MEDIA_RULE && rule.conditionText === "print")
                .map((rule) => rule.cssText)
                .join("\\n")
            })
            """,
            in: webView
        )

        XCTAssertEqual(result["enhanced"] as? Bool, false)
        XCTAssertEqual(result["hiddenSteps"] as? Int, 0)
        XCTAssertEqual(
            result["links"] as? [String],
            ["#step-1", "#step-2", "#step-3"]
        )
        XCTAssertEqual(result["listStyles"] as? [String], ["none", "none", "none"])
        let printRules = try XCTUnwrap(result["printRules"] as? String)
        XCTAssertTrue(printRules.contains(".step-card[hidden]"))
        XCTAssertTrue(printRules.contains("display: block"))
    }

    @MainActor
    private func browserConfiguration(
        allowsContentJavaScript: Bool
    ) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript =
            allowsContentJavaScript
        configuration.userContentController.addUserScript(WKUserScript(
            source: """
            window.__compositionCSPViolations = [];
            document.addEventListener("securitypolicyviolation", (event) => {
              window.__compositionCSPViolations.push(
                `${event.violatedDirective}:${event.blockedURI}`
              );
            });
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        return configuration
    }

    @MainActor
    private func validateGeneratedLocalFile(in browser: String) throws {
        guard ProcessInfo.processInfo.environment[
            "SSS_RUN_EXTERNAL_HTML_BROWSER_TESTS"
        ] == "1" else {
            throw XCTSkip(
                "External browser matrix is opt-in. Set "
                    + "SSS_RUN_EXTERNAL_HTML_BROWSER_TESTS=1 to run \(browser)."
            )
        }

        let html = try CompositionHTMLExporter.html(for: CompositionHTMLDocument(
            title: "External browser matrix",
            layout: .steps,
            items: [
                item(title: "First", stepLabel: "A"),
                item(title: "Second", stepLabel: "B"),
                item(title: "Third", stepLabel: "C"),
            ]
        ))
        let fixture = try LocalHTMLFixture(html: html)
        defer { fixture.remove() }

        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let validator = repository
            .appendingPathComponent("Tools", isDirectory: true)
            .appendingPathComponent("validate-composition-html-browser.py")
        guard FileManager.default.isReadableFile(atPath: validator.path) else {
            XCTFail("Missing external browser validator at \(validator.path)")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            validator.path,
            "--browser",
            browser,
            "--html",
            fixture.url.path,
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let diagnostic = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus == 77 {
            if ProcessInfo.processInfo.environment[
                "SSS_REQUIRE_EXTERNAL_HTML_BROWSERS"
            ] == "1" {
                XCTFail(
                    "\(browser) is required for this release gate:\n\(diagnostic)"
                )
                return
            }
            throw XCTSkip(diagnostic)
        }
        XCTAssertEqual(
            process.terminationStatus,
            0,
            "\(browser) validation failed:\n\(diagnostic)"
        )
        XCTAssertTrue(
            diagnostic.contains(#""result": "passed""#),
            "\(browser) validator did not report a passing result:\n\(diagnostic)"
        )
        XCTAssertTrue(
            diagnostic.contains(#""externalNetworkRequests": 0"#),
            "\(browser) validator observed an external request:\n\(diagnostic)"
        )
    }

    @MainActor
    private func evaluateJSON(
        _ source: String,
        in webView: WKWebView
    ) async throws -> [String: Any] {
        let encoded = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<String, Error>) in
            webView.evaluateJavaScript(source) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let value = value as? String {
                    continuation.resume(returning: value)
                } else {
                    continuation.resume(throwing: LocalHTMLBrowserTestError.invalidJavaScriptResult)
                }
            }
        }
        let object = try JSONSerialization.jsonObject(with: Data(encoded.utf8))
        guard let dictionary = object as? [String: Any] else {
            throw LocalHTMLBrowserTestError.invalidJavaScriptResult
        }
        return dictionary
    }

    private func item(
        title: String,
        caption: String? = nil,
        stepLabel: String
    ) -> CompositionHTMLItem {
        CompositionHTMLItem(
            image: makeSolidImage(
                width: 4,
                height: 3,
                color: PixelSample(red: 80, green: 120, blue: 180, alpha: 255)
            ),
            title: title,
            caption: caption,
            accessibilityLabel: "\(title) screenshot",
            stepLabel: stepLabel
        )
    }
}

@MainActor
private final class LocalFileNavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ url: URL, in webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            webView.navigationDelegate = self
            webView.loadFileURL(
                url,
                allowingReadAccessTo: url.deletingLastPathComponent()
            )
        }
    }

    func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation!
    ) {
        finish(.success(()))
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(.failure(error))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(LocalHTMLBrowserTestError.webContentProcessTerminated))
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else {
            return
        }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

@MainActor
private final class LocalBrowserHost {
    private let window: NSWindow

    init(webView: WKWebView) {
        window = NSWindow(
            contentRect: CGRect(x: -20_000, y: -20_000, width: 1_024, height: 768),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderBack(nil)
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }
}

private struct LocalHTMLFixture {
    let directory: URL
    let url: URL

    init(html: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CompositionHTMLLocalFileBrowserTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        let url = directory.appendingPathComponent("composition.html")
        try Data(html.utf8).write(to: url, options: .atomic)
        self.directory = directory
        self.url = url
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private enum LocalHTMLBrowserTestError: Error {
    case invalidJavaScriptResult
    case webContentProcessTerminated
}
