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
            model: model,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        XCTAssertEqual(diagnostics.permissions.screenRecording, true)
        XCTAssertEqual(diagnostics.permissions.accessibility, false)
        XCTAssertEqual(diagnostics.editor.annotationCount, 2)
        XCTAssertEqual(diagnostics.editor.selectedAnnotationCount, 1)
        XCTAssertEqual(diagnostics.storage.recycleBinItemCount, 1)
        XCTAssertEqual(diagnostics.recentStatus.launchAtLoginStatus, model.launchAtLoginStatus.stateLabel)
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

        let diagnostics = SupportDiagnosticsBuilder.make(model: model)
        let json = String(data: try diagnostics.jsonData(), encoding: .utf8)!

        XCTAssertFalse(json.contains("/Users/example"))
        XCTAssertFalse(json.contains("/Volumes/External"))
        XCTAssertFalse(json.contains("/private/tmp"))
        XCTAssertFalse(json.contains("Do not include this annotation text"))
        XCTAssertTrue(json.contains("[path]"))
    }

    private func makeModel() -> AppModel {
        let suiteName = "SupportDiagnosticsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

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
}
