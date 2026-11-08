import Foundation
import XCTest
@testable import SnipSnipSnip

@MainActor
final class VideoExportTransactionTests: XCTestCase {
    func testInvalidVideoDoesNotReplaceExistingOutputForAnyFormat() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VideoExportTransactionTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("invalid.mov")
        try Data("Invalid video fixture".utf8).write(to: source)
        let recording = CapturedVideoRecording(sourceURL: source, kind: .region, sourceName: "Fixture",
            bounds: CGRect(x: 0, y: 0, width: 160, height: 100), recordedAt: Date(),
            duration: 2, preferences: VideoRecordingPreferences())
        let document = EditableVideoDocument(recording: recording, session: .fullDuration(2))
        let previous = Data("Existing export must survive".utf8)
        for format in [VideoExportFormat.mp4, .gif, .apng] {
            let destination = directory.appendingPathComponent("existing.\(format.rawValue)")
            try previous.write(to: destination)
            do {
                try await VideoExporter.export(document, as: format, to: destination)
                XCTFail("Invalid media must fail")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: destination), previous, "\(format) must retain the existing export")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
            ["existing.apng", "existing.gif", "existing.mp4", "invalid.mov"])
    }

    func testCancelledVideoExportPreservesExistingOutput() async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("VideoExportTransactionTests-\(UUID()).mp4")
        let previous = Data("Existing export".utf8)
        try previous.write(to: destination)
        defer { try? FileManager.default.removeItem(at: destination) }
        let recording = CapturedVideoRecording(sourceURL: destination, kind: .region, sourceName: "Fixture",
            bounds: CGRect(x: 0, y: 0, width: 160, height: 100), recordedAt: Date(),
            duration: 2, preferences: VideoRecordingPreferences())
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await VideoExporter.export(EditableVideoDocument(recording: recording, session: .fullDuration(2)),
                as: .mp4, preset: .high, progressHandler: nil, to: destination)
        }
        do {
            try await operation.value
            XCTFail("Cancelled export must fail")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: destination), previous)
    }
}
