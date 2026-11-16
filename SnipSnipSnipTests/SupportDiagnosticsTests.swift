import XCTest
@testable import SnipSnipSnip

@MainActor
final class SupportDiagnosticsTests: XCTestCase {
    func testBuilderIncludesExpectedSafeSummaries() throws {
        let model = makeModel()
        let text = Annotation.makeText(at: CGPoint(x: 12, y: 16))
            .updatingText("Customer account: 12345")
        let rectangle = Annotation.makeRectangle(in: CGRect(x: 20, y: 24, width: 120, height: 80))
        let controller = EditorController(capture: makeCapturedScreenshot())
        controller.addAnnotation(text)
        controller.addAnnotation(rectangle)
        controller.select(annotationIDs: [text.id])
        model.editorController = controller
        model.permissionStatus = CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: false)
        model.archiveSizeBytes = 42
        model.connectedDevices = [
            ConnectedAppleDevice(id: "redacted-device-id", name: "Jorge's iPhone", modelName: "iPhone")
        ]
        model.connectedDeviceEmptyStateMessage = "Unlock /Users/example/Device Log and refresh."
        model.recycleBinEntries = [
            DocumentHistoryEntry(
                id: UUID(),
                sessionID: UUID(),
                title: "Deleted.sss",
                label: "Deleted",
                changeSummary: nil,
                savedAt: Date(timeIntervalSince1970: 1_700_000_000),
                packageURL: FileManager.default.temporaryDirectory.appendingPathComponent("Deleted.sss"),
                previewAssetURL: nil,
                sourceDocumentURL: nil,
                hasUnsavedChanges: false,
                searchableText: "",
                packageSizeBytes: 10,
                deletedAt: Date(timeIntervalSince1970: 1_700_000_001)
            )
        ]

        let diagnostics = SupportDiagnosticsBuilder.make(
            snapshot: supportDiagnosticsSnapshot(from: model),
            generatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        XCTAssertEqual(diagnostics.permissions.screenRecording, true)
        XCTAssertEqual(diagnostics.permissions.accessibility, false)
        XCTAssertEqual(diagnostics.editor.annotationCount, 2)
        XCTAssertEqual(diagnostics.editor.selectedAnnotationCount, 1)
        XCTAssertEqual(diagnostics.storage.recycleBinItemCount, 1)
        XCTAssertEqual(diagnostics.connectedDevice.listedDeviceCount, 1)
        XCTAssertEqual(diagnostics.connectedDevice.previewSessionActive, false)
        XCTAssertEqual(diagnostics.connectedDevice.emptyStateMessage, "Connected device needs attention.")
        XCTAssertEqual(diagnostics.recentStatus.launchAtLoginStatus, model.lifecycle.launchAtLoginStatus.stateLabel)
    }

    func testBuilderSanitizesStatusStringsAndOmitsSensitiveContent() throws {
        let model = makeModel()
        let controller = EditorController(capture: makeCapturedScreenshot())
        controller.addAnnotation(
            Annotation.makeText(at: CGPoint(x: 12, y: 16))
                .updatingText("Do not include this annotation text")
        )
        controller.errorMessage = "Could not read /Volumes/External/Client Folder/Screenshot.png"
        model.editorController = controller
        model.errorMessage = "Failed opening /Users/example/Documents/Private.sss"
        model.workingMessage = "Writing /private/tmp/SnipSnipSnip/session/file.sss"
        model.isWorking = true

        let diagnostics = SupportDiagnosticsBuilder.make(snapshot: supportDiagnosticsSnapshot(from: model))
        let json = String(data: try diagnostics.jsonData(), encoding: .utf8)!

        XCTAssertFalse(json.contains("/Users/example"))
        XCTAssertFalse(json.contains("/Volumes/External"))
        XCTAssertFalse(json.contains("/private/tmp"))
        XCTAssertFalse(json.contains("Do not include this annotation text"))
        XCTAssertEqual(diagnostics.recentStatus.appError, "Input failed.")
        XCTAssertEqual(diagnostics.recentStatus.editorError, "Input failed.")
        XCTAssertEqual(diagnostics.recentStatus.workingMessage, "Operation in progress.")
    }

    func testDiagnosticsNeverIncludeFilenamesOrArbitraryErrorProse() throws {
        let model = makeModel()
        let cases: [(String, String)] = [
            ("Could not read /Users/example/Client.Secret.sss", "Input failed."),
            ("Could not open /Volumes/Client Files/秘密 Project.final.sss", "Input failed."),
            (#"Failed loading "/tmp/Client.Project/Quarterly Report.sss"."#, "Input failed."),
            ("The file “Client Secret.sss” couldn’t be opened because you don’t have permission to view it.", "Access denied."),
            ("The document ‘顧客の秘密.final.sss’ could not be saved.", "Output failed."),
            ("Private title, copied password, arbitrary user-authored text", "Status details omitted."),
        ]
        for (message, expected) in cases {
            model.errorMessage = message
            let diagnostics = SupportDiagnosticsBuilder.make(snapshot: supportDiagnosticsSnapshot(from: model))
            XCTAssertEqual(diagnostics.recentStatus.appError, expected)
            let json = try diagnostics.jsonData()
            let report = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
            let status = try XCTUnwrap(report["recentStatus"] as? [String: Any])
            XCTAssertEqual(status["appError"] as? String, expected, "Only a fixed category is serialized")
        }

        model.isWorking = true
        for message in ["Saving", "Capturing"] {
            model.workingMessage = message
            let diagnostics = SupportDiagnosticsBuilder.make(snapshot: supportDiagnosticsSnapshot(from: model))
            XCTAssertEqual(diagnostics.recentStatus.workingMessage, message)
        }
        model.workingMessage = "Capturing Customer Private Window"
        let diagnostics = SupportDiagnosticsBuilder.make(snapshot: supportDiagnosticsSnapshot(from: model))
        XCTAssertEqual(diagnostics.recentStatus.workingMessage, "Operation in progress.")
    }

    private func makeModel() -> AppModel {
        let suiteName = "SupportDiagnosticsTests.\(UUID().uuidString)"
        let defaults = makeDefaults(named: suiteName)

        let recoveryStore = DocumentRecoveryStore(
            baseURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        return AppModel(
            defaults: defaults,
            recoveryStore: recoveryStore,
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )
    }

    private func supportDiagnosticsSnapshot(from model: AppModel) -> SupportDiagnosticsSnapshot {
        SupportDiagnosticsSnapshot.make(
            capabilities: model.capabilities,
            permissions: model.environment.permissions,
            systemServices: model.environment.systemServices,
            lifecycle: model.lifecycle,
            permissionWorkflow: model.permissions,
            capture: model.capture,
            documents: model.documents,
            clipboard: model.clipboard,
            video: model.video,
            archive: model.archive
        )
    }
}
