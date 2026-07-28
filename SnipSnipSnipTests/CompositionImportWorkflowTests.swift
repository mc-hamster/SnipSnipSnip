import Foundation
import XCTest
@testable import SnipSnipSnip

@MainActor
final class CompositionImportWorkflowTests: XCTestCase {
    func testPartialBatchKeepsSuccessfulImportAndRetriesRetainedFailure() throws {
        let fixture = try makeFixture(named: #function)
        defer { fixture.cleanup() }
        let rootItemID = try XCTUnwrap(
            fixture.controller.composition?.items.first?.id
        )
        let validURL = fixture.directory.appendingPathComponent("First.png")
        let failedURL = fixture.directory.appendingPathComponent("Second.png")
        try writeImage(
            to: validURL,
            color: PixelSample(red: 255, green: 0, blue: 0, alpha: 255)
        )
        try Data("not an image".utf8).write(to: failedURL)

        fixture.model.documents.handleCompositionFileDrop(
            [validURL, failedURL],
            destination: .insert(afterItemID: rootItemID)
        )

        XCTAssertEqual(fixture.controller.composition?.items.count, 2)
        XCTAssertEqual(
            fixture.controller.composition?.items.map(\.title),
            ["Root", "First"]
        )
        let recovery = try XCTUnwrap(
            fixture.model.documents.pendingCompositionImportRecovery
        )
        XCTAssertEqual(recovery.successfulSourceCount, 1)
        XCTAssertEqual(recovery.failures.map(\.url), [failedURL])
        let firstImportedID = try XCTUnwrap(
            fixture.controller.composition?.items.last?.id
        )
        XCTAssertEqual(
            recovery.retryDestination,
            .insert(afterItemID: firstImportedID)
        )
        XCTAssertEqual(recovery.summary, "Added: 1. Failed: 1.")
        XCTAssertEqual(
            fixture.controller.notice?.accessibilityAnnouncement,
            "Import complete. Added: 1. Failed: 1."
        )

        try writeImage(
            to: failedURL,
            color: PixelSample(red: 0, green: 0, blue: 255, alpha: 255)
        )
        fixture.model.documents.retryFailedCompositionImports()

        XCTAssertNil(fixture.model.documents.pendingCompositionImportRecovery)
        XCTAssertEqual(fixture.controller.composition?.items.count, 3)
        XCTAssertEqual(
            fixture.controller.composition?.items.map(\.title),
            ["Root", "First", "Second"]
        )
        XCTAssertEqual(
            fixture.controller.notice?.accessibilityAnnouncement,
            "Import complete. Added: 1. Failed: 0."
        )
    }

    func testReplaceBatchRetryContinuesAfterSuccessfulReplacement() throws {
        let fixture = try makeFixture(named: #function)
        defer { fixture.cleanup() }
        let added = try fixture.controller.appendCaptureToComposition(
            makeCapturedScreenshot(sourceName: "Original Target"),
            isPrivate: false
        )
        let failedURL = fixture.directory.appendingPathComponent("Late.png")
        let replacementURL = fixture.directory.appendingPathComponent(
            "Replacement.png"
        )
        try Data("not an image".utf8).write(to: failedURL)
        try writeImage(
            to: replacementURL,
            color: PixelSample(red: 0, green: 255, blue: 0, alpha: 255)
        )

        fixture.model.documents.handleCompositionFileDrop(
            [failedURL, replacementURL],
            destination: .replace(itemID: added.itemID)
        )

        let recovery = try XCTUnwrap(
            fixture.model.documents.pendingCompositionImportRecovery
        )
        XCTAssertEqual(
            recovery.retryDestination,
            .insert(afterItemID: added.itemID)
        )
        XCTAssertEqual(fixture.controller.composition?.items.count, 2)
        XCTAssertEqual(
            fixture.controller.composition?.items.last?.title,
            "Replacement"
        )

        try writeImage(
            to: failedURL,
            color: PixelSample(red: 0, green: 0, blue: 255, alpha: 255)
        )
        fixture.model.documents.retryFailedCompositionImports()

        XCTAssertNil(fixture.model.documents.pendingCompositionImportRecovery)
        XCTAssertEqual(fixture.controller.composition?.items.count, 3)
        XCTAssertEqual(
            fixture.controller.composition?.items.map(\.title),
            ["Root", "Replacement", "Late"]
        )
    }

    func testReplaceRetryRetainsExactItemWhenEverySourceInitiallyFails() throws {
        let fixture = try makeFixture(named: #function)
        defer { fixture.cleanup() }
        let added = try fixture.controller.appendCaptureToComposition(
            makeCapturedScreenshot(sourceName: "Original Target"),
            isPrivate: false
        )
        let failedURL = fixture.directory.appendingPathComponent(
            "Replacement.png"
        )
        try Data("not an image".utf8).write(to: failedURL)

        fixture.model.documents.handleCompositionFileDrop(
            [failedURL],
            destination: .replace(itemID: added.itemID)
        )

        let recovery = try XCTUnwrap(
            fixture.model.documents.pendingCompositionImportRecovery
        )
        XCTAssertEqual(
            recovery.retryDestination,
            .replace(itemID: added.itemID)
        )
        XCTAssertEqual(fixture.controller.composition?.items.count, 2)
        XCTAssertEqual(
            fixture.controller.composition?.items.last?.title,
            "Original Target"
        )

        try writeImage(
            to: failedURL,
            color: PixelSample(red: 0, green: 255, blue: 0, alpha: 255)
        )
        fixture.model.documents.retryFailedCompositionImports()

        XCTAssertNil(fixture.model.documents.pendingCompositionImportRecovery)
        XCTAssertEqual(fixture.controller.composition?.items.count, 2)
        XCTAssertEqual(
            fixture.controller.composition?.items.last?.id,
            added.itemID
        )
        XCTAssertEqual(
            fixture.controller.composition?.items.last?.title,
            "Replacement"
        )
    }

    func testCancelledMultiItemChoiceAndEmptySelectionDoNotMutate() throws {
        let fixture = try makeFixture(named: #function)
        defer { fixture.cleanup() }
        let validURL = fixture.directory.appendingPathComponent("First.png")
        let packageURL = fixture.directory.appendingPathComponent(
            "Source.sss",
            isDirectory: true
        )
        try writeImage(
            to: validURL,
            color: PixelSample(red: 255, green: 0, blue: 0, alpha: 255)
        )

        let sourceController = EditorController(
            capture: makeCapturedScreenshot(sourceName: "Source One")
        )
        _ = try sourceController.appendCaptureToComposition(
            makeCapturedScreenshot(sourceName: "Source Two"),
            isPrivate: false
        )
        try SSSDocumentPackage.save(
            document: sourceController.editableDocument,
            previewImage: sourceController.documentCapture.image,
            to: packageURL
        )
        fixture.model.documents.compositionEditableImportChoiceHandler = {
            itemCount in
            XCTAssertEqual(itemCount, 2)
            return .cancel
        }
        let originalSession = fixture.controller.documentSession
        let originalPrivateState = fixture.controller.isPrivateDocument
        let rootItemID = try XCTUnwrap(
            fixture.controller.composition?.items.first?.id
        )

        fixture.model.documents.handleCompositionFileDrop(
            [],
            destination: .insert(afterItemID: rootItemID)
        )
        fixture.model.documents.handleCompositionFileDrop(
            [validURL, packageURL],
            destination: .insert(afterItemID: rootItemID)
        )

        XCTAssertEqual(fixture.controller.documentSession, originalSession)
        XCTAssertEqual(
            fixture.controller.isPrivateDocument,
            originalPrivateState
        )
        XCTAssertNil(fixture.model.documents.pendingCompositionImportRecovery)
    }

    private func makeFixture(named name: String) throws -> Fixture {
        let suiteName = "CompositionImportWorkflowTests.\(name)"
        let defaults = makeDefaults(named: suiteName)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let model = retainForTestLifetime(
            AppModel(
                defaults: defaults,
                recoveryStore: DocumentRecoveryStore(baseURL: nil),
                shouldCheckCompatibilityOnLaunch: false,
                shouldStartArchiveMaintenance: false
            )
        )
        let controller = EditorController(
            capture: makeCapturedScreenshot(sourceName: "Root"),
            defaults: defaults
        )
        model.documents.installEditorController(
            controller,
            documentURL: nil,
            savedSession: nil,
            shouldCreateRecoverySession: false
        )
        return Fixture(
            model: model,
            controller: controller,
            defaults: defaults,
            suiteName: suiteName,
            directory: directory
        )
    }

    private func writeImage(
        to url: URL,
        color: PixelSample
    ) throws {
        let image = makeSolidImage(width: 8, height: 6, color: color)
        try ImageExporter.pngData(for: image).write(
            to: url,
            options: .atomic
        )
    }
}

@MainActor
private struct Fixture {
    let model: AppModel
    let controller: EditorController
    let defaults: UserDefaults
    let suiteName: String
    let directory: URL

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}
