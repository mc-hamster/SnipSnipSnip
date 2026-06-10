import AppKit
import Foundation
import UniformTypeIdentifiers

extension AppModel {
    var clipboardHistoryItems: [ClipboardItem] {
        clipboardHistoryStore.items
    }

    static func loadClipboardPreferences(from defaults: UserDefaults) -> ClipboardPreferences {
        guard let data = defaults.data(forKey: AppModelPreferenceKey.clipboardPreferences),
              let preferences = try? JSONDecoder().decode(ClipboardPreferences.self, from: data) else {
            return .default
        }

        var migratedPreferences = preferences
        let existingMatches = Set(migratedPreferences.ignoredApps.map { $0.id })
        let missingDefaultIgnores = ClipboardPreferences.defaultIgnoredApps.filter { !existingMatches.contains($0.id) }
        migratedPreferences.ignoredApps.append(contentsOf: missingDefaultIgnores)
        return migratedPreferences.sanitized()
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

        var preferences = clipboardPreferences
        let existingMatches = Set(preferences.ignoredApps.map { $0.match.localizedLowercase })
        guard !existingMatches.contains(normalizedMatch.localizedLowercase) else {
            return
        }

        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        preferences.ignoredApps.append(ClipboardIgnoredApp(
            name: normalizedName.isEmpty ? normalizedMatch : normalizedName,
            match: normalizedMatch
        ))
        clipboardPreferences = preferences
    }

    var clipboardRunningAppIgnoreCandidates: [ClipboardIgnoredApp] {
        let candidates = NSWorkspace.shared.runningApplications.compactMap { app -> ClipboardIgnoredApp? in
            guard app.activationPolicy == .regular,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else {
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
        let candidates = clipboardHistoryItems.compactMap { item -> ClipboardIgnoredApp? in
            guard let sourceApp = item.sourceApp,
                  sourceApp.bundleIdentifier != Bundle.main.bundleIdentifier else {
                return nil
            }

            let match = sourceApp.bundleIdentifier ?? sourceApp.displayName
            return ClipboardIgnoredApp(name: sourceApp.displayName, match: match)
        }

        return filteredClipboardIgnoreCandidates(candidates)
    }

    func chooseIgnoredClipboardApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose App to Ignore"
        panel.prompt = "Ignore"
        panel.message = "Choose an app. SnipSnipSnip will skip clipboard history entries copied from it."
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK,
              let appURL = panel.url else {
            return
        }

        let bundle = Bundle(url: appURL)
        let displayName = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? appURL.deletingPathExtension().lastPathComponent
        addIgnoredClipboardApp(
            name: displayName,
            match: bundle?.bundleIdentifier ?? displayName
        )
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

    private func filteredClipboardIgnoreCandidates(_ candidates: [ClipboardIgnoredApp]) -> [ClipboardIgnoredApp] {
        let ignoredMatches = Set(clipboardPreferences.ignoredApps.map(\.id))
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

    func copyClipboardItemAsPlainText(_ item: ClipboardItem) {
        guard item.supportsPlainTextSanitization else {
            return
        }

        writeClipboardItemToPasteboard(item, plainTextOnly: true)
    }

    func pasteClipboardItem(_ item: ClipboardItem) {
        writeClipboardItemToPasteboard(item, plainTextOnly: false)
        clipboardManagerWindowController?.activatePreviousApplicationForPaste()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            Self.sendPasteKeystroke()
        }
    }

    func pasteClipboardItemAsPlainText(_ item: ClipboardItem) {
        guard item.supportsPlainTextSanitization else {
            return
        }

        writeClipboardItemToPasteboard(item, plainTextOnly: true)
        clipboardManagerWindowController?.activatePreviousApplicationForPaste()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
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
        let renderInput = ExportRenderInput(
            baseImage: controller.capture.image,
            snapshot: controller.snapshot,
            pinnedUIMapElements: controller.pinnedUIMapElements,
            uiMapOverlayOptions: controller.uiMapOverlayOptions
        )

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
        if plainTextOnly, item.plainTextValue == nil {
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        if plainTextOnly, let text = item.plainTextValue {
            pasteboard.setString(text, forType: .string)
            clipboardMonitor.markCurrentPasteboardChangeAsHandled()
            return
        }

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

            guard let image = EditorRenderer.render(
                baseImage: input.baseImage,
                snapshot: input.snapshot,
                pinnedUIMapElements: input.pinnedUIMapElements,
                uiMapOverlayOptions: input.uiMapOverlayOptions
            ),
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
