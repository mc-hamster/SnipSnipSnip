import Foundation

extension DocumentWorkflowModel {
    func presentCapturePreview(
        for result: CaptureWorkflowResult,
        installation: CaptureInstallationResult
    ) -> Bool {
        guard CapturePreviewPolicy.shouldPresent(
            result: result, disposition: installation.disposition,
            isEnabled: showsCapturePreview
        ), let controller = installation.controller,
           editorController === controller else { return false }

        hasCapturePreview = true
        capturePreviewCoordinator.present(
            controller: controller,
            autoCopyEnabled: autoCopyEnabled,
            copy: { [weak self, weak controller] completion in
                guard let self, let controller, self.editorController === controller else {
                    completion(false)
                    return
                }
                self.copyCurrentEditorImageToClipboard(completion: completion)
            },
            edit: { [weak self, weak controller] in
                guard let self, self.editorController === controller else { return }
                self.capturePreviewCoordinator.clear()
                self.hasCapturePreview = false
                self.requestMainWindowPresentation()
            },
            export: { [weak self, weak controller] in
                guard let self, self.editorController === controller else { return }
                self.exportAnnotatedImage(as: .png, appearance: .plain)
            },
            drag: { [weak self, weak controller] in
                guard let self, self.editorController === controller else { return nil }
                return self.promisedAnnotatedImagePayload(appearance: .plain)
            }
        )
        return true
    }

    func showCapturePreview() {
        guard hasCapturePreview else { return }
        capturePreviewCoordinator.show()
    }

    func updateCapturePreviewAutoCopy(_ enabled: Bool) {
        capturePreviewCoordinator.model?.updateAutoCopy(enabled)
    }
}
