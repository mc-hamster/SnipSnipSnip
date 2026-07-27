import Foundation

@MainActor
extension AppModelComposition {
    static func makeCreationWorkflow(
        capabilities: AppCapabilitySnapshot,
        capture: CaptureWorkflowModel,
        documents: DocumentWorkflowModel,
        guide: GuideWorkflowModel,
        tools: ToolWorkflowModel
    ) -> CreationWorkflowModel {
        let creation = CreationWorkflowModel(
            capabilities: capabilities,
            defaultDraftProvider: { [weak capture] in
                guard let capture else {
                    return .default
                }
                return CreationDraft(
                    captureDelay: capture.captureDelay,
                    includesCursor: capture.screenshotIncludesCursor,
                    privateCapture: capture.privateCaptureEnabled,
                    windowUIMapEnabled: capture.windowUIMapEnabled
                )
            }
        )
        let starter = CreationPlanStarter(
            capture: capture,
            documents: documents,
            guide: guide,
            tools: tools
        )
        creation.startHandler = { plan in
            starter.start(plan)
        }
        creation.connectedDeviceSelectionHandler = { device, plan in
            capture.captureConnectedDevice(
                device,
                intent: .newDocument,
                completionRole:
                    plan.captureCompletionRole ?? .standalone,
                oneShotOptions: plan.captureOptions
            )
        }
        return creation
    }
}
