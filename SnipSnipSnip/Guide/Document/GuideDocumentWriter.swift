import Foundation

/// Manual saves and autosaves share a serial writer so an older autosave
/// cannot replace a newer manual save while its detached work is finishing.
nonisolated protocol GuideDocumentWriting: Sendable {
    func save(_ document: EditableGuideDocument, to url: URL, files: any FileSystemServicing) async throws -> EditableGuideDocument
}

actor GuideDocumentWriter: GuideDocumentWriting {
    func save(
        _ document: EditableGuideDocument,
        to url: URL,
        files: any FileSystemServicing
    ) throws -> EditableGuideDocument {
        try Task.checkCancellation()
        var document = document
        document.previewImage = GuideRenderer.renderPreview(
            project: document.project, images: document.stepImages
        )
        try SSSGuideDocumentPackage.save(document: document, to: url, files: files)
        return try SSSGuideDocumentPackage.load(from: url, files: files)
    }
}
