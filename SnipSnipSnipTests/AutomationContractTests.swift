import AppIntents
import CoreGraphics
import XCTest
@testable import SnipSnipSnip

final class AutomationContractTests: XCTestCase {
    func testAutomationRequestRoundTripsThroughCodable() throws {
        let requestID = UUID()
        let outputURL = URL(fileURLWithPath: "/tmp/SnipSnipSnip-AutomationContractTests.png")
        let request = AutomationRequest(
            id: requestID,
            source: AutomationSource(kind: .appIntent, caller: "unit-test"),
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
        XCTAssertEqual(decoded.source.kind, .appIntent)
    }

    func testAutomationResultEnvelopeRoundTripsThroughCodable() throws {
        let requestID = UUID()
        let capabilities = AutomationCapabilities(
            supportsURLScheme: true,
            supportsAppleScript: true,
            supportsCLI: true,
            supportsAppIntents: true,
            supportsCapturePresets: true,
            supportsPrivateCapture: true,
            supportsUIMap: false,
            supportsScrollingCapture: false,
            supportsConnectedDeviceCapture: false,
            supportsCurrentEditorExport: true,
            supportsGuide: false
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

    func testSandboxedAutomationFileDestinationPolicyKeepsUnattendedOutputInDownloads() throws {
        let downloads = URL(fileURLWithPath: "/Users/example/Downloads", isDirectory: true)
        let policy = AutomationFileDestinationPolicy(
            restrictsUnattendedOutputToDownloads: true,
            downloadsDirectory: downloads
        )
        let valid = downloads.appendingPathComponent("Captures/example.png")

        XCTAssertEqual(try policy.validate(valid), valid.standardizedFileURL)

        for invalid in [
            URL(fileURLWithPath: "/Users/example/Desktop/example.png"),
            URL(fileURLWithPath: "/Users/example/Downloads/../Desktop/example.png"),
            downloads,
        ] {
            XCTAssertThrowsError(try policy.validate(invalid)) { error in
                XCTAssertEqual((error as? AutomationExecutionError)?.code, .permissionDenied)
            }
        }

        let unrestricted = AutomationFileDestinationPolicy(
            restrictsUnattendedOutputToDownloads: false,
            downloadsDirectory: nil
        )
        let desktop = URL(fileURLWithPath: "/Users/example/Desktop/example.png")
        XCTAssertEqual(try unrestricted.validate(desktop), desktop.standardizedFileURL)
    }

    func testAppIntentRequestFactoryMapsExistingAutomationCommands() {
        let presetID = UUID()
        let outputURL = URL(fileURLWithPath: "/tmp/SnipSnipSnip-AppIntentTests.png")
        let documentURL = URL(fileURLWithPath: "/tmp/SnipSnipSnip-AppIntentTests.sss")

        let status = AutomationIntentRequestFactory.request(
            caller: "StatusTest",
            command: .status,
            output: .none
        )
        XCTAssertEqual(status.source.kind, .appIntent)
        XCTAssertEqual(status.command, .status)
        XCTAssertEqual(status.output, .none)

        let listPresets = AutomationIntentRequestFactory.request(
            caller: "ListTest",
            command: .listPresets,
            output: .none
        )
        XCTAssertEqual(listPresets.command, .listPresets)

        let presetOutput = AutomationIntentRequestFactory.output(
            destination: .file,
            filePath: documentURL.path,
            format: .sss,
            overwrite: true
        )
        let runPreset = AutomationIntentRequestFactory.request(
            caller: "PresetTest",
            command: .runPreset(RunPresetAutomationCommand(id: presetID)),
            interactionPolicy: .promptIfNeeded,
            privacy: AutomationIntentRequestFactory.privacy(privateCapture: true),
            output: presetOutput
        )
        XCTAssertEqual(runPreset.source.kind, .appIntent)
        XCTAssertEqual(runPreset.privacy.privateCapture, true)
        XCTAssertEqual(runPreset.interactionPolicy, .promptIfNeeded)
        XCTAssertEqual(runPreset.output, .saveEditableDocument(AutomationFileOutput(url: documentURL, format: .sss, overwrite: true)))

        let captureOptions = AutomationIntentRequestFactory.captureOptions(
            delay: .threeSeconds,
            cursor: .include,
            windowUIMap: .enabled
        )
        XCTAssertEqual(captureOptions.delay, .seconds(3))
        XCTAssertEqual(captureOptions.includesCursor, true)
        XCTAssertEqual(captureOptions.windowUIMap, .enabled)

        let fullscreen = AutomationIntentRequestFactory.request(
            caller: "FullscreenTest",
            command: .capture(CaptureAutomationCommand(
                target: .fullscreen(FullscreenCaptureTarget(displayMode: .current)),
                options: captureOptions
            )),
            interactionPolicy: .promptIfNeeded,
            output: .copyRenderedImage
        )
        guard case .capture(let fullscreenCommand) = fullscreen.command,
              case .fullscreen(let fullscreenTarget) = fullscreenCommand.target else {
            return XCTFail("Expected fullscreen capture command.")
        }
        XCTAssertEqual(fullscreenTarget.displayMode, .current)
        XCTAssertEqual(fullscreen.output, .copyRenderedImage)

        let frontmostWindow = AutomationIntentRequestFactory.request(
            caller: "FrontmostTest",
            command: .capture(CaptureAutomationCommand(target: .frontmostWindow, options: captureOptions)),
            interactionPolicy: .promptIfNeeded,
            output: .openEditor
        )
        XCTAssertEqual(frontmostWindow.command, .capture(CaptureAutomationCommand(target: .frontmostWindow, options: captureOptions)))

        let fixedRegion = AutomationIntentRequestFactory.regionTarget(
            interactive: false,
            x: 10,
            y: 20,
            width: 300,
            height: 200
        )
        XCTAssertEqual(fixedRegion.policy, .promptIfNeeded)
        XCTAssertEqual(fixedRegion.target, .region(RegionCaptureSelector(rect: CGRect(x: 10, y: 20, width: 300, height: 200))))

        let interactiveRegion = AutomationIntentRequestFactory.regionTarget(
            interactive: true,
            x: nil,
            y: nil,
            width: nil,
            height: nil
        )
        XCTAssertEqual(interactiveRegion.policy, .requireUserSelection)
        XCTAssertEqual(interactiveRegion.target, .interactiveRegion)

        let window = AutomationIntentRequestFactory.request(
            caller: "WindowTest",
            command: .capture(CaptureAutomationCommand(target: .interactiveWindow, options: captureOptions)),
            interactionPolicy: .requireUserSelection,
            output: .floatReference
        )
        XCTAssertEqual(window.interactionPolicy, .requireUserSelection)
        XCTAssertTrue(window.requiresAppIntentForeground)

        let repeatLast = AutomationIntentRequestFactory.request(
            caller: "RepeatTest",
            command: .repeatLastCapture,
            interactionPolicy: .promptIfNeeded,
            output: .openEditor
        )
        XCTAssertEqual(repeatLast.command, .repeatLastCapture)
        XCTAssertTrue(repeatLast.requiresAppIntentForeground)

        let openDocument = AutomationIntentRequestFactory.request(
            caller: "OpenTest",
            command: .openDocument(OpenDocumentAutomationCommand(url: documentURL)),
            interactionPolicy: .promptIfNeeded,
            output: .openEditor
        )
        XCTAssertEqual(openDocument.command, .openDocument(OpenDocumentAutomationCommand(url: documentURL)))

        let exportCurrent = AutomationIntentRequestFactory.request(
            caller: "ExportTest",
            command: .exportCurrent(ExportCurrentAutomationCommand(format: .png)),
            interactionPolicy: .promptIfNeeded,
            output: AutomationIntentRequestFactory.output(
                destination: .file,
                filePath: outputURL.path,
                format: .png,
                overwrite: true
            )
        )
        XCTAssertEqual(exportCurrent.output, .saveFile(AutomationFileOutput(url: outputURL, format: .png, overwrite: true)))

        XCTAssertEqual(AutomationIntentRequestFactory.fileURL(from: outputURL.path), outputURL)
        XCTAssertEqual(AutomationIntentRequestFactory.fileURL(from: outputURL.absoluteString), outputURL)
    }

    @MainActor
    func testCaptureFullscreenAppIntentMapsFileOutputToAutomationSaveFile() {
        let intent = CaptureFullscreenIntent()
        let outputURL = URL(fileURLWithPath: "/Users/jmcasler/Downloads/snip.png")
        intent.display = .all
        intent.output = .file
        intent.outputFile = outputURL.path
        intent.format = .png
        intent.overwrite = true
        intent.privateCapture = true
        intent.delay = .immediate
        intent.cursor = .exclude

        let request = intent.automationRequest()

        XCTAssertEqual(request.source.kind, .appIntent)
        XCTAssertEqual(request.output, .saveFile(AutomationFileOutput(url: outputURL, format: .png, overwrite: true)))
        XCTAssertEqual(request.privacy.privateCapture, true)
        XCTAssertFalse(request.requiresAppIntentForeground)
        guard case .capture(let command) = request.command,
              case .fullscreen(let target) = command.target else {
            return XCTFail("Expected fullscreen capture command.")
        }
        XCTAssertEqual(target.displayMode, .all)
        XCTAssertEqual(command.options.delay, .immediate)
        XCTAssertEqual(command.options.includesCursor, false)
    }

    func testAppIntentRequestFactoryKeepsValidationFailuresRepresentable() {
        let missingFileOutput = AutomationIntentRequestFactory.output(
            destination: .file,
            filePath: nil,
            format: .png,
            overwrite: false
        )
        let missingFileRequest = AutomationIntentRequestFactory.request(
            caller: "MissingFileTest",
            command: .capture(CaptureAutomationCommand(target: .fullscreen(FullscreenCaptureTarget()))),
            interactionPolicy: .promptIfNeeded,
            output: missingFileOutput
        )
        XCTAssertEqual(missingFileRequest.validationError?.code, .invalidRequest)

        let partialRegion = AutomationIntentRequestFactory.regionTarget(
            interactive: false,
            x: 10,
            y: 20,
            width: nil,
            height: 200
        )
        let partialRegionRequest = AutomationIntentRequestFactory.request(
            caller: "PartialRegionTest",
            command: .capture(CaptureAutomationCommand(target: partialRegion.target)),
            interactionPolicy: partialRegion.policy
        )
        XCTAssertEqual(partialRegionRequest.validationError?.code, .invalidRequest)

        let unsupportedExport = AutomationIntentRequestFactory.request(
            caller: "UnsupportedExportTest",
            command: .exportCurrent(ExportCurrentAutomationCommand(format: .sss)),
            interactionPolicy: .promptIfNeeded,
            output: .saveEditableDocument(AutomationFileOutput(url: URL(fileURLWithPath: "/tmp/current.sss"), format: .sss))
        )
        XCTAssertEqual(unsupportedExport.validationError?.code, .invalidRequest)
    }

    func testCapturePresetEntityQueryUsesAutomationIntentClient() async throws {
        let presetID = UUID()
        let preset = AutomationPresetSummary(
            id: presetID,
            name: "Daily Clip",
            target: "fullscreen",
            targetLabel: "Fullscreen",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let client = AutomationIntentClient(
            performRequest: { request in
                .success(requestID: request.id, payload: AutomationPayload.none, outputs: [.init(kind: .none)])
            },
            capabilitiesRequest: { requestID in
                .success(requestID: requestID, payload: AutomationPayload.none, outputs: [.init(kind: .none)])
            },
            listCapturePresetsRequest: { requestID in
                .success(requestID: requestID, payload: .presets([preset]), outputs: [.init(kind: .none)])
            }
        )
        let query = CapturePresetQuery(client: client)

        let suggested = try await query.suggestedEntities()
        XCTAssertEqual(suggested, [
            CapturePresetEntity(id: presetID, name: "Daily Clip", target: "fullscreen", targetLabel: "Fullscreen")
        ])

        let resolved = try await query.entities(for: [presetID])
        XCTAssertEqual(resolved.map(\.id), [presetID])
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
            ["guide", "start", "--target", "window"],
            ["guide", "start", "--target", "app", "--private"],
            ["guide", "start", "--target", "region"],
            ["guide", "start", "--target", "display"],
            ["guide", "pause"],
            ["guide", "resume"],
            ["guide", "add-step"],
            ["guide", "stop"],
            ["guide", "export", "--format", "pdf"],
            ["guide", "export", "--format", "gif"],
            ["guide", "export", "--format", "apng"],
            ["guide", "export", "--format", "mp4-full"],
            ["guide", "export", "--format", "mp4-highlights"],
            ["guide", "export", "--format", "mp4-slideshow"],
            ["guide", "export", "--format", "images"],
            ["guide", "export", "--format", "zip"],
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

    func testBundledCLIImplementsDocumentedGuideCommands() throws {
        let text = try String(
            contentsOf: repoRoot().appendingPathComponent("SnipSnipSnipCLI/main.swift"),
            encoding: .utf8
        )

        for fragment in [
            "case \"guide\":",
            "\"start\"",
            "\"pause\"",
            "\"resume\"",
            "\"add-step\"",
            "\"stop\"",
            "\"export\"",
            "appleScriptCommand(\"guide\"",
        ] {
            XCTAssertTrue(text.contains(fragment), "Bundled CLI is missing Guide support for \(fragment).")
        }
    }

    func testBundledCLIHasSandboxedAccessToTheAppsAutomationCommands() throws {
        let scriptingDefinition = try String(
            contentsOf: repoRoot().appendingPathComponent("SnipSnipSnip/Automation/SnipSnipSnipAutomation.sdef"),
            encoding: .utf8
        )
        let entitlements = try String(
            contentsOf: repoRoot().appendingPathComponent("SnipSnipSnipCLI/SnipSnipSnipCLI.entitlements"),
            encoding: .utf8
        )
        let info = try String(
            contentsOf: repoRoot().appendingPathComponent("SnipSnipSnipCLI/Info.plist"),
            encoding: .utf8
        )

        XCTAssertEqual(
            scriptingDefinition.components(separatedBy: "com.oontz.SnipSnipSnip.automation").count - 1,
            11,
            "Every exposed command must belong to the CLI's narrow scripting access group."
        )
        XCTAssertTrue(entitlements.contains("com.apple.security.scripting-targets"))
        XCTAssertTrue(entitlements.contains("com.oontz.SnipSnipSnip.automation"))
        XCTAssertTrue(info.contains("NSAppleEventsUsageDescription"))
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
            "export current screenshot",
            "guide"
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
        XCTAssertTrue(plan.localizedCaseInsensitiveContains("App Intents"))
        XCTAssertTrue(readme.localizedCaseInsensitiveContains("App Intents"))
        XCTAssertTrue(readme.contains("\"supportsAppIntents\": true"))
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
            "13-repeat-last-to-editor",
            "17-start-guide-window",
            "18-pause-guide",
            "19-resume-guide",
            "20-add-guide-step",
            "21-stop-guide",
            "22-export-guide-pdf"
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
