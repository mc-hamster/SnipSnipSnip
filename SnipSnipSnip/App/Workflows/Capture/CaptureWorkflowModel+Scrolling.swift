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
        guard dependencies.capabilities.isEnabled(.scrollingCapture), !isWorking, !isInteractiveCaptureActive else { return }
        let mode: ScrollingCaptureMode
        if let requested = oneShotOptions?.scrollingMode {
            mode = resolvedScrollingMode(requested)
        } else if dependencies.capabilities.isEnabled(.automaticScrollingCapture) {
            guard let selected = dependencies.chooseScrollingMode() else { return }
            mode = selected
        } else {
            mode = .manual
        }
        var options = oneShotOptions ?? CaptureOneShotOptions(
            captureDelay: captureDelay, includesCursor: screenshotIncludesCursor,
            privateCapture: privateCaptureEnabled, windowUIMapEnabled: windowUIMapEnabled
        )
        options.scrollingMode = mode
        prepareCaptureIntent(
            intent,
            completionRole: completionRole,
            oneShotOptions: options,
            presentationContext: presentationContext
        )
        runActionWhenPermissionsReady(
            scrollingPermissionRequirements(for: mode),
            featureName: "Scrolling Capture",
            pendingCommand: .scrollingCapture
        ) { [weak self] in
            self?.beginScrollingCapture()
        }
    }

    func resolvedScrollingMode(_ requested: ScrollingCaptureMode?) -> ScrollingCaptureMode {
        guard dependencies.capabilities.isEnabled(.automaticScrollingCapture) else { return .manual }
        return requested ?? .automatic
    }

    func scrollingPermissionRequirements(for mode: ScrollingCaptureMode) -> [CapturePermissionRequirement] {
        mode == .automatic ? [.screenRecording, .accessibility] : [.screenRecording]
    }

    func repeatScrollingCapture(_ region: CGRect) {
        repeatScrollingCaptureImpl(region)
    }

}
