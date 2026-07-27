import AppKit
import CoreGraphics
import Foundation
import ImageIO

nonisolated enum CompositionEditableImportChoice {
    case editable
    case flattened
    case cancel
}

nonisolated struct CompositionImportFailure: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    let reason: String

    init(id: UUID = UUID(), url: URL, reason: String) {
        self.id = id
        self.url = url
        self.reason = reason
    }
}

nonisolated struct CompositionImportRecoveryState:
    Identifiable,
    Equatable,
    Sendable
{
    let id: UUID
    let documentGenerationID: UUID
    let successfulSourceCount: Int
    let failures: [CompositionImportFailure]
    let retryDestination: CompositionFileDropDestination

    init(
        id: UUID = UUID(),
        documentGenerationID: UUID,
        successfulSourceCount: Int,
        failures: [CompositionImportFailure],
        retryDestination: CompositionFileDropDestination
    ) {
        self.id = id
        self.documentGenerationID = documentGenerationID
        self.successfulSourceCount = successfulSourceCount
        self.failures = failures
        self.retryDestination = retryDestination
    }

    var summary: String {
        String(localized: "Added: \(successfulSourceCount). Failed: \(failures.count).")
    }
}

private enum PlannedCompositionImport {
    case image(URL)
    case editableDocument(URL, EditableScreenshotDocument)
    case flattenedDocument(URL, EditableScreenshotDocument)
    case failure(CompositionImportFailure)
}

private struct CompositionSourceImportResult {
    let lastItemID: UUID?
    let didImport: Bool
}

private struct CompositionImportedImageLoadError: LocalizedError {
    var errorDescription: String? {
        "The selected file could not be loaded as an image."
    }
}

extension DocumentWorkflowModel {
    func addImagesToCurrentCompositionPanel(
        completionRole: CaptureCompletionRole = .standalone
    ) {
        let urls = dependencies.panels.selectImagesToImport()
        guard !urls.isEmpty else {
            return
        }
        addFilesToCurrentComposition(
            urls,
            completionRole: completionRole
        )
    }

    func addFilesToCurrentComposition(
        _ urls: [URL],
        completionRole: CaptureCompletionRole = .standalone
    ) {
        guard let controller = editorController else {
            presentError("Open or capture a screenshot before adding images to a composition.")
            return
        }
        handleCompositionFileDrop(
            urls,
            destination: .insert(
                afterItemID: controller.composition?.items.last?.id
            ),
            completionRole: completionRole
        )
    }

    func locateCompositionItemSource(_ itemID: UUID) {
        guard let url = dependencies.panels.selectImageToImport() else {
            return
        }
        handleCompositionFileDrop([url], destination: .replace(itemID: itemID))
    }

    func handleCompositionFileDrop(
        _ urls: [URL],
        destination: CompositionFileDropDestination,
        completionRole: CaptureCompletionRole = .standalone
    ) {
        guard !urls.isEmpty else {
            return
        }
        guard let controller = editorController else {
            presentError("Open or capture a screenshot before adding images to a composition.")
            return
        }
        guard let plan = planCompositionImports(urls) else {
            return
        }

        performCompositionImports(
            plan,
            into: controller,
            destination: destination,
            completionRole: completionRole
        )
    }

    func retryFailedCompositionImports() {
        guard let recovery = pendingCompositionImportRecovery,
              let controller = editorController else {
            return
        }
        guard controller.documentGenerationID == recovery.documentGenerationID else {
            presentError("The composition changed before the failed imports could be retried.")
            return
        }
        guard isValidCompositionImportDestination(
            recovery.retryDestination,
            in: controller
        ) else {
            presentError("The original import position is no longer available. Add the files again to choose a new position.")
            return
        }

        let urls = recovery.failures.map(\.url)
        guard let plan = planCompositionImports(urls) else {
            return
        }
        performCompositionImports(
            plan,
            into: controller,
            destination: recovery.retryDestination,
            alwaysAnnouncesResult: true
        )
    }

    func dismissCompositionImportRecovery() {
        pendingCompositionImportRecovery = nil
    }

    private func planCompositionImports(
        _ urls: [URL]
    ) -> [PlannedCompositionImport]? {
        var plan: [PlannedCompositionImport] = []
        plan.reserveCapacity(urls.count)

        for url in urls {
            guard url.pathExtension.lowercased() == "sss" else {
                plan.append(.image(url))
                continue
            }

            do {
                let document = try withSecurityScopedAccess(to: url) {
                    try SSSDocumentPackage.load(
                        from: url,
                        files: systemServices.files
                    )
                }
                let itemCount =
                    document.session.currentSnapshot.composition?.items.count
                    ?? 1
                let choice = itemCount > 1
                    ? compositionEditableImportChoiceHandler(itemCount)
                    : .editable
                switch choice {
                case .editable:
                    plan.append(.editableDocument(url, document))
                case .flattened:
                    plan.append(.flattenedDocument(url, document))
                case .cancel:
                    // Resolve every user choice before applying any source so
                    // cancellation cannot leave a partially mutated document.
                    return nil
                }
            } catch {
                plan.append(.failure(importFailure(for: url, error: error)))
            }
        }

        return plan
    }

    private func performCompositionImports(
        _ plan: [PlannedCompositionImport],
        into controller: EditorController,
        destination: CompositionFileDropDestination,
        alwaysAnnouncesResult: Bool = false,
        completionRole: CaptureCompletionRole = .standalone,
        initialSuccessCount: Int = 0,
        initialFailures: [CompositionImportFailure] = []
    ) {
        var insertionCursor: UUID?
        var replacementItemID: UUID?
        switch destination {
        case .insert(let afterItemID):
            insertionCursor = afterItemID
        case .replace(let itemID):
            replacementItemID = itemID
            insertionCursor = itemID
        }

        var failures = initialFailures
        var successCount = initialSuccessCount
        controller.beginCoalescedEditorGesture()
        for source in plan {
            switch source {
            case .failure(let failure):
                failures.append(failure)
            default:
                do {
                    let result = try importPlannedCompositionSource(
                        source,
                        into: controller,
                        afterItemID: insertionCursor,
                        replacingItemID: replacementItemID
                    )
                    guard result.didImport else {
                        continue
                    }
                    successCount += 1
                    insertionCursor = result.lastItemID ?? insertionCursor
                    replacementItemID = nil
                } catch {
                    failures.append(
                        importFailure(
                            for: source.url,
                            error: error
                        )
                    )
                }
            }
        }
        var focusedCompletionRole: CaptureCompletionRole?
        if successCount > 0 {
            let effectiveCompletionRole: CaptureCompletionRole
            if case .replace = destination,
               completionRole == .standalone {
                effectiveCompletionRole = .replacement
            } else {
                effectiveCompletionRole = completionRole
            }
            applyCaptureCompletionRole(
                effectiveCompletionRole,
                afterAppendingTo: controller
            )
            focusedCompletionRole = effectiveCompletionRole
        }
        controller.endCoalescedEditorGesture()
        if let focusedCompletionRole {
            routeToFocusedContentWorkspace(
                for: focusedCompletionRole,
                in: controller
            )
        }

        let retryDestination: CompositionFileDropDestination
        if let replacementItemID {
            retryDestination = .replace(itemID: replacementItemID)
        } else {
            retryDestination = .insert(afterItemID: insertionCursor)
        }

        if failures.isEmpty {
            pendingCompositionImportRecovery = nil
        } else {
            pendingCompositionImportRecovery = CompositionImportRecoveryState(
                documentGenerationID: controller.documentGenerationID,
                successfulSourceCount: successCount,
                failures: failures,
                retryDestination: retryDestination
            )
        }

        if successCount > 0 {
            if controller.isPrivateDocument {
                excludeCurrentPrivateDocumentFromRecoveryAndHistory()
            }
            updateDocumentChangeTracking()
            requestMainWindowPresentation()
        }

        if alwaysAnnouncesResult || plan.count > 1 || !failures.isEmpty {
            let summary = String(
                localized: "Added: \(successCount). Failed: \(failures.count)."
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
    }

    private func importPlannedCompositionSource(
        _ source: PlannedCompositionImport,
        into controller: EditorController,
        afterItemID: UUID?,
        replacingItemID: UUID?
    ) throws -> CompositionSourceImportResult {
        switch source {
        case .editableDocument(_, let document):
            let lastItemID = try controller.appendEditableDocument(
                document,
                afterItemID: afterItemID,
                replacingItemID: replacingItemID
            )
            return CompositionSourceImportResult(
                lastItemID: lastItemID,
                didImport: lastItemID != nil
            )
        case .flattenedDocument(let url, let document):
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
                throw CompositionImportedImageLoadError()
            }
            let capture = importedCompositionCapture(
                image: preview,
                sourceName: url.deletingPathExtension().lastPathComponent
            )
            let insertion = try insertImportedCompositionCapture(
                capture,
                isPrivate: document.isPrivate,
                into: controller,
                afterItemID: afterItemID,
                replacingItemID: replacingItemID
            )
            return CompositionSourceImportResult(
                lastItemID: insertion.itemID,
                didImport: true
            )
        case .image(let url):
            let image = try withSecurityScopedAccess(to: url) {
                guard let source = CGImageSourceCreateWithURL(
                    url as CFURL,
                    nil
                ),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
                else {
                    throw CompositionImportedImageLoadError()
                }
                return image
            }
            let capture = importedCompositionCapture(
                image: image,
                sourceName: url.deletingPathExtension().lastPathComponent
            )
            let insertion = try insertImportedCompositionCapture(
                capture,
                isPrivate: false,
                into: controller,
                afterItemID: afterItemID,
                replacingItemID: replacingItemID
            )
            return CompositionSourceImportResult(
                lastItemID: insertion.itemID,
                didImport: true
            )
        case .failure:
            return CompositionSourceImportResult(
                lastItemID: nil,
                didImport: false
            )
        }
    }

    private func insertImportedCompositionCapture(
        _ capture: CapturedScreenshot,
        isPrivate: Bool,
        into controller: EditorController,
        afterItemID: UUID?,
        replacingItemID: UUID?
    ) throws -> CompositionInsertionResult {
        if let replacingItemID {
            return try controller.replaceCompositionItem(
                itemID: replacingItemID,
                with: capture,
                isPrivate: isPrivate
            )
        }
        return try controller.appendCaptureToComposition(
            capture,
            isPrivate: isPrivate,
            afterItemID: afterItemID
        )
    }

    private func importedCompositionCapture(
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

    private func importFailure(
        for url: URL,
        error: Error
    ) -> CompositionImportFailure {
        CompositionImportFailure(
            url: url,
            reason: (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        )
    }

    private func isValidCompositionImportDestination(
        _ destination: CompositionFileDropDestination,
        in controller: EditorController
    ) -> Bool {
        switch destination {
        case .insert(let afterItemID):
            guard let afterItemID else {
                return true
            }
            return controller.composition?.items.contains {
                $0.id == afterItemID
            } == true
        case .replace(let itemID):
            return controller.composition?.items.contains {
                $0.id == itemID
            } == true
        }
    }

    static func presentCompositionEditableImportChoice(
        itemCount: Int
    ) -> CompositionEditableImportChoice {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Add Multi-Item Composition"
        alert.informativeText = "This document contains \(itemCount) editable items. Add every item with its edits intact, or add one flattened rendering."
        alert.addButton(withTitle: "Add Editable Items")
        alert.addButton(withTitle: "Add as Flattened Item")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .editable
        case .alertSecondButtonReturn:
            return .flattened
        default:
            return .cancel
        }
    }

    func pasteImageIntoCurrentComposition(
        completionRole: CaptureCompletionRole = .standalone
    ) {
        guard editorController != nil else {
            presentError("Open or capture a screenshot before pasting into a composition.")
            return
        }
        guard let image = NSImage(pasteboard: .general),
              let cgImage = image.cgImage(
                forProposedRect: nil,
                context: nil,
                hints: nil
              ) else {
            presentError("The clipboard does not contain an image.")
            return
        }

        pasteImageIntoCurrentComposition(
            cgImage,
            completionRole: completionRole
        )
    }

    /// Image-based entry point keeps paste installation and navigation in one
    /// testable transaction without coupling focused workflow tests to the
    /// process-wide pasteboard.
    func pasteImageIntoCurrentComposition(
        _ cgImage: CGImage,
        completionRole: CaptureCompletionRole = .standalone
    ) {
        guard let controller = editorController else {
            presentError(
                "Open or capture a screenshot before pasting into a composition."
            )
            return
        }

        do {
            let capture = CapturedScreenshot(
                image: cgImage,
                kind: .region,
                sourceName: "Pasted Image",
                sourceRect: CGRect(
                    origin: .zero,
                    size: CGSize(width: cgImage.width, height: cgImage.height)
                ),
                capturedAt: systemServices.clock.now()
            )
            controller.beginCoalescedEditorGesture()
            _ = try controller.appendCaptureToComposition(
                capture,
                isPrivate: false
            )
            applyCaptureCompletionRole(
                completionRole,
                afterAppendingTo: controller
            )
            controller.endCoalescedEditorGesture()
            routeToFocusedContentWorkspace(
                for: completionRole,
                in: controller
            )
            updateDocumentChangeTracking()
            requestMainWindowPresentation()
        } catch {
            controller.cancelCoalescedEditorGesture()
            present(error)
        }
    }

    func addHistoryEntryToCurrentComposition(
        _ entry: DocumentHistoryEntry,
        flattened: Bool = false,
        completionRole: CaptureCompletionRole = .standalone
    ) {
        guard let controller = editorController else {
            presentError("Open or capture a screenshot before adding history to a composition.")
            return
        }

        do {
            controller.beginCoalescedEditorGesture()
            if flattened {
                guard let preview = try SSSDocumentPackage.loadDisplayPreview(
                    from: entry.packageURL,
                    allowsExternalRecoveryBase: true,
                    files: systemServices.files
                )?.image else {
                    throw CompositionImportedImageLoadError()
                }
                let capture = CapturedScreenshot(
                    image: preview,
                    kind: .region,
                    sourceName: entry.title,
                    sourceRect: CGRect(
                        origin: .zero,
                        size: CGSize(
                            width: preview.width,
                            height: preview.height
                        )
                    ),
                    capturedAt: entry.savedAt
                )
                _ = try controller.appendCaptureToComposition(
                    capture,
                    isPrivate: false
                )
            } else {
                let document = try recoveryStore.restoreDocument(from: entry)
                try controller.appendEditableDocument(document)
            }
            applyCaptureCompletionRole(
                completionRole,
                afterAppendingTo: controller
            )
            controller.endCoalescedEditorGesture()
            routeToFocusedContentWorkspace(
                for: completionRole,
                in: controller
            )
            if controller.isPrivateDocument {
                excludeCurrentPrivateDocumentFromRecoveryAndHistory()
            }
            updateDocumentChangeTracking()
            requestMainWindowPresentation()
        } catch {
            controller.cancelCoalescedEditorGesture()
            present(error)
        }
    }
}

private extension PlannedCompositionImport {
    var url: URL {
        switch self {
        case .image(let url),
             .editableDocument(let url, _),
             .flattenedDocument(let url, _):
            url
        case .failure(let failure):
            failure.url
        }
    }
}
