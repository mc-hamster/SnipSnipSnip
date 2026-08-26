import CoreGraphics
import Foundation

@MainActor
extension CaptureWorkflowModel {
    var activeCaptureIntent: CaptureIntent {
        get { activeCaptureContext.intent }
        set {
            if newValue == .newDocument {
                activeCaptureContext = .standalone
            } else {
                activeCaptureContext.intent = newValue
            }
        }
    }

    var activeCaptureCompletionRole: CaptureCompletionRole {
        activeCaptureContext.role
    }

    func prepareCaptureIntent(
        _ intent: CaptureIntent,
        completionRole: CaptureCompletionRole = .standalone,
        oneShotOptions: CaptureOneShotOptions? = nil
    ) {
        prepareCaptureIntent(
            intent,
            completionRole: completionRole,
            oneShotOptions: oneShotOptions,
            presentationContext: .application
        )
    }

    func prepareCaptureIntent(
        _ intent: CaptureIntent,
        completionRole: CaptureCompletionRole = .standalone,
        oneShotOptions: CaptureOneShotOptions? = nil,
        presentationContext: WorkflowPresentationContext
    ) {
        activeCaptureContext = CaptureCompletionContext(
            intent: intent,
            role: completionRole,
            oneShotOptions: oneShotOptions,
            presentationContext: presentationContext
        )
    }

    @discardableResult
    func preparePersistentCaptureSurfaceIntent(
        _ intent: CaptureIntent,
        completionRole: CaptureCompletionRole = .standalone,
        oneShotOptions: CaptureOneShotOptions? = nil
    ) -> CaptureCompletionContext {
        let context = CaptureCompletionContext(
            intent: intent,
            role: completionRole,
            oneShotOptions: oneShotOptions,
            persistentSurfaceSessionID: UUID()
        )
        activeCaptureContext = context
        return context
    }

    @discardableResult
    func prepareScreenInspectorCaptureIntent(
        _ intent: CaptureIntent,
        completionRole: CaptureCompletionRole = .standalone,
        oneShotOptions: CaptureOneShotOptions? = nil
    ) -> CaptureCompletionContext {
        let context = preparePersistentCaptureSurfaceIntent(
            intent,
            completionRole: completionRole,
            oneShotOptions: oneShotOptions
        )
        screenInspectorCaptureContext = context
        return context
    }

    func resetPersistentCaptureSurfaceSession(_ sessionID: UUID) {
        if activeCaptureContext.persistentSurfaceSessionID == sessionID {
            activeCaptureContext = .standalone
        }
        if screenInspectorCaptureContext?
            .persistentSurfaceSessionID == sessionID {
            screenInspectorCaptureContext = nil
        }
    }

    /// Advances a live acquisition surface after the coordinator has installed
    /// the completed capture. Steps and collections remain in a seamless
    /// append loop, Comparison advances Before to After, and one-shot Create
    /// Screenshot/Replace sessions end after their successful result.
    func persistentSurfaceContinuationContext(
        after completedContext: CaptureCompletionContext
    ) -> CaptureCompletionContext? {
        guard let sessionID =
            completedContext.persistentSurfaceSessionID
        else {
            return nil
        }

        switch completedContext.role {
        case .standalone:
            if completedContext.oneShotOptions != nil,
               completedContext.intent == .newDocument {
                return nil
            }
            switch completedContext.intent {
            case .newDocument:
                return completedContext
            case .append:
                return persistentAppendContext(
                    from: completedContext,
                    role: .standalone,
                    expectedPurpose: nil,
                    sessionID: sessionID
                )
            case .replace:
                return nil
            }
        case .comparisonBefore:
            return persistentAppendContext(
                from: completedContext,
                role: .comparisonAfter,
                expectedPurpose: .comparison,
                sessionID: sessionID
            )
        case .comparisonAfter, .replacement:
            return nil
        case .step:
            return persistentAppendContext(
                from: completedContext,
                role: .step,
                expectedPurpose: .steps,
                sessionID: sessionID
            )
        case .collectionItem:
            return persistentAppendContext(
                from: completedContext,
                role: .collectionItem,
                expectedPurpose: .collection,
                sessionID: sessionID
            )
        }
    }

    private func persistentAppendContext(
        from completedContext: CaptureCompletionContext,
        role: CaptureCompletionRole,
        expectedPurpose: ScreenshotDocumentPurpose?,
        sessionID: UUID
    ) -> CaptureCompletionContext? {
        guard let controller = documents?.activeCaptureEditorController else {
            return nil
        }
        if let expectedPurpose,
           controller.documentPurpose != expectedPurpose {
            return nil
        }
        switch completedContext.intent {
        case .newDocument:
            break
        case .append(let documentGenerationID, _),
             .replace(let documentGenerationID, _):
            guard controller.documentGenerationID == documentGenerationID
            else {
                return nil
            }
        }

        return CaptureCompletionContext(
            intent: .append(
                documentGenerationID: controller.documentGenerationID,
                afterItemID: controller.composition?.items.last?.id
            ),
            role: role,
            oneShotOptions: completedContext.oneShotOptions,
            presentationContext: completedContext.presentationContext,
            persistentSurfaceSessionID: sessionID
        )
    }

    func resetPreparedCaptureIntent(ifMatching intent: CaptureIntent) {
        guard activeCaptureIntent == intent else {
            return
        }
        activeCaptureContext = .standalone
    }

    func resetPreparedCaptureContext(
        ifMatching context: CaptureCompletionContext
    ) {
        guard activeCaptureContext == context else {
            return
        }
        activeCaptureContext = .standalone
    }

    func captureCurrentDisplay(
        intent: CaptureIntent,
        completionRole: CaptureCompletionRole = .standalone,
        oneShotOptions: CaptureOneShotOptions? = nil
    ) {
        captureCurrentDisplay(
            intent: intent,
            completionRole: completionRole,
            oneShotOptions: oneShotOptions,
            presentationContext: .application
        )
    }

    func captureCurrentDisplay(
        intent: CaptureIntent,
        completionRole: CaptureCompletionRole = .standalone,
        oneShotOptions: CaptureOneShotOptions? = nil,
        presentationContext: WorkflowPresentationContext
    ) {
        prepareCaptureIntent(
            intent,
            completionRole: completionRole,
            oneShotOptions: oneShotOptions,
            presentationContext: presentationContext
        )
        runScreenshotCaptureWhenPermissionsReady(
            for: .fullscreen,
            pendingCommand: .currentDisplay
        ) { [weak self] in
            self?.beginFullscreenCapture()
        }
    }

    func captureRegion(
        intent: CaptureIntent,
        completionRole: CaptureCompletionRole = .standalone,
        oneShotOptions: CaptureOneShotOptions? = nil
    ) {
        captureRegion(
            intent: intent,
            completionRole: completionRole,
            oneShotOptions: oneShotOptions,
            presentationContext: .application
        )
    }

    func captureRegion(
        intent: CaptureIntent,
        completionRole: CaptureCompletionRole = .standalone,
        oneShotOptions: CaptureOneShotOptions? = nil,
        presentationContext: WorkflowPresentationContext
    ) {
        prepareCaptureIntent(
            intent,
            completionRole: completionRole,
            oneShotOptions: oneShotOptions,
            presentationContext: presentationContext
        )
#if DEBUG
        if handleCompositionUITestRegionCaptureIfNeeded() {
            return
        }
#endif
        runScreenshotCaptureWhenPermissionsReady(
            for: .region(.zero),
            pendingCommand: .region
        ) { [weak self] in
            self?.beginRegionCapture()
        }
    }

    func captureFrontmostWindow(
        intent: CaptureIntent,
        completionRole: CaptureCompletionRole = .standalone,
        oneShotOptions: CaptureOneShotOptions? = nil
    ) {
        prepareCaptureIntent(
            intent,
            completionRole: completionRole,
            oneShotOptions: oneShotOptions
        )
        runScreenshotCaptureWhenPermissionsReady(
            for: .frontmostWindow,
            pendingCommand: .frontmostWindow
        ) { [weak self] in
            self?.beginFrontmostWindowCapture()
        }
    }

    func repeatLastCapture(
        intent: CaptureIntent,
        completionRole: CaptureCompletionRole = .standalone,
        oneShotOptions: CaptureOneShotOptions? = nil
    ) {
        repeatLastCapture(
            intent: intent,
            completionRole: completionRole,
            oneShotOptions: oneShotOptions,
            presentationContext: .application
        )
    }

    func repeatLastCapture(
        intent: CaptureIntent,
        completionRole: CaptureCompletionRole = .standalone,
        oneShotOptions: CaptureOneShotOptions? = nil,
        presentationContext: WorkflowPresentationContext
    ) {
        prepareCaptureIntent(
            intent,
            completionRole: completionRole,
            oneShotOptions: oneShotOptions,
            presentationContext: presentationContext
        )
        beginRepeatLastCapture()
    }

#if DEBUG
    private func handleCompositionUITestRegionCaptureIfNeeded() -> Bool {
        guard let outcome =
            CompositionUITestLaunchSupport.consumeRegionCaptureOutcome()
        else {
            return false
        }

        switch outcome {
        case .cancelled:
            let captureContext = activeCaptureContext
            resetPreparedCaptureContext(ifMatching: captureContext)
            if captureContext.presentationContext
                .shouldReturnToMainWindowAfterCancellation {
                dependencies.lifecycle.requestMainWindowPresentation()
            }
        case .captured(let capture),
             .staleDestination(let capture):
            if case .staleDestination = outcome {
                replaceActiveIntentWithStaleUITestDestination()
            }
            let captureContext = activeCaptureContext
            let runOptions = captureRunOptions(for: captureContext)
            let isPrivateCapture =
                captureContext.oneShotOptions?.privateCapture
                ?? privateCaptureEnabled
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                do {
                    try completeCapture(
                        capture,
                        request: .region(capture.sourceRect),
                        isPrivateCapture: isPrivateCapture,
                        shouldAttemptUIMapCapture: false,
                        runOptions: runOptions,
                        completionContext: captureContext
                    )
                } catch {
                    dependencies.lifecycle.presentError(
                        (error as? LocalizedError)?.errorDescription
                            ?? error.localizedDescription
                    )
                }
            }
        }
        return true
    }

    private func replaceActiveIntentWithStaleUITestDestination() {
        let staleDocumentGenerationID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000BAD"
        )!
        switch activeCaptureIntent {
        case .newDocument:
            activeCaptureIntent = .append(
                documentGenerationID: staleDocumentGenerationID,
                afterItemID: nil
            )
        case let .append(_, afterItemID):
            activeCaptureIntent = .append(
                documentGenerationID: staleDocumentGenerationID,
                afterItemID: afterItemID
            )
        case let .replace(_, itemID):
            activeCaptureIntent = .replace(
                documentGenerationID: staleDocumentGenerationID,
                itemID: itemID
            )
        }
    }
#endif
}
