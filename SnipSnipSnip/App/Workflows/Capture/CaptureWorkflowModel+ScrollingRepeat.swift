import CoreGraphics
import Foundation

@MainActor
extension CaptureWorkflowModel {
    func repeatScrollingCaptureImpl(_ region: CGRect) {
        let captureContext = activeCaptureContext
        let runOptions = currentCaptureRunOptions()
        guard dependencies.capabilities.isEnabled(.scrollingCapture) else {
            resetPreparedCaptureContext(ifMatching: captureContext)
            return
        }
        Task {
            var transfersContextToSelection = false
            defer {
                if !transfersContextToSelection {
                    resetPreparedCaptureContext(ifMatching: captureContext)
                }
            }
            guard preflightPermissions([.screenRecording, .accessibility], for: "Scrolling Capture") else { return }
            let isPrivateCapture = beginCapturePrivacyLock(
                latchedPrivateCapture:
                    captureContext.oneShotOptions?.privateCapture
                    ?? privateCaptureEnabled
            )
            defer { endCapturePrivacyLock() }

            isWorking = true
            dependencies.lifecycle.updateWorkingMessage(captureDelay == .immediate ? "Scrolling Capture" : captureDelay.shortLabel)
            defer { isWorking = false }

            do {
                let service = dependencies.makeScrollingCaptureService(captureService)
                let target = try service.resolveTarget(
                    for: ScrollingCaptureRequest(
                        viewportRect: region,
                        isPrivateCapture: isPrivateCapture
                    )
                )
                switch ScrollingCaptureTargetConfirmation.present(target: target) {
                case .start:
                    break
                case .chooseAnotherArea:
                    transfersContextToSelection = true
                    captureScrollingArea(
                        intent: captureContext.intent,
                        completionRole: captureContext.role,
                        oneShotOptions: captureContext.oneShotOptions
                    )
                    return
                case .cancel:
                    resetPreparedCaptureContext(ifMatching: captureContext)
                    return
                }

                try await runCaptureDelayIfNeeded(
                    actionName: "Scrolling Capture",
                    delay: runOptions.captureDelay
                )
                try await performScrollingCapture(
                    in: region,
                    isPrivateCapture: isPrivateCapture,
                    runOptions: runOptions,
                    completionContext: captureContext
                )
            } catch ScrollingCaptureError.cancelled {
                resetPreparedCaptureContext(ifMatching: captureContext)
                return
            } catch let interruption as ScrollingCaptureInterruptedError {
                present(
                    interruption,
                    recovering: .scrolling(region),
                    captureContext: captureContext
                )
            } catch {
                present(
                    error,
                    recovering: .scrolling(region),
                    captureContext: captureContext
                )
            }
        }
    }
}
