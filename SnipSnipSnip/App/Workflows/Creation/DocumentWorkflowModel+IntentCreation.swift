import AppKit
import CoreGraphics
import Foundation
import ImageIO

private enum PreparedIntentCreationSource {
    case capture(
        url: URL?,
        capture: CapturedScreenshot,
        isPrivate: Bool
    )
    case editableDocument(
        url: URL?,
        document: EditableScreenshotDocument
    )

    var url: URL? {
        switch self {
        case .capture(let url, _, _),
             .editableDocument(let url, _):
            return url
        }
    }
}

private struct IntentCreationPreparation {
    var sources: [PreparedIntentCreationSource] = []
    var failures: [CompositionImportFailure] = []
}

private enum IntentCreationSourcePolicy: Equatable {
    case editableBatch
    case oneFlattenedScreenshot
}

@MainActor
extension DocumentWorkflowModel {
    @discardableResult
    func createDocumentFromFiles(
        completionRole: CaptureCompletionRole,
        options: CaptureOneShotOptions
    ) -> Bool {
        let urls: [URL]
        if completionRole == .standalone {
            urls = dependencies.panels
                .selectSingleCompositionSourceToImport()
                .map { [$0] } ?? []
        } else {
            urls = dependencies.panels.selectImagesToImport()
        }
        guard !urls.isEmpty else {
            return false
        }

        return createDocumentFromFiles(
            urls,
            completionRole: completionRole,
            options: options
        )
    }

    /// URL-based entry point shared by the panel and deterministic workflow
    /// tests. Screenshot creation deliberately consumes at most one source and
    /// rasterizes editable packages so a hidden composition can never survive
    /// behind the one-image editor.
    @discardableResult
    func createDocumentFromFiles(
        _ urls: [URL],
        completionRole: CaptureCompletionRole,
        options: CaptureOneShotOptions
    ) -> Bool {
        guard !urls.isEmpty else {
            return false
        }
        let sourcePolicy: IntentCreationSourcePolicy =
            completionRole == .standalone
                ? .oneFlattenedScreenshot
                : .editableBatch
        let selectedURLs =
            sourcePolicy == .oneFlattenedScreenshot
                ? Array(urls.prefix(1))
                : urls
        guard let preparation = prepareIntentCreationSources(
            selectedURLs,
            forcePrivate: options.privateCapture,
            policy: sourcePolicy
        ) else {
            return false
        }
        return installPreparedIntentCreationSources(
            preparation,
            completionRole: completionRole
        )
    }

    @discardableResult
    func createDocumentFromClipboard(
        completionRole: CaptureCompletionRole,
        options: CaptureOneShotOptions
    ) -> Bool {
        guard let image = NSImage(pasteboard: .general),
              let cgImage = image.cgImage(
                forProposedRect: nil,
                context: nil,
                hints: nil
              ) else {
            return false
        }
        let capture = intentCreationCapture(
            image: cgImage,
            sourceName: "Pasted Image"
        )
        return installPreparedIntentCreationSources(
            IntentCreationPreparation(
                sources: [
                    .capture(
                        url: nil,
                        capture: capture,
                        isPrivate: options.privateCapture
                    )
                ]
            ),
            completionRole: completionRole
        )
    }

    /// Installs an exact Recent Snip or Snip History choice as the
    /// first source for a pending intent-driven creation plan. The caller owns
    /// exact-item selection; this method never substitutes another entry.
    @discardableResult
    func createDocument(
        from entry: DocumentHistoryEntry,
        flattened: Bool = false,
        completionRole: CaptureCompletionRole,
        forcePrivate: Bool = false
    ) -> Bool {
        do {
            let source: PreparedIntentCreationSource
            if flattened || completionRole == .standalone {
                guard let preview = try SSSDocumentPackage.loadDisplayPreview(
                    from: entry.packageURL,
                    allowsExternalRecoveryBase: true,
                    files: systemServices.files
                )?.image else {
                    throw IntentCreationImportError.invalidImage
                }
                let recoveredDocument =
                    try? recoveryStore.restoreDocument(from: entry)
                source = .capture(
                    url: entry.packageURL,
                    capture: intentCreationCapture(
                        image: preview,
                        sourceName: entry.title
                    ),
                    // A display preview can remain readable when an older
                    // editable checkpoint is damaged. If privacy provenance
                    // cannot be proven public, conservatively retain it.
                    isPrivate: forcePrivate
                        || (recoveredDocument?.isPrivate ?? true)
                )
            } else {
                var document = try recoveryStore.restoreDocument(from: entry)
                if forcePrivate {
                    document.isPrivate = true
                }
                source = .editableDocument(
                    url: entry.packageURL,
                    document: document
                )
            }
            return installPreparedIntentCreationSources(
                IntentCreationPreparation(sources: [source]),
                completionRole: completionRole
            )
        } catch {
            present(error)
            return false
        }
    }

    private func prepareIntentCreationSources(
        _ urls: [URL],
        forcePrivate: Bool,
        policy: IntentCreationSourcePolicy
    ) -> IntentCreationPreparation? {
        var preparation = IntentCreationPreparation()
        for url in urls {
            if url.pathExtension.lowercased() == "sss" {
                do {
                    var document = try withSecurityScopedAccess(to: url) {
                        try SSSDocumentPackage.load(
                            from: url,
                            files: systemServices.files
                        )
                    }
                    if forcePrivate {
                        document.isPrivate = true
                    }
                    let choice: CompositionEditableImportChoice
                    switch policy {
                    case .oneFlattenedScreenshot:
                        choice = .flattened
                    case .editableBatch:
                        let itemCount =
                            document.session.currentSnapshot.composition?.items
                                .count ?? 1
                        choice = itemCount > 1
                            ? compositionEditableImportChoiceHandler(itemCount)
                            : .editable
                    }
                    switch choice {
                    case .editable:
                        preparation.sources.append(
                            .editableDocument(
                                url: url,
                                document: document
                            )
                        )
                    case .flattened:
                        guard let preview = try withSecurityScopedAccess(
                            to: url,
                            perform: {
                                try SSSDocumentPackage.loadDisplayPreview(
                                    from: url,
                                    allowsExternalRecoveryBase: false,
                                    files: systemServices.files
                                )?.image
                            }
                        ) else {
                            throw IntentCreationImportError.invalidImage
                        }
                        preparation.sources.append(
                            .capture(
                                url: url,
                                capture: intentCreationCapture(
                                    image: preview,
                                    sourceName: url.deletingPathExtension()
                                        .lastPathComponent
                                ),
                                isPrivate: document.isPrivate || forcePrivate
                            )
                        )
                    case .cancel:
                        // All editable/flattened choices are resolved before
                        // replacing the current document.
                        return nil
                    }
                } catch {
                    preparation.failures.append(
                        CompositionImportFailure(
                            url: url,
                            reason: intentCreationErrorDescription(error)
                        )
                    )
                }
                continue
            }

            do {
                let image = try withSecurityScopedAccess(to: url) {
                    guard let source = CGImageSourceCreateWithURL(
                        url as CFURL,
                        nil
                    ),
                          let image = CGImageSourceCreateImageAtIndex(
                            source,
                            0,
                            nil
                          ) else {
                        throw IntentCreationImportError.invalidImage
                    }
                    return image
                }
                preparation.sources.append(
                    .capture(
                        url: url,
                        capture: intentCreationCapture(
                            image: image,
                            sourceName: url.deletingPathExtension()
                                .lastPathComponent
                        ),
                        isPrivate: forcePrivate
                    )
                )
            } catch {
                preparation.failures.append(
                    CompositionImportFailure(
                        url: url,
                        reason: intentCreationErrorDescription(error)
                    )
                )
            }
        }
        return preparation
    }

    private func installPreparedIntentCreationSources(
        _ preparation: IntentCreationPreparation,
        completionRole: CaptureCompletionRole
    ) -> Bool {
        guard let first = preparation.sources.first else {
            if preparation.failures.isEmpty {
                presentError("No selected image could be added.")
            } else {
                presentError(
                    intentCreationFailureSummary(preparation.failures)
                )
            }
            return false
        }

        do {
            let controller = try makeIntentCreationController(
                from: first,
                completionRole: completionRole
            )

            // No current document is shelved until every user choice has been
            // resolved and the first valid source has produced a controller.
            shelveCurrentDocumentForRecents()
            installEditorController(
                controller,
                documentURL: nil,
                savedSession: nil,
                shouldCreateRecoverySession: !controller.isPrivateDocument,
                initialCheckpointLabel: controller.isPrivateDocument
                    ? nil : "Import"
            )

            var failures = preparation.failures
            var installedCount = 1
            controller.beginCoalescedEditorGesture()
            for source in preparation.sources.dropFirst() {
                do {
                    switch source {
                    case .capture(_, let capture, let isPrivate):
                        _ = try controller.appendCaptureToComposition(
                            capture,
                            isPrivate: isPrivate
                        )
                    case .editableDocument(_, let document):
                        try controller.appendEditableDocument(document)
                    }
                    installedCount += 1
                } catch {
                    failures.append(
                        CompositionImportFailure(
                            url: source.url
                                ?? URL(fileURLWithPath: "/Imported Image"),
                            reason: intentCreationErrorDescription(error)
                        )
                    )
                }
            }

            var focusedRole = completionRole
            if completionRole == .comparisonBefore,
               controller.includedCompositionItemCount >= 2 {
                focusedRole = .comparisonAfter
            }
            if installedCount > 1 {
                applyCaptureCompletionRole(
                    focusedRole,
                    afterAppendingTo: controller
                )
            } else if focusedRole == .comparisonAfter {
                // A single editable package can already contain a valid A/B
                // pair. Its session was configured before construction, so
                // only resume navigation needs updating here.
                controller.setWorkflowStage(.reviewingComparison)
            }
            controller.endCoalescedEditorGesture()
            routeToFocusedContentWorkspace(
                for: focusedRole,
                in: controller
            )

            if failures.isEmpty {
                pendingCompositionImportRecovery = nil
            } else {
                pendingCompositionImportRecovery =
                    CompositionImportRecoveryState(
                        documentGenerationID:
                            controller.documentGenerationID,
                        successfulSourceCount: installedCount,
                        failures: failures,
                        retryDestination: .insert(
                            afterItemID:
                                controller.composition?.items.last?.id
                        )
                    )
            }

            if controller.isPrivateDocument {
                excludeCurrentPrivateDocumentFromRecoveryAndHistory()
            }
            updateDocumentChangeTracking()
            requestMainWindowPresentation()
            if preparation.sources.count > 1 || !failures.isEmpty {
                let summary = String(
                    localized:
                        "Added: \(installedCount). Failed: \(failures.count)."
                )
                controller.showNotice(
                    EditorNotice(
                        message: summary,
                        accessibilityAnnouncement: String(
                            localized: "Import complete. \(summary)"
                        ),
                        dismissalDelaySeconds: failures.isEmpty ? 4 : 7
                    )
                )
            }
            return true
        } catch {
            present(error)
            return false
        }
    }

    private func makeIntentCreationController(
        from source: PreparedIntentCreationSource,
        completionRole: CaptureCompletionRole
    ) throws -> EditorController {
        let workflow = captureWorkflowConfiguration(for: completionRole)
        switch source {
        case .capture(_, let capture, let isPrivate):
            return EditorController(
                capture: capture,
                capabilities: capabilities,
                uiMapOverlayOptions: uiMapPinnedOverlayDefaults,
                isPrivateDocument: isPrivate,
                documentPurpose: workflow.purpose,
                workflowResumeState: workflow.resumeState
            )
        case .editableDocument(_, let document):
            let session = intentCreationSession(
                document.session,
                purpose: workflow.purpose
            )
            return EditorController(
                capture: document.capture,
                session: session,
                capabilities: capabilities,
                uiMapOverlayOptions: uiMapPinnedOverlayDefaults,
                isPrivateDocument: document.isPrivate,
                workflowResumeState: workflow.resumeState,
                sourceDocumentFormatVersion:
                    document.sourceFormatVersion,
                compositionStoredAssets:
                    document.compositionStoredAssets
            )
        }
    }

    private func intentCreationSession(
        _ session: EditorDocumentSession,
        purpose: ScreenshotDocumentPurpose
    ) -> EditorDocumentSession {
        func configured(_ snapshot: EditorSnapshot) -> EditorSnapshot {
            var updated = snapshot
            updated.documentPurpose = purpose
            guard var composition = updated.composition else {
                return updated
            }
            switch purpose {
            case .screenshot:
                break
            case .comparison:
                if composition.items.count > 1 {
                    composition.layout.mode = .compare
                    composition.isActivated = true
                } else {
                    composition.layout.mode = .auto
                    composition.isActivated = false
                }
            case .steps:
                composition.layout.mode = .steps
                composition.isActivated = true
            case .collection:
                composition.layout.mode = .auto
                composition.isActivated = true
            }
            composition.repairComparisonSelection()
            updated.composition = composition
            return updated
        }

        return EditorDocumentSession(
            initialSnapshot: configured(session.initialSnapshot),
            currentSnapshot: configured(session.currentSnapshot),
            undoStack: session.undoStack.map(configured),
            redoStack: session.redoStack.map(configured),
            toolStyles: session.toolStyles,
            savedPresentations: session.savedPresentations
        )
    }

    private func intentCreationCapture(
        image: CGImage,
        sourceName: String
    ) -> CapturedScreenshot {
        CapturedScreenshot(
            image: image,
            kind: .region,
            sourceName: sourceName,
            sourceRect: CGRect(
                origin: .zero,
                size: CGSize(width: image.width, height: image.height)
            ),
            capturedAt: systemServices.clock.now()
        )
    }

    private func intentCreationErrorDescription(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
    }

    private func intentCreationFailureSummary(
        _ failures: [CompositionImportFailure]
    ) -> String {
        let heading = String(
            localized:
                "Added: 0. Failed: \(failures.count)."
        )
        let details = failures.map {
            "\($0.url.lastPathComponent): \($0.reason)"
        }
        return ([heading] + details).joined(separator: "\n")
    }
}

private enum IntentCreationImportError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        "The selected file could not be loaded as an image."
    }
}
