import AppKit
import Foundation

nonisolated enum GuideDocumentProNotice {
    static let title = "Creating Guides is a Pro feature"
    static let message = "This App Store edition can open, edit, save, and export this Guide. Creating or recording new Guides is available in the free SnipSnipSnip Pro edition."
    static let learnMoreURL = AppLinks.snipSnipSnipProduct

    static func shouldPresent(
        didOpenSuccessfully: Bool,
        isAppStoreEdition: Bool,
        guideCaptureIsAvailable: Bool,
        hasPresented: Bool
    ) -> Bool {
        didOpenSuccessfully && isAppStoreEdition && !guideCaptureIsAvailable && !hasPresented
    }
}

extension DocumentWorkflowModel {
    func presentGuideDocumentProNoticeIfNeeded() {
        #if APP_STORE_BUILD
        let isAppStoreEdition = true
        #else
        let isAppStoreEdition = false
        #endif

        guard GuideDocumentProNotice.shouldPresent(
            didOpenSuccessfully: true,
            isAppStoreEdition: isAppStoreEdition,
            guideCaptureIsAvailable: capabilities.isEnabled(.guideCapture),
            hasPresented: preferenceStore.hasPresentedGuideDocumentProNotice()
        ) else {
            return
        }

        preferenceStore.markGuideDocumentProNoticePresented()

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = GuideDocumentProNotice.title
        alert.informativeText = GuideDocumentProNotice.message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Learn More")

        if alert.runModal() == .alertSecondButtonReturn {
            systemServices.workspace.open(GuideDocumentProNotice.learnMoreURL)
        }
    }
}
