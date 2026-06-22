import Foundation

@MainActor
extension CaptureWorkflowModel {
    func beginCapturePrivacyLock() -> Bool {
        let latchedPrivateCapture = privateCaptureEnabled
        capturePrivacyLockDepth += 1
        isCapturePrivacyLocked = true
        return latchedPrivateCapture
    }

    func endCapturePrivacyLock() {
        capturePrivacyLockDepth = max(0, capturePrivacyLockDepth - 1)

        if capturePrivacyLockDepth == 0 {
            isCapturePrivacyLocked = false
        }
    }
}
