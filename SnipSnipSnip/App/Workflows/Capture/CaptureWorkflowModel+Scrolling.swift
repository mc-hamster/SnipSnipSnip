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
        func start(_ mode: ScrollingCaptureMode) {
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

        let requestedMode = oneShotOptions?.scrollingMode
        guard requestedMode == nil, dependencies.capabilities.isEnabled(.automaticScrollingCapture) else {
            start(resolvedScrollingMode(requestedMode))
            return
        }

        isWorking = true
        dependencies.lifecycle.updateWorkingMessage("Scrolling Capture")
        Task {
            let mode = await dependencies.chooseScrollingMode(presentationContext.displayID)
            isWorking = false
            guard let mode, !Task.isCancelled else { return }
            start(mode)
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
