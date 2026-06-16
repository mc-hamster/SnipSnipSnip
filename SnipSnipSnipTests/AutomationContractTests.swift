import CoreGraphics
import XCTest
@testable import SnipSnipSnip

final class AutomationContractTests: XCTestCase {
    func testAutomationRequestRoundTripsThroughCodable() throws {
        let requestID = UUID()
        let outputURL = URL(fileURLWithPath: "/tmp/SnipSnipSnip-AutomationContractTests.png")
        let request = AutomationRequest(
            id: requestID,
            source: AutomationSource(kind: .commandLine, caller: "unit-test"),
            command: .capture(CaptureAutomationCommand(
                target: .region(RegionCaptureSelector(rect: CGRect(x: 10, y: 20, width: 300, height: 200))),
                options: CaptureAutomationOptions(delay: .seconds(3), includesCursor: true, windowUIMap: .disabled)
            )),
            interactionPolicy: .never,
            privacy: AutomationPrivacyOptions(privateCapture: true),
            output: .saveFile(AutomationFileOutput(url: outputURL, format: .png, overwrite: true))
        )

        let data = try AutomationJSON.encoder.encode(request)
        let decoded = try AutomationJSON.decoder.decode(AutomationRequest.self, from: data)

        XCTAssertEqual(decoded, request)
    }

    func testAutomationResultEnvelopeRoundTripsThroughCodable() throws {
        let requestID = UUID()
        let capabilities = AutomationCapabilities(
            supportsURLScheme: true,
            supportsAppleScript: true,
            supportsCLI: true,
            supportsCapturePresets: true,
            supportsPrivateCapture: true,
            supportsUIMap: false,
            supportsScrollingCapture: false,
            supportsConnectedDeviceCapture: false,
            supportsCurrentEditorExport: true
        )
        let preflight = AutomationPermissionPreflight(
            capabilities: capabilities,
            permissions: AutomationPermissionSummary(hasScreenRecording: true, hasAccessibility: false, hasMicrophone: false)
        )
        let success = AutomationResultEnvelope.success(
            requestID: requestID,
            payload: .preflight(preflight),
            outputs: [.init(kind: .none)]
        )

        let successData = try AutomationJSON.encoder.encode(success)
        let decodedSuccess = try AutomationJSON.decoder.decode(AutomationResultEnvelope.self, from: successData)

        XCTAssertEqual(decodedSuccess, success)
        XCTAssertTrue(preflight.isCaptureReady)

        let failure = AutomationResultEnvelope.failure(
            requestID: requestID,
            code: .confirmationRequired,
            message: "Editable .sss output with redactions requires user confirmation.",
            warnings: [AutomationWarning(code: "redaction", message: "Use rendered output for irreversible redactions.")]
        )

        let data = try AutomationJSON.encoder.encode(failure)
        let decoded = try AutomationJSON.decoder.decode(AutomationResultEnvelope.self, from: data)

        XCTAssertEqual(decoded, failure)
    }

    func testCommandValidationRejectsUnsupportedShapes() {
        let source = AutomationSource(kind: .commandLine)

        let missingPreset = AutomationRequest(source: source, command: .runPreset(RunPresetAutomationCommand()))
        XCTAssertEqual(missingPreset.validationError?.code, .invalidRequest)

        let invalidRegion = AutomationRequest(
            source: source,
            command: .capture(CaptureAutomationCommand(target: .region(RegionCaptureSelector(rect: CGRect(x: 0, y: 0, width: 1, height: 1)))))
        )
        XCTAssertEqual(invalidRegion.validationError?.code, .invalidRequest)

        let interactiveWithoutInteraction = AutomationRequest(
            source: source,
            command: .capture(CaptureAutomationCommand(target: .interactiveWindow)),
            interactionPolicy: .never
        )
        XCTAssertEqual(interactiveWithoutInteraction.validationError?.code, .invalidRequest)

        let unsupportedDelay = AutomationRequest(
            source: source,
            command: .capture(CaptureAutomationCommand(
                target: .fullscreen(FullscreenCaptureTarget()),
                options: CaptureAutomationOptions(delay: .seconds(2))
            ))
        )
        XCTAssertEqual(unsupportedDelay.validationError?.code, .invalidRequest)
    }

    func testOutputValidationKeepsEditableRedactionGuardRepresentable() {
        let source = AutomationSource(kind: .commandLine)
        let editableURL = URL(fileURLWithPath: "/tmp/SnipSnipSnip-AutomationContractTests.sss")
        let editableOutput = AutomationOutput.saveEditableDocument(AutomationFileOutput(url: editableURL, format: .sss))
        let request = AutomationRequest(
            source: source,
            command: .capture(CaptureAutomationCommand(target: .fullscreen(FullscreenCaptureTarget()))),
            interactionPolicy: .never,
            output: editableOutput
        )

        XCTAssertNil(request.validationError)

        let error = AutomationError(
            code: .confirmationRequired,
            message: "Editable .sss output with redactions requires user confirmation."
        )
        XCTAssertEqual(error.code.rawValue, "confirmationRequired")
    }

    func testURLRouterParsesEveryV1RouteAndPreservesPasteboardImportRoute() async throws {
        assertRoute("snipsnipsnip://v1/status") { XCTAssertEqual($0.command, .status) }
        assertRoute("snipsnipsnip://v1/presets/run?id=00000000-0000-0000-0000-000000000001&output=editor") {
            guard case .runPreset(let command) = $0.command else {
                return XCTFail("Expected runPreset command.")
            }
            XCTAssertEqual(command.id?.uuidString, "00000000-0000-0000-0000-000000000001")
            XCTAssertEqual($0.output, .openEditor)
        }
        assertRoute("snipsnipsnip://v1/presets/run?name=Daily%20Clip&output=clipboard") {
            guard case .runPreset(let command) = $0.command else {
                return XCTFail("Expected runPreset command.")
            }
            XCTAssertEqual(command.name, "Daily Clip")
            XCTAssertEqual($0.output, .copyRenderedImage)
        }
        assertRoute("snipsnipsnip://v1/capture/fullscreen?display=current&output=clipboard") {
            guard case .capture(let command) = $0.command,
                  case .fullscreen(let target) = command.target else {
                return XCTFail("Expected fullscreen capture command.")
            }
            XCTAssertEqual(target.displayMode, .current)
            XCTAssertEqual($0.output, .copyRenderedImage)
        }
        assertRoute("snipsnipsnip://v1/capture/frontmost-window?output=editor") {
            guard case .capture(let command) = $0.command else {
                return XCTFail("Expected capture command.")
            }
            XCTAssertEqual(command.target, .frontmostWindow)
        }
        assertRoute("snipsnipsnip://v1/capture/region?rect=10,20,300,200&output=editor") {
            guard case .capture(let command) = $0.command,
                  case .region(let selector) = command.target else {
                return XCTFail("Expected region capture command.")
            }
            XCTAssertEqual(selector.rect, CGRect(x: 10, y: 20, width: 300, height: 200))
            XCTAssertEqual($0.output, .openEditor)
        }
        assertRoute("snipsnipsnip://v1/capture/window?output=clipboard") {
            guard case .capture(let command) = $0.command else {
                return XCTFail("Expected capture command.")
            }
            XCTAssertEqual(command.target, .interactiveWindow)
            XCTAssertEqual($0.interactionPolicy, .requireUserSelection)
        }
        assertRoute("snipsnipsnip://v1/repeat-last?output=editor") {
            XCTAssertEqual($0.command, .repeatLastCapture)
        }

        let pasteboardURL = try XCTUnwrap(URL(string: "snipsnipsnip://import-pasteboard?name=com.apple.pasteboard.general&source=Share"))
        let pasteboardName = await MainActor.run {
            AppImportURL.pasteboardImportRequest(from: pasteboardURL)?.pasteboardName
        }
        XCTAssertEqual(pasteboardName, "com.apple.pasteboard.general")
        XCTAssertNil(AutomationURLRouter.request(from: pasteboardURL))
    }

    func testCLIParserAcceptsDocumentedCommandShapes() throws {
        let sampleCommands: [[String]] = [
            ["--json", "status"],
            ["presets", "list"],
            ["presets", "run", "--id", "00000000-0000-0000-0000-000000000001", "--open-editor"],
            ["presets", "run", "--name", "Daily Clip", "--copy"],
            ["presets", "run", "--id", "00000000-0000-0000-0000-000000000001", "--output", "/tmp/capture.png", "--format", "png", "--overwrite"],
            ["capture", "fullscreen", "--display", "current", "--copy"],
            ["capture", "fullscreen", "--output", "/tmp/fullscreen.png", "--format", "png", "--overwrite"],
            ["capture", "frontmost-window", "--open-editor"],
            ["capture", "region", "--rect", "10,20,300,200", "--open-editor"],
            ["capture", "region", "--rect", "10,20,300,200", "--output", "/tmp/region.png", "--format", "png", "--overwrite"],
            ["capture", "region", "--interactive", "--open-editor"],
            ["capture", "window", "--interactive", "--copy"],
            ["repeat-last", "--json", "--open-editor"],
            ["export", "current", "--output", "/tmp/current.png", "--format", "png", "--overwrite"],
            ["capture", "fullscreen", "--private", "--output", "/tmp/private.png", "--format", "png", "--overwrite"],
            ["open", "--file", "/tmp/document.sss", "--output", "/tmp/document.png", "--format", "png", "--overwrite"]
        ]

        for arguments in sampleCommands {
            let result = AutomationCLIParser.parse(arguments)
            XCTAssertEqual(result.exitCode, 0, arguments.joined(separator: " "))
            XCTAssertNotNil(result.request, arguments.joined(separator: " "))
        }
    }

    func testScriptingDictionaryContainsDocumentedCommands() throws {
        let text = try String(
            contentsOf: repoRoot().appendingPathComponent("SnipSnipSnip/Automation/SnipSnipSnipAutomation.sdef"),
            encoding: .utf8
        )
        let commands = [
            "automation status",
            "list capture presets",
            "run capture preset",
            "capture fullscreen",
            "capture frontmost window",
            "capture region",
            "capture window",
            "repeat last capture",
            "open snip document",
            "export current screenshot"
        ]

        for command in commands {
            XCTAssertTrue(text.contains("command name=\"\(command)\""), command)
        }
    }

    func testAutomationDocsMentionSampleMaintenanceRequirement() throws {
        let plan = try String(contentsOf: repoRoot().appendingPathComponent("Docs/AutomationServicePlan.md"), encoding: .utf8)
        let readme = try String(contentsOf: repoRoot().appendingPathComponent("Docs/Automation/README.md"), encoding: .utf8)
        let samplesReadme = try String(contentsOf: repoRoot().appendingPathComponent("Docs/Automation/SampleScripts/README.md"), encoding: .utf8)

        for text in [plan, readme, samplesReadme] {
            XCTAssertTrue(text.localizedCaseInsensitiveContains("sample"))
            XCTAssertTrue(text.localizedCaseInsensitiveContains("maintain"))
        }
    }

    func testAutomationSampleFilenamesKeepProcedureParity() throws {
        let scriptsRoot = repoRoot().appendingPathComponent("Docs/Automation/SampleScripts")
        let cliBasenames = try sampleBasenames(in: scriptsRoot.appendingPathComponent("cli"), extension: "sh")
        let appleScriptBasenames = try sampleBasenames(in: scriptsRoot.appendingPathComponent("applescript"), extension: "applescript")
        let urlBasenames = try sampleBasenames(in: scriptsRoot.appendingPathComponent("url"), extension: "sh")

        XCTAssertEqual(cliBasenames, appleScriptBasenames)
        XCTAssertEqual(urlBasenames, [
            "01-status",
            "03-run-preset-by-id-to-editor",
            "04-run-preset-by-name-to-clipboard",
            "06-capture-fullscreen-to-clipboard",
            "08-capture-frontmost-window-to-editor",
            "09-capture-fixed-region-to-editor",
            "11-capture-interactive-region-to-editor",
            "12-capture-interactive-window-to-clipboard",
            "13-repeat-last-to-editor"
        ])
        XCTAssertTrue(urlBasenames.isSubset(of: cliBasenames))
    }

    private func assertRoute(
        _ string: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        assertions: (AutomationRequest) -> Void
    ) {
        guard let url = URL(string: string),
              let request = AutomationURLRouter.request(from: url) else {
            return XCTFail("Expected route to parse: \(string)", file: file, line: line)
        }

        assertions(request)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sampleBasenames(in directory: URL, extension fileExtension: String) throws -> Set<String> {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return Set(
            urls
                .filter { $0.pathExtension == fileExtension }
                .map { $0.deletingPathExtension().lastPathComponent }
        )
    }
}
