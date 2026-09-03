import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import SnipSnipSnip

@MainActor
final class ImageExportFileWriterTests: XCTestCase {
    private enum ExpectedError: Error {
        case encodingFailed
    }

    func testAllFormatsCreateAndReplaceReadableFiles() async throws {
        let directory = try makeDestinationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = makeSolidImage(
            width: 17, height: 11,
            color: PixelSample(red: 120, green: 80, blue: 40, alpha: 255)
        )

        for format in ImageExportFormat.allCases {
            let destination = directory.appendingPathComponent("export.\(format.fileExtension)")
            for replacing in [false, true] {
                if replacing {
                    try Data("old content".utf8).write(to: destination)
                }
                try await ImageExporter.write(image, format: format, to: destination)

                if format == .pdf {
                    let pdf = try XCTUnwrap(CGPDFDocument(destination as CFURL))
                    XCTAssertEqual(pdf.numberOfPages, 1)
                    XCTAssertNotNil(pdf.page(at: 1))
                } else {
                    let source = try XCTUnwrap(CGImageSourceCreateWithURL(destination as CFURL, nil))
                    let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                    XCTAssertEqual(decoded.width, image.width)
                    XCTAssertEqual(decoded.height, image.height)
                }
            }
        }
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
            Set(["export.png", "export.jpg", "export.pdf"])
        )
    }

    func testPDFPageMatchesImageSize() async throws {
        let directory = try makeDestinationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for (width, height) in [(17, 11), (1512, 982)] {
            let image = makeSolidImage(
                width: width, height: height,
                color: PixelSample(red: 120, green: 80, blue: 40, alpha: 255)
            )
            let expectedPage = CGRect(x: 0, y: 0, width: image.width, height: image.height)

            let pdfData = try ImageExporter.data(for: image, format: .pdf)
            let dataOutput = directory.appendingPathComponent("data-\(width).pdf")
            try pdfData.write(to: dataOutput)
            let dataDocument = try XCTUnwrap(CGPDFDocument(dataOutput as CFURL))
            let dataPage = try XCTUnwrap(dataDocument.page(at: 1))
            XCTAssertEqual(dataPage.getBoxRect(.mediaBox), expectedPage, "Data-based PDF writer must size the page to the image")

            let destination = directory.appendingPathComponent("export-\(width).pdf")
            try await ImageExporter.write(image, format: .pdf, to: destination)
            let fileDocument = try XCTUnwrap(CGPDFDocument(destination as CFURL))
            let filePage = try XCTUnwrap(fileDocument.page(at: 1))
            XCTAssertEqual(filePage.getBoxRect(.mediaBox), expectedPage, "Staged PDF writer must size the page to the image")
        }
    }

    func testStagingDoesNotRequireDestinationSiblingAccessAndIsRemovedAfterSuccess() throws {
        let directory = try makeDestinationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("export.png")
        let original = Data("old content".utf8)
        let replacement = Data("new content".utf8)
        try original.write(to: destination)
        var stagingDirectory: URL?

        try ImageExportFileWriter.write(to: destination) { stagedURL in
            stagingDirectory = stagedURL.deletingLastPathComponent()
            XCTAssertNotEqual(
                stagingDirectory?.resolvingSymlinksInPath(),
                directory.resolvingSymlinksInPath()
            )
            XCTAssertEqual(try Data(contentsOf: destination), original)
            try replacement.write(to: stagedURL)
        }

        XCTAssertEqual(try Data(contentsOf: destination), replacement)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(stagingDirectory).path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["export.png"])
    }

    func testEncodingFailurePreservesDestinationAndRemovesStaging() throws {
        let directory = try makeDestinationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("export.png")
        let original = Data("old content".utf8)

        for replacing in [false, true] {
            if replacing {
                try original.write(to: destination)
            }
            var stagingDirectory: URL?
            XCTAssertThrowsError(try ImageExportFileWriter.write(to: destination) { stagedURL in
                stagingDirectory = stagedURL.deletingLastPathComponent()
                try Data("partial encoding".utf8).write(to: stagedURL)
                throw ExpectedError.encodingFailed
            }) { error in
                XCTAssertTrue(error is ExpectedError)
            }

            XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(stagingDirectory).path))
            if replacing {
                XCTAssertEqual(try Data(contentsOf: destination), original)
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            }
        }
    }

    func testCancellationAfterEncodingPreservesDestinationAndRemovesStaging() async throws {
        let directory = try makeDestinationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("export.png")
        let original = Data("old content".utf8)
        try original.write(to: destination)

        let stagingDirectory = try await Task.detached { () throws -> URL in
            var stagingDirectory: URL?
            do {
                try ImageExportFileWriter.write(to: destination) { stagedURL in
                    stagingDirectory = stagedURL.deletingLastPathComponent()
                    try Data("complete encoding".utf8).write(to: stagedURL)
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                XCTFail("Cancellation must prevent installation of the staged output")
            } catch is CancellationError {
                // Expected: encoding finished, but installation must not proceed.
            }
            return try XCTUnwrap(stagingDirectory)
        }.value

        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory.path))
    }

    func testInstallationFailureRemovesStaging() throws {
        let directory = try makeDestinationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("export.png")
        var stagingDirectory: URL?

        XCTAssertThrowsError(try ImageExportFileWriter.write(to: destination) { stagedURL in
            stagingDirectory = stagedURL.deletingLastPathComponent()
            try Data("complete encoding".utf8).write(to: stagedURL)
            // Model a destination that disappears while encoding is in progress.
            try FileManager.default.removeItem(at: directory)
        })

        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(stagingDirectory).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    private func makeDestinationDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
