import CoreGraphics
import Foundation
import XCTest
@testable import SnipSnipSnip

final class AutomationInputBoundaryTests: XCTestCase {
    func testMalformedCLIInputsFailBeforeExecution() {
        let invalid: [[String]] = [
            ["status", "extra"], ["status", "--copy"], ["--json", "status", "--json"],
            ["capture", "fullscreen", "--typo"],
            ["capture", "fullscreen", "--copy", "--output", "/tmp/file.png"],
            ["capture", "fullscreen", "--copy", "--open-editor"],
            ["capture", "fullscreen", "--output", "/tmp/a", "--output", "/tmp/b"],
            ["capture", "region", "--interactive", "--rect", "1,2,3,4"],
            ["capture", "region", "--rect", "1,nope,2,3,4"],
            ["capture", "region", "--rect", "1,,2,3,4"],
            ["capture", "region", "--rect", "nan,2,3,4"],
            ["capture", "fullscreen", "--rect", "1,2,3,4"],
            ["open", "--file", ""], ["open", "--file", "/tmp/a.sss", "extra"],
            ["composition", "layout", "--layout", "grid", "--grid-columns", "1e300"],
            ["composition", "compare", "--mode", "wipe", "--wipe-position", "nan"],
            ["composition", "compare", "--mode", "blink", "--blink-interval", "inf"],
            ["composition", "layout", "--layout", "steps", "--private"],
            ["guide", "pause", "--output", "/tmp/ignored.pdf"],
            ["export", "current", "--overwrite"]
        ]
        for arguments in invalid {
            let result = AutomationCLIParser.parse(arguments)
            XCTAssertNil(result.request, arguments.description)
            XCTAssertEqual(result.exitCode, 64, arguments.description)
        }
    }

    func testCLIFormatCasePrivacyAndUnattendedPolicySurviveParsing() throws {
        for format in AutomationExportFormat.allCases {
            let result = AutomationCLIParser.parse(["export", "current", "--format", format.rawValue.uppercased(), "--output", "/tmp/output.\(format.rawValue)"])
            let request = try XCTUnwrap(result.request)
            XCTAssertEqual(request.interactionPolicy, .never)
            switch request.output {
            case .saveFile(let file), .saveEditableDocument(let file): XCTAssertEqual(file.format, format)
            default: XCTFail("Expected file output")
            }
        }
        let request = try XCTUnwrap(AutomationCLIParser.parse(["repeat-last", "--private", "--copy"]).request)
        XCTAssertTrue(request.privacy.privateCapture)
        XCTAssertEqual(request.source.kind, .commandLine)
        XCTAssertEqual(request.interactionPolicy, .never)
    }

    func testRectangleParserNeverDropsInvalidOrExtraFields() {
        for value in ["1,,2,3,4", "1,bad,2,3,4", ",1,2,3,4", "1,2,3,4,", "nan,2,3,4", "1,2,inf,4", "1,2,3,4,5"] {
            XCTAssertNil(AutomationValueParser.rect(value), value)
        }
        XCTAssertEqual(AutomationValueParser.rect("-10, -20, 30, 40"), CGRect(x: -10, y: -20, width: 30, height: 40))
    }

    func testURLRejectsAmbiguousParametersAndMalformedPresetIdentity() throws {
        for suffix in [
            "presets/run?id=invalid&name=Daily%20Clip",
            "capture/fullscreen?output=clipboard&output=editor",
            "capture/fullscreen?private=true&private=false",
            "capture/fullscreen?private",
            "capture/region?rect=1,bad,2,3,4"
        ] {
            XCTAssertNil(AutomationURLRouter.request(from: try XCTUnwrap(URL(string: "\(AppImportURL.scheme)://v1/" + suffix))), suffix)
        }
    }

    func testMalformedCLIResultsNeverReportSuccess() {
        for value in ["", "not JSON", "{}", "[]", "{\"status\":\"unknown\"}"] {
            XCTAssertEqual(CLIExitCodeMapper.exitCode(for: value), 70, value)
        }
    }
}

extension AutomationInputBoundaryTests {
    @MainActor
    func testUnattendedCaptureDenialAndMissingWindowNeverPresentRecoveryUI() async throws {
        for permissionGranted in [false, true] {
            let suite = "AutomationInputBoundaryTests.\(UUID())"
            let defaults = makeDefaults(named: suite)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: root)
            }
            let permissionService = TestCapturePermissionService(status: CapturePermissionStatus(hasScreenRecording: permissionGranted, hasAccessibility: false))
            let model = retainForTestLifetime(AppModel(defaults: defaults,
                environment: AppEnvironment(defaults: defaults, permissions: permissionService),
                compositionOverrides: AppModelCompositionOverrides(recoveryStore: DocumentRecoveryStore(baseURL: root), captureService: CompositionUITestCaptureService()),
                shouldCheckCompatibilityOnLaunch: false, shouldStartArchiveMaintenance: false))
            let request = try XCTUnwrap(AutomationCLIParser.parse(["capture", "frontmost-window", "--copy"]).request)
            let result = await AppAutomationService(host: model.automation).perform(request)
            XCTAssertEqual(result.error?.code, permissionGranted ? .targetUnavailable : .permissionDenied)
            XCTAssertNil(model.capture.captureRecovery)
            XCTAssertNil(model.permissions.activePermissionRequest)
            XCTAssertNil(model.permissions.permissionSetupGuide)
            XCTAssertFalse(model.capture.isWorking)
            let preset = CapturePreset(name: "Saved window", target: .window(SavedWindowTarget(window: makeCaptureWindow())), options: CaptureRunOptions())
            model.capture.capturePresets = [preset]
            let presetRequest = try XCTUnwrap(AutomationCLIParser.parse(["presets", "run", "--id", preset.id.uuidString, "--copy"]).request)
            let presetResult = await AppAutomationService(host: model.automation).perform(presetRequest)
            XCTAssertEqual(presetResult.error?.code, permissionGranted ? .targetUnavailable : .permissionDenied)
            XCTAssertNil(model.permissions.activePermissionRequest)
        }
    }

    func testPublicDiagnosticSummariesOmitContentPathsAndNames() {
        let secret = "private-customer-document"
        let path = URL(fileURLWithPath: "/tmp/\(secret).sss")
        let request = AutomationRequest(source: .init(kind: .commandLine, caller: secret),
            command: .openDocument(.init(url: path)), output: .saveFile(.init(url: path, format: .png)))
        XCTAssertFalse(request.debugSummary.contains(secret))
        XCTAssertFalse(AutomationCommand.runPreset(.init(name: secret)).debugSummary.contains(secret))
        let result = AutomationResultEnvelope.failure(requestID: UUID(), code: .outputFailed, message: secret)
        XCTAssertFalse(result.debugSummary.contains(secret))
        XCTAssertFalse(AutomationOutputResult(kind: .savedFile, url: path, format: .png).debugSummary.contains(secret))
    }
}

extension AutomationInputBoundaryTests {
    func testEveryErrorCodeHasAnIntentionalCLIExitStatus() {
        let cases: [(String, Int32)] = [
            ("invalidRequest", 64), ("busy", 69), ("permissionDenied", 77),
            ("confirmationRequired", 77), ("userCancelled", 130),
            ("targetUnavailable", 69), ("featureUnavailable", 69), ("proFeatureRequired", 69),
            ("unsupportedOutput", 74), ("outputFailed", 74), ("internalError", 70),
            ("noActiveComposition", 69), ("compositionItemNotFound", 69),
            ("compositionRequiresMultipleItems", 69), ("incompatibleCompositionItems", 69),
            ("unsupportedComparisonOutput", 74), ("oversizedOutput", 74), ("staleDestination", 69),
            ("noActiveGuide", 69), ("guideAlreadyActive", 69), ("guideHasNoSteps", 69),
            ("guideSourceMediaUnavailable", 69), ("guideFinalizationFailed", 74)
        ]
        for (code, expected) in cases {
            XCTAssertNotNil(AutomationErrorCode(rawValue: code))
            XCTAssertEqual(CLIExitCodeMapper.exitCode(for: "{\"status\":\"failed\",\"error\":{\"code\":\"\(code)\"}}"), expected, code)
        }
    }
}

extension AutomationInputBoundaryTests {
    @MainActor
    func testInteractiveCaptureKeepsItsPrivateOutputUntilSelectionCompletes() async throws {
        let suite = "AutomationInputBoundaryTests.interactive.\(UUID())"
        let defaults = makeDefaults(named: suite)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let pasteboard = TestPasteboardService()
        pasteboard.setString("Unchanged until selection", forType: .string)
        let model = retainForTestLifetime(AppModel(defaults: defaults,
            environment: makePasteboardTestEnvironment(defaults: defaults, pasteboard: pasteboard),
            recoveryStore: DocumentRecoveryStore(baseURL: root),
            shouldCheckCompatibilityOnLaunch: false, shouldStartArchiveMaintenance: false))
        let request = try XCTUnwrap(AutomationCLIParser.parse(["capture", "window", "--interactive", "--private", "--copy"]).request)
        model.capture.prepareInteractiveAutomationOutput(request, runOptions: CaptureRunOptions(includesCursor: true))
        let context = model.capture.activeCaptureContext
        XCTAssertTrue(context.oneShotOptions?.privateCapture == true)
        XCTAssertTrue(context.oneShotOptions?.includesCursor == true)
        XCTAssertEqual(pasteboard.string(forType: .string), "Unchanged until selection")
        try model.capture.completeCapture(makeCapturedScreenshot(), request: .fullscreen,
            isPrivateCapture: true, shouldAttemptUIMapCapture: false, completionContext: context)
        await waitUntil { pasteboard.data(forType: .png) != nil }
        XCTAssertNotNil(pasteboard.data(forType: .png))
        XCTAssertTrue(model.documents.editorController?.isPrivateDocument == true)
        XCTAssertNil(model.capture.activeCaptureContext.automationRequest)
    }
}

extension AutomationInputBoundaryTests {
    func testNumericLimitsAcrossCLIAndURLAdapters() throws {
        let fields: [(String, String, String, [String])] = [
            ("layout", "--grid-columns", "gridColumns", ["0", "-1", "201", "1.5", "nan", "inf", "1e300"]),
            ("layout", "--target-aspect-ratio", "targetAspectRatio", ["0", "-1", "1001", "nan", "inf"]),
            ("layout", "--step-start-index", "stepStartIndex", ["-1", "1000001", "1.5", "nan", "1e300"]),
            ("compare", "--wipe-position", "wipePosition", ["-0.1", "1.1", "nan", "inf", "-inf"]),
            ("compare", "--overlay-opacity", "overlayOpacity", ["-0.1", "1.1", "nan", "inf"]),
            ("compare", "--difference-intensity", "differenceIntensity", ["-0.1", "1.1", "nan", "inf"]),
            ("compare", "--highlight-threshold", "highlightThreshold", ["-0.1", "1.1", "nan", "inf"]),
            ("compare", "--blink-interval", "blinkInterval", ["0", "0.01", "61", "nan", "inf"])
        ]
        for (action, flag, key, values) in fields {
            let mode = action == "layout" ? ["--layout", "steps"] : ["--mode", "wipe"]
            let query = action == "layout" ? "layout=steps" : "mode=wipe"
            for value in values {
                XCTAssertEqual(AutomationCLIParser.parse(["composition", action] + mode + [flag, value]).exitCode, 64, flag + " " + value)
                let url = try XCTUnwrap(URL(string: "\(AppImportURL.scheme)://v1/composition/\(action)?\(query)&\(key)=\(value)"))
                if let request = AutomationURLRouter.request(from: url) {
                    XCTAssertEqual(request.validationError?.code, .invalidRequest, key + " " + value)
                }
            }
        }
        XCTAssertEqual(AutomationCLIParser.parse(["composition", "compare", "--mode", "wipe", "--primary-label", "", "--secondary-label", ""]).exitCode, 0)
        for value in ["0", "0.5", "1"] {
            XCTAssertEqual(AutomationCLIParser.parse(["composition", "compare", "--mode", "wipe", "--wipe-position", value]).exitCode, 0)
        }
    }
}

extension AutomationInputBoundaryTests {
    @MainActor
    func testCancelledInteractiveAutomationCannotCopyTheNextCapture() async throws {
        let suite = "AutomationInputBoundaryTests.cancelled.\(UUID())"
        let defaults = makeDefaults(named: suite)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let pasteboard = TestPasteboardService()
        pasteboard.setString("Keep clipboard", forType: .string)
        let model = retainForTestLifetime(AppModel(defaults: defaults,
            environment: makePasteboardTestEnvironment(defaults: defaults, pasteboard: pasteboard),
            recoveryStore: DocumentRecoveryStore(baseURL: root),
            shouldCheckCompatibilityOnLaunch: false, shouldStartArchiveMaintenance: false))
        let request = try XCTUnwrap(AutomationCLIParser.parse(["capture", "window", "--interactive", "--private", "--copy"]).request)
        model.capture.prepareInteractiveAutomationOutput(request, runOptions: CaptureRunOptions())
        model.capture.resetPreparedCaptureContext(ifMatching: model.capture.activeCaptureContext)
        XCTAssertNil(model.capture.activeCaptureContext.automationRequest)
        XCTAssertNil(model.capture.activeCaptureContext.oneShotOptions)
        try model.capture.completeCapture(makeCapturedScreenshot(), request: .fullscreen,
            isPrivateCapture: false, shouldAttemptUIMapCapture: false, allowsCapturePreview: false)
        await Task.yield()
        XCTAssertEqual(pasteboard.string(forType: .string), "Keep clipboard")
        XCTAssertNil(pasteboard.data(forType: .png))
    }
}
