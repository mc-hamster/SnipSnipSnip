import Foundation

@MainActor
struct CreationPlanStarter {
    let capture: any CreationCaptureWorkflowPort
    let documents: any CreationDocumentWorkflowPort
    let guide: any CreationGuideWorkflowPort
    let tools: any CreationToolWorkflowPort

    func start(_ plan: CreationPlan) -> CreationPlanStartResult {
        if plan.goal == .instructions(.recordAsIWork) {
            guide.presentQuickStart()
            return .started
        }

        guard plan.documentPurpose != nil,
              let completionRole = plan.captureCompletionRole else {
            return .unavailable(
                "This creation plan does not produce a screenshot document."
            )
        }

        switch plan.source {
        case .region:
            capture.captureRegion(
                intent: .newDocument,
                completionRole: completionRole,
                oneShotOptions: plan.captureOptions
            )
        case .window:
            capture.presentWindowPicker(
                intent: .newDocument,
                completionRole: completionRole,
                oneShotOptions: plan.captureOptions
            )
        case .screen:
            capture.captureCurrentDisplay(
                intent: .newDocument,
                completionRole: completionRole,
                oneShotOptions: plan.captureOptions
            )
        case .existing(.files):
            return documents.createDocumentFromFiles(
                completionRole: completionRole,
                options: plan.captureOptions
            )
                ? .started
                : .cancelled
        case .existing(.clipboard):
            return documents.createDocumentFromClipboard(
                completionRole: completionRole,
                options: plan.captureOptions
            )
                ? .started
                : .unavailable(
                    "The clipboard does not contain an image."
                )
        case .existing(.recentSnips),
             .existing(.captureHistory),
             .existing(.archive):
            return .awaitingExistingSelection
        case .scrolling:
            capture.captureScrollingArea(
                intent: .newDocument,
                completionRole: completionRole,
                oneShotOptions: plan.captureOptions
            )
        case .connectedDevice:
            return .awaitingConnectedDeviceSelection
        case .screenInspector:
            let context = capture.prepareScreenInspectorCaptureIntent(
                .newDocument,
                completionRole: completionRole,
                oneShotOptions: plan.captureOptions
            )
            tools.presentScreenInspector {
                guard let sessionID =
                    context.persistentSurfaceSessionID else {
                    return
                }
                capture.resetPersistentCaptureSurfaceSession(sessionID)
            }
        }

        return .started
    }
}
