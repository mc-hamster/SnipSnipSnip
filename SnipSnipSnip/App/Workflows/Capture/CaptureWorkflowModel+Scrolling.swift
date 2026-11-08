import AppKit
import Foundation

@MainActor
extension CaptureWorkflowModel {
    func captureScrollingArea() {
        captureScrollingArea(intent: .newDocument)
    }

    func captureScrollingArea(
        presentationContext: WorkflowPresentationContext
    ) {
        captureScrollingArea(
            intent: .newDocument,
            presentationContext: presentationContext
        )
    }

    func captureScrollingArea(
        intent: CaptureIntent,
        completionRole: CaptureCompletionRole = .standalone,
        oneShotOptions: CaptureOneShotOptions? = nil
    ) {
        captureScrollingArea(
            intent: intent,
            completionRole: completionRole,
            oneShotOptions: oneShotOptions,
            presentationContext: .application
        )
    }

    func captureScrollingArea(
        intent: CaptureIntent,
        completionRole: CaptureCompletionRole = .standalone,
        oneShotOptions: CaptureOneShotOptions? = nil,
        presentationContext: WorkflowPresentationContext
    ) {
        guard dependencies.capabilities.isEnabled(.scrollingCapture) else { return }
        prepareCaptureIntent(
            intent,
            completionRole: completionRole,
            oneShotOptions: oneShotOptions,
            presentationContext: presentationContext
        )
        runActionWhenPermissionsReady(
            [.screenRecording, .accessibility],
            featureName: "Scrolling Capture",
            pendingCommand: .scrollingCapture
        ) { [weak self] in
            self?.beginScrollingCapture()
        }
    }

    func repeatScrollingCapture(_ region: CGRect) {
        repeatScrollingCaptureImpl(region)
    }

}
