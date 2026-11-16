import AppKit
import PDFKit
import XCTest
@testable import SnipSnipSnip

final class DocumentPrintCoordinatorTests: XCTestCase {
    @MainActor
    func testPrintOperationUsesNativeDialogAndIndependentPrintSettings() throws {
        let image = makeSolidImage(width: 80, height: 40, color: .init(red: 255, green: 255, blue: 255, alpha: 255))
        let data = try ImageExporter.pdfData(for: image)
        let operation = try DocumentPrintCoordinator.printOperation(data: data, title: "Screenshot")

        XCTAssertEqual(operation.jobTitle, "Screenshot")
        XCTAssertTrue(operation.showsPrintPanel)
        XCTAssertTrue(operation.showsProgressPanel)
        XCTAssertFalse(operation.printInfo === NSPrintInfo.shared)
    }

    @MainActor
    func testInvalidPrintDataReportsErrorAndReleasesJob() async {
        let coordinator = DocumentPrintCoordinator()
        var receivedError = false
        coordinator.printDocument(
            title: "Screenshot", prepare: { Data() }, isCurrent: { true },
            onError: { _ in receivedError = true }
        )
        XCTAssertTrue(coordinator.isPrinting)
        await waitUntil { !coordinator.isPrinting }
        XCTAssertTrue(receivedError)
    }

    @MainActor
    func testChangedDocumentSuppressesDialogAndDuplicatePreparation() async {
        let coordinator = DocumentPrintCoordinator()
        var preparationCount = 0
        var receivedError = false
        let prepare: @MainActor () async throws -> Data = {
            preparationCount += 1
            return Data()
        }
        for _ in 0..<2 {
            coordinator.printDocument(
                title: "Screenshot", prepare: prepare, isCurrent: { false },
                onError: { _ in receivedError = true }
            )
        }
        await waitUntil { !coordinator.isPrinting }
        XCTAssertEqual(preparationCount, 1)
        XCTAssertFalse(receivedError)
    }

    func testGuidePrintUsesCurrentIncludedStepsAndPDFLayout() async throws {
        let image = makeSolidImage(width: 80, height: 40, color: .init(red: 255, green: 255, blue: 255, alpha: 255))
        var project = GuideProject(source: .displays(.current))
        let session = GuideStepSession(
            sourceCoordinateRect: CGRect(x: 0, y: 0, width: 80, height: 40),
            sourcePixelSize: CGSize(width: 80, height: 40)
        )
        project.steps = (1...3).map {
            GuideStep(sequence: $0, eventKind: .manual, caption: "Step \($0)", session: session)
        }
        project.steps[1].isIncluded = false
        project.exportSettings.includesCoverWhenTitled = false
        project.exportSettings.usesCompactPDFLayout = false
        let document = EditableGuideDocument(
            project: project,
            stepImages: Dictionary(uniqueKeysWithValues: project.steps.map { ($0.id, image) }),
            previewImage: nil, logoImage: nil, mediaSegmentURLs: [:]
        )
        let data = try await GuidePrintRenderer.pdfData(document: document)
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(pdf.pageCount, 2)
        XCTAssertTrue(pdf.string?.contains("Step 3") == true)
        XCTAssertFalse(pdf.string?.contains("Step 2") == true)
        XCTAssertTrue(document.project.steps[1].isIncluded == false)
    }
}
