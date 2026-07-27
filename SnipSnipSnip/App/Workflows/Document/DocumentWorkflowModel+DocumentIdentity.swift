import Foundation

extension DocumentWorkflowModel {
    var currentDocumentFilename: String {
        if let currentDocumentURL {
            return currentDocumentURL.lastPathComponent
        }
        if let controller = editorController {
            return ScreenshotFilenameTemplate(
                pattern: screenshotFilenameTemplate
            )
            .resolvedFilename(
                for: controller.capture,
                formatExtension: "sss"
            ) + ".sss"
        }
        if let controller = videoEditorController {
            return controller.recording.defaultFilename + ".sssvideo"
        }
        if let controller = guideEditorController {
            let title = controller.project.title.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return (title.isEmpty ? "Untitled Guide" : title)
                + ".sssguide"
        }
        return "Untitled.sss"
    }
}
