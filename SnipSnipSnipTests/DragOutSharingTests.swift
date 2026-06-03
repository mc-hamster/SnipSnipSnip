import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SnipSnipSnip

@MainActor
final class DragOutSharingTests: XCTestCase {
    private enum ExpectedError: Error {
        case failed
    }

    private actor WriteCounter {
        private(set) var value = 0

        func increment() {
            value += 1
        }
    }

    func testPromisedPayloadDefersWritingUntilRequested() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let writeCount = WriteCounter()

        let payload = PromisedFilePayload(
            suggestedFilename: outputURL.lastPathComponent,
            contentType: .plainText,
            writer: { destinationURL in
                await writeCount.increment()
                try Data("shared".utf8).write(to: destinationURL)
            }
        )

        let initialWriteCount = await writeCount.value
        XCTAssertEqual(initialWriteCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))

        try await payload.write(to: outputURL)

        let finalWriteCount = await writeCount.value
        XCTAssertEqual(finalWriteCount, 1)
        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), "shared")
    }

    func testPromisedPayloadRemovesPartialDestinationAfterFailure() async {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let payload = PromisedFilePayload(
            suggestedFilename: outputURL.lastPathComponent,
            contentType: .plainText,
            writer: { destinationURL in
                try Data("partial".utf8).write(to: destinationURL)
                throw ExpectedError.failed
            }
        )

        do {
            try await payload.write(to: outputURL)
            XCTFail("Expected promised-file write to fail")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        }
    }

    func testPromisedPayloadWritesFromDetachedExecutor() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let payload = PromisedFilePayload(
            suggestedFilename: outputURL.lastPathComponent,
            contentType: .plainText,
            writer: { destinationURL in
                try Data("shared off main actor".utf8).write(to: destinationURL)
            }
        )

        try await Task.detached {
            try await payload.write(to: outputURL)
        }.value

        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), "shared off main actor")
    }

    func testFilePromiseDelegateWritesToProvidedURLWithoutAppendingFilename() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let completionExpectation = expectation(description: "file promise completion")
        var observedDestinationURL: URL?
        var completionError: Error?

        let payload = PromisedFilePayload(
            suggestedFilename: "promised.png",
            contentType: .png,
            writer: { destinationURL in
                observedDestinationURL = destinationURL
                try Data("promised".utf8).write(to: destinationURL)
            }
        )
        let delegate = PromisedFileProviderDelegate(payload: payload) { _ in }
        let provider = NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: delegate)

        delegate.filePromiseProvider(provider, writePromiseTo: outputURL) { error in
            completionError = error
            completionExpectation.fulfill()
        }

        await fulfillment(of: [completionExpectation], timeout: 2)
        XCTAssertNil(completionError)
        XCTAssertEqual(observedDestinationURL, outputURL)
        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), "promised")
    }

    func testDirectImageWriteEncodesFinalDestination() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let image = makeSolidImage(
            width: 12,
            height: 8,
            color: PixelSample(red: 22, green: 44, blue: 66, alpha: 255)
        )

        try await ImageExporter.write(image, format: .png, to: outputURL, mode: .direct)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(outputURL as CFURL, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 12)
        XCTAssertEqual(decoded.height, 8)
    }

    func testEditedFilenamePlacesSuffixBeforeExtension() {
        XCTAssertEqual(
            ImageExporter.editedFilename(suggestedFilename: "Screenshot.png", format: .png),
            "Screenshot-edited.png"
        )
        XCTAssertEqual(
            ImageExporter.editedFilename(suggestedFilename: "Screenshot.jpg", format: .pdf),
            "Screenshot-edited.pdf"
        )
    }

    func testTransparentPresentationDragOutFallsBackToPNG() {
        XCTAssertEqual(
            ImageExporter.dragOutFormat(requestedFormat: .jpeg, requiresPNGForFaithfulExport: true),
            .png
        )
        XCTAssertEqual(
            ImageExporter.dragOutFormat(requestedFormat: .pdf, requiresPNGForFaithfulExport: true),
            .png
        )
        XCTAssertEqual(
            ImageExporter.dragOutFormat(requestedFormat: .jpeg, requiresPNGForFaithfulExport: false),
            .jpeg
        )
    }

    func testPromisedScreenshotPayloadUsesPresentationRendererAndPNGFallback() async throws {
        let capture = makeCapturedScreenshot(
            image: makeSolidImage(width: 80, height: 60, color: PixelSample(red: 240, green: 240, blue: 240, alpha: 255))
        )
        let presentation = ScreenshotPresentationPreset.transparentShadow.settings
        let snapshot = makeEditorSnapshot(
            cropRect: CGRect(origin: .zero, size: CGSize(width: 80, height: 60)),
            presentation: presentation
        )
        let controller = EditorController(
            capture: capture,
            session: makeEditorDocumentSession(initialSnapshot: snapshot, currentSnapshot: snapshot)
        )
        let payload = controller.promisedImagePayload(
            requestedFormat: .jpeg,
            filenameTemplate: ScreenshotFilenameTemplate(pattern: "Shared-{source}")
        )
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(payload.suggestedFilename)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        XCTAssertEqual(payload.contentType, .png)
        XCTAssertEqual(payload.suggestedFilename, "Shared-Display-edited.png")
        XCTAssertEqual(controller.noticeMessage, "PNG used to preserve transparent presentation styling.")

        try await payload.write(to: outputURL)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(outputURL as CFURL, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertGreaterThan(decoded.width, capture.image.width)
        XCTAssertGreaterThan(decoded.height, capture.image.height)
        XCTAssertEqual(samplePixel(in: decoded, topLeftX: 0, topLeftY: 0).alpha, 0)
    }

    func testScreenshotDragOutPreferenceDefaultsPersistsAndResets() {
        let suiteName = "DragOutSharingTests.preference"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(
            defaults: defaults,
            recoveryStore: DocumentRecoveryStore(baseURL: nil),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )
        XCTAssertEqual(model.screenshotDragOutFormat, .png)

        model.screenshotDragOutFormat = .pdf
        let reloaded = AppModel(
            defaults: defaults,
            recoveryStore: DocumentRecoveryStore(baseURL: nil),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )
        XCTAssertEqual(reloaded.screenshotDragOutFormat, .pdf)

        reloaded.resetPreferencesToDefaults()
        XCTAssertEqual(reloaded.screenshotDragOutFormat, .png)
    }

    func testVideoDragOutExportFreezesTrimRangeAndPreset() {
        let recording = CapturedVideoRecording(
            sourceURL: URL(fileURLWithPath: "/tmp/frozen-recording.mp4"),
            kind: .window,
            sourceName: "Release Notes Window",
            bounds: CGRect(x: 20, y: 30, width: 640, height: 360),
            recordedAt: Date(timeIntervalSince1970: 1_818_181_818),
            duration: 17,
            preferences: VideoRecordingPreferences()
        )
        let session = VideoEditorSession(
            trimStartSeconds: 2,
            trimEndSeconds: 11,
            posterTimeSeconds: 4
        )
        let request = VideoExportRequest(format: .mp4, target: .sizeLimit(.under25MB))

        let dragOutExport = VideoDragOutExport(
            recording: recording,
            session: session,
            request: request
        )

        XCTAssertEqual(dragOutExport.document.recording, recording)
        XCTAssertEqual(dragOutExport.document.session, session)
        XCTAssertEqual(dragOutExport.request, request)
        XCTAssertEqual(dragOutExport.suggestedFilename, "\(recording.defaultFilename).mp4")
    }
}
