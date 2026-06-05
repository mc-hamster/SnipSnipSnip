import AppKit
import Foundation

extension AppModel {
    var clipboardHistoryItems: [ClipboardItem] {
        clipboardHistoryStore.items
    }

    static func loadClipboardPreferences(from defaults: UserDefaults) -> ClipboardPreferences {
        guard let data = defaults.data(forKey: AppModelPreferenceKey.clipboardPreferences),
              let preferences = try? JSONDecoder().decode(ClipboardPreferences.self, from: data) else {
            return .default
        }

        return preferences.sanitized()
    }

    func persistClipboardPreferences() {
        guard let data = try? JSONEncoder().encode(clipboardPreferences.sanitized()) else {
            return
        }

        defaults.set(data, forKey: AppModelPreferenceKey.clipboardPreferences)
    }

    func showClipboardManager() {
        if clipboardManagerWindowController == nil {
            clipboardManagerWindowController = ClipboardManagerWindowController(model: self)
        }

        clipboardManagerWindowController?.show()
    }

    func updateClipboardHistoryEnabled(_ isEnabled: Bool) {
        var preferences = clipboardPreferences
        preferences.isEnabled = isEnabled
        clipboardPreferences = preferences
    }

    func updateClipboardMaxItemCount(_ value: Int) {
        var preferences = clipboardPreferences
        preferences.maxItemCount = value
        clipboardPreferences = preferences
    }

    func updateClipboardMaxStorageMB(_ value: Int) {
        var preferences = clipboardPreferences
        preferences.maxStorageMB = value
        clipboardPreferences = preferences
    }

    func addIgnoredClipboardApp(match: String) {
        let normalizedMatch = match.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMatch.isEmpty else {
            return
        }

        var preferences = clipboardPreferences
        let existingMatches = Set(preferences.ignoredApps.map { $0.match.localizedLowercase })
        guard !existingMatches.contains(normalizedMatch.localizedLowercase) else {
            return
        }

        preferences.ignoredApps.append(ClipboardIgnoredApp(name: normalizedMatch, match: normalizedMatch))
        clipboardPreferences = preferences
    }

    func removeIgnoredClipboardApp(_ app: ClipboardIgnoredApp) {
        var preferences = clipboardPreferences
        preferences.ignoredApps.removeAll { $0.id == app.id }
        clipboardPreferences = preferences
    }

    func resetIgnoredClipboardApps() {
        var preferences = clipboardPreferences
        preferences.ignoredApps = ClipboardPreferences.defaultIgnoredApps
        clipboardPreferences = preferences
    }

    func clearUnpinnedClipboardItems() {
        clipboardHistoryStore.clearUnpinned()
    }

    func clearClipboardHistory() {
        clipboardHistoryStore.clearAll()
    }

    func togglePinnedClipboardItem(_ item: ClipboardItem) {
        clipboardHistoryStore.togglePinned(item)
    }

    func deleteClipboardItem(_ item: ClipboardItem) {
        clipboardHistoryStore.delete(item)
    }

    func clipboardPreviewImage(for item: ClipboardItem) -> NSImage? {
        clipboardHistoryStore.image(for: item)
    }

    func copyClipboardItem(_ item: ClipboardItem, plainTextOnly: Bool = false) {
        writeClipboardItemToPasteboard(item, plainTextOnly: plainTextOnly)
    }

    func pasteClipboardItem(_ item: ClipboardItem) {
        writeClipboardItemToPasteboard(item, plainTextOnly: false)
        clipboardManagerWindowController?.window?.orderOut(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            Self.sendPasteKeystroke()
        }
    }

    func openClipboardSnip(_ item: ClipboardItem) {
        guard case let .snip(_, sessionID, _) = item.kind,
              let sessionID else {
            return
        }

        refreshRecoveryPresentationState()
        let candidates = allCaptureHistoryEntries + recentSnipEntries + historyEntries
        guard let entry = candidates
            .filter({ $0.sessionID == sessionID })
            .sorted(by: { $0.savedAt > $1.savedAt })
            .first else {
            return
        }

        restoreHistoryEntry(entry)
    }

    func recordClipboardSnip(
        from controller: EditorController,
        searchableText: String = "",
        sessionID: UUID? = nil
    ) {
        guard clipboardPreferences.isEnabled,
              let image = controller.exportedImage(),
              let pngData = try? ImageExporter.pngData(for: image) else {
            return
        }

        let title = recoverySessionTitle(for: controller, documentURL: currentDocumentURL)
        let searchText = [title, searchableText, controller.capture.sourceName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        clipboardHistoryStore.recordSnip(
            pngData: pngData,
            title: title,
            searchableText: searchText,
            sessionID: sessionID,
            preferences: clipboardPreferences
        )
    }

    func scheduleClipboardSnipRecording(
        from controller: EditorController,
        searchableText: String = "",
        sessionID: UUID? = nil
    ) {
        guard clipboardPreferences.isEnabled else {
            return
        }

        let preferences = clipboardPreferences
        let title = recoverySessionTitle(for: controller, documentURL: currentDocumentURL)
        let searchText = [title, searchableText, controller.capture.sourceName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let renderInput = ExportRenderInput(baseImage: controller.capture.image, snapshot: controller.snapshot)

        Task { @MainActor [weak self] in
            do {
                let pngData = try await ClipboardSnipRenderer.renderPNGData(from: renderInput)

                guard let self, self.clipboardPreferences.isEnabled else {
                    return
                }

                self.clipboardHistoryStore.recordSnip(
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

    private func writeClipboardItemToPasteboard(_ item: ClipboardItem, plainTextOnly: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.kind {
        case let .text(text), let .link(text):
            pasteboard.setString(text, forType: .string)
        case let .fileURLs(paths):
            let urls = paths.map { URL(fileURLWithPath: $0) }
            pasteboard.writeObjects(urls as [NSURL])
        case .image, .snip:
            if let data = clipboardHistoryStore.dataForPasteboard(for: item) {
                pasteboard.setData(data, forType: .png)
            }
        }

        clipboardMonitor.markCurrentPasteboardChangeAsHandled()
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

            guard let image = EditorRenderer.render(baseImage: input.baseImage, snapshot: input.snapshot),
                  let presentedImage = ScreenshotPresentationRenderer.render(contentImage: image, presentation: input.snapshot.presentation) else {
                throw ImageExportError.encodingFailed
            }

            try Task.checkCancellation()
            return try ImageExporter.pngData(for: presentedImage)
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
