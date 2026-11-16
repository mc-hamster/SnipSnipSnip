import AppKit
import Combine
import PDFKit

/// Owns preparation and the native print dialog, without changing editable work.
@MainActor
final class DocumentPrintCoordinator: ObservableObject {
    @Published private(set) var isPrinting = false

    func printDocument(
        title: String,
        prepare: @escaping @MainActor () async throws -> Data,
        isCurrent: @escaping @MainActor () -> Bool,
        onError: @escaping @MainActor (Error) -> Void
    ) {
        guard !isPrinting else { return }
        isPrinting = true
        Task { @MainActor in
            defer { isPrinting = false }
            do {
                let data = try await prepare()
                guard isCurrent() else { return }
                let operation = try Self.printOperation(data: data, title: title)
                operation.run()
            } catch is CancellationError {
                return
            } catch {
                if isCurrent() { onError(error) }
            }
        }
    }

    static func printOperation(data: Data, title: String) throws -> NSPrintOperation {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        guard let document = PDFDocument(data: data), document.pageCount > 0,
              let operation = document.printOperation(
                for: info, scalingMode: .pageScaleToFit, autoRotate: true
              ) else {
            throw DocumentPrintError.invalidDocument
        }
        operation.jobTitle = title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        return operation
    }
}

private enum DocumentPrintError: LocalizedError {
    case invalidDocument

    var errorDescription: String? {
        String(localized: "The document could not be prepared for printing.")
    }
}

nonisolated enum GuidePrintRenderer {
    static func pdfData(document: EditableGuideDocument) async throws -> Data {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnipSnip-Print-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await GuideExporter.export(
            document: document, format: .pdf, directory: directory
        )
        return try Data(contentsOf: url)
    }
}
