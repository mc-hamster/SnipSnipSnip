import AppKit
import Foundation

extension ClipboardWorkflowModel {
    var clipboardHistoryItems: [ClipboardItem] {
        items
    }

    static func loadClipboardPreferences(from defaults: UserDefaults) -> ClipboardPreferences {
        AppPreferenceStores(storage: defaults).clipboard.loadPreferences()
    }

    func persistClipboardPreferences() {
        preferenceStore.savePreferences(preferences)
    }

    func showClipboardManager() {
        dependencies.managerPresenter.showClipboardManager(
            clipboard: self,
            workspace: dependencies.systemServices.workspace,
            bundleIdentifier: dependencies.systemServices.bundle.bundleIdentifier
        )
    }

    func updateClipboardHistoryEnabled(_ isEnabled: Bool) {
        var preferences = preferences
        preferences.isEnabled = isEnabled
        self.preferences = preferences
    }

    func updateClipboardMaxItemCount(_ value: Int) {
        var preferences = preferences
        preferences.maxItemCount = value
        self.preferences = preferences
    }

    func updateClipboardMaxStorageMB(_ value: Int) {
        var preferences = preferences
        preferences.maxStorageMB = value
        self.preferences = preferences
    }

    func addIgnoredClipboardApp(match: String) {
        addIgnoredClipboardApp(name: match, match: match)
    }

    func addIgnoredClipboardApp(_ app: ClipboardIgnoredApp) {
        addIgnoredClipboardApp(name: app.name, match: app.match)
    }

    func addIgnoredClipboardApp(name: String, match: String) {
        let normalizedMatch = match.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMatch.isEmpty else {
            return
        }

        var preferences = preferences
        let existingMatches = Set(preferences.ignoredApps.map { $0.match.localizedLowercase })
        guard !existingMatches.contains(normalizedMatch.localizedLowercase) else {
            return
        }

        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        preferences.ignoredApps.append(ClipboardIgnoredApp(
            name: normalizedName.isEmpty ? normalizedMatch : normalizedName,
            match: normalizedMatch
        ))
        self.preferences = preferences
    }

    var clipboardRunningAppIgnoreCandidates: [ClipboardIgnoredApp] {
        let currentBundleIdentifier = dependencies.systemServices.bundle.bundleIdentifier
        let candidates = dependencies.systemServices.workspace.runningApplications.compactMap { app -> ClipboardIgnoredApp? in
            guard app.activationPolicy == .regular,
                  app.bundleIdentifier != currentBundleIdentifier else {
                return nil
            }

            let name = app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? app.bundleIdentifier
            guard let name else {
                return nil
            }

            return ClipboardIgnoredApp(
                name: name,
                match: app.bundleIdentifier ?? name
            )
        }

        return filteredClipboardIgnoreCandidates(candidates)
    }

    var clipboardRecentSourceAppIgnoreCandidates: [ClipboardIgnoredApp] {
        let currentBundleIdentifier = dependencies.systemServices.bundle.bundleIdentifier
        let candidates = clipboardHistoryItems.compactMap { item -> ClipboardIgnoredApp? in
            guard let sourceApp = item.sourceApp,
                  sourceApp.bundleIdentifier != currentBundleIdentifier else {
                return nil
            }

            let match = sourceApp.bundleIdentifier ?? sourceApp.displayName
            return ClipboardIgnoredApp(name: sourceApp.displayName, match: match)
        }

        return filteredClipboardIgnoreCandidates(candidates)
    }

    func chooseIgnoredClipboardApp() {
        guard let app = dependencies.ignoredAppPresenter.selectIgnoredClipboardApp() else {
            return
        }

        addIgnoredClipboardApp(app)
    }

    func removeIgnoredClipboardApp(_ app: ClipboardIgnoredApp) {
        var preferences = preferences
        preferences.ignoredApps.removeAll { $0.id == app.id }
        self.preferences = preferences
    }

    func resetIgnoredClipboardApps() {
        var preferences = preferences
        preferences.ignoredApps = ClipboardPreferences.defaultIgnoredApps
        self.preferences = preferences
    }

    private func filteredClipboardIgnoreCandidates(_ candidates: [ClipboardIgnoredApp]) -> [ClipboardIgnoredApp] {
        let ignoredMatches = Set(preferences.ignoredApps.map(\.id))
        var seenMatches = Set<String>()

        return candidates
            .filter { !ignoredMatches.contains($0.id) }
            .filter { candidate in
                seenMatches.insert(candidate.id).inserted
            }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    func clearUnpinnedClipboardItems() {
        historyStore.clearUnpinned()
    }

    func clearClipboardHistory() {
        historyStore.clearAll()
    }

    func togglePinnedClipboardItem(_ item: ClipboardItem) {
        historyStore.togglePinned(item)
    }

    func deleteClipboardItem(_ item: ClipboardItem) {
        historyStore.delete(item)
    }

    func clipboardPreviewImage(for item: ClipboardItem) -> NSImage? {
        historyStore.image(for: item)
    }

    func copyClipboardItem(_ item: ClipboardItem, plainTextOnly: Bool = false) {
        copyItem(item, plainTextOnly: plainTextOnly)
    }

    func copyClipboardItemAsPlainText(_ item: ClipboardItem) {
        copyItemAsPlainText(item)
    }

    func pasteClipboardItem(_ item: ClipboardItem) {
        pasteItem(
            item,
            activatePreviousApplication: { [weak self] in
                self?.dependencies.managerPresenter.activatePreviousApplicationForPaste()
            },
            sendPasteKeystroke: Self.sendPasteKeystroke
        )
    }

    func pasteClipboardItemAsPlainText(_ item: ClipboardItem) {
        pasteItem(
            item,
            plainTextOnly: true,
            activatePreviousApplication: { [weak self] in
                self?.dependencies.managerPresenter.activatePreviousApplicationForPaste()
            },
            sendPasteKeystroke: Self.sendPasteKeystroke
        )
    }

    func openClipboardSnip(_ item: ClipboardItem) {
        guard case let .snip(_, sessionID, _) = item.kind,
              let sessionID,
              let documents else {
            return
        }

        documents.refreshRecoveryPresentationState()
        let candidates = documents.allCaptureHistoryEntries + documents.recentSnipEntries + documents.historyEntries
        guard let entry = candidates
            .filter({ $0.sessionID == sessionID })
            .sorted(by: { $0.savedAt > $1.savedAt })
            .first else {
            return
        }

        documents.restoreHistoryEntry(entry)
    }

    func recordClipboardSnip(
        from controller: EditorController,
        searchableText: String = "",
        sessionID: UUID? = nil
    ) {
        guard preferences.isEnabled,
              let image = controller.exportedImage(),
              let pngData = try? ImageExporter.pngData(for: image) else {
            return
        }

        let title = documents?.recoverySessionTitle(for: controller, documentURL: documents?.currentDocumentURL) ?? controller.capture.sourceName
        let searchText = [title, searchableText, controller.capture.sourceName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        historyStore.recordSnip(
            pngData: pngData,
            title: title,
            searchableText: searchText,
            sessionID: sessionID,
            preferences: preferences
        )
    }

    func scheduleClipboardSnipRecording(
        from controller: EditorController,
        searchableText: String = "",
        sessionID: UUID? = nil
    ) {
        guard preferences.isEnabled else {
            return
        }

        let preferences = preferences
        let title = documents?.recoverySessionTitle(for: controller, documentURL: documents?.currentDocumentURL) ?? controller.capture.sourceName
        let searchText = [title, searchableText, controller.capture.sourceName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let renderInput = ExportRenderInput(
            baseImage: controller.capture.image,
            snapshot: controller.snapshot,
            pinnedUIMapElements: controller.pinnedUIMapElements,
            uiMapOverlayOptions: controller.uiMapOverlayOptions
        )

        Task { @MainActor [weak self] in
            do {
                let pngData = try await ClipboardSnipRenderer.renderPNGData(from: renderInput)

                guard let self, self.preferences.isEnabled else {
                    return
                }

                self.historyStore.recordSnip(
                    pngData: pngData,
                    title: title,
                    searchableText: searchText,
                    sessionID: sessionID,
                    preferences: preferences
                )
            } catch {
                // Clipboard history is auxiliary; capture should remain successful.
            }
        }
    }

    private static func sendPasteKeystroke() {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

nonisolated private enum ClipboardSnipRenderer {
    static func renderPNGData(from input: ExportRenderInput) async throws -> Data {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()

            let image = PresentationPerformanceMetrics.measure(
                "clipboard.content",
                context: "base=\(input.baseImage.width)x\(input.baseImage.height) crop=\(PresentationPerformanceMetrics.size(input.snapshot.cropRect.size)) annotations=\(input.snapshot.annotations.count)",
                warnAfterMS: 80
            ) {
                EditorRenderer.render(
                    baseImage: input.baseImage,
                    snapshot: input.snapshot,
                    pinnedUIMapElements: input.pinnedUIMapElements,
                    uiMapOverlayOptions: input.uiMapOverlayOptions
                )
            }

            let presentedImage = image.flatMap { image in
                PresentationPerformanceMetrics.measure(
                    "clipboard.presentation",
                    context: "content=\(image.width)x\(image.height) \(PresentationPerformanceMetrics.presentationSummary(input.snapshot.presentation))",
                    warnAfterMS: 100
                ) {
                    ScreenshotPresentationRenderer.render(contentImage: image, presentation: input.snapshot.presentation)
                }
            }

            guard let presentedImage else {
                throw ImageExportError.encodingFailed
            }

            try Task.checkCancellation()
            return try PresentationPerformanceMetrics.measure(
                "clipboard.encode",
                context: "image=\(presentedImage.width)x\(presentedImage.height)",
                warnAfterMS: 80
            ) {
                try ImageExporter.pngData(for: presentedImage)
            }
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
