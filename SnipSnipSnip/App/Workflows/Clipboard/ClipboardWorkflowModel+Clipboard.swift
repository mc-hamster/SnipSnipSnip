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
        dependencies.managerPresenter.showClipboardManager(clipboard: self)
    }

    func updateClipboardHistoryEnabled(_ isEnabled: Bool) {
        if isEnabled {
            historyStore.activateStorage()
        }

        var preferences = preferences
        preferences.isEnabled = isEnabled
        self.preferences = preferences

        if !isEnabled {
            historyStore.deactivateStorage()
        }
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

    func updateClipboardRetentionDays(_ value: Int) {
        var preferences = preferences
        preferences.retentionDays = value
        self.preferences = preferences
    }

    func updateClipboardMaxItemSizeMB(_ value: Int) {
        var preferences = preferences
        preferences.maxItemSizeMB = value
        self.preferences = preferences
    }

    func updateRecordsUncopiedSnips(_ value: Bool) {
        var preferences = preferences
        preferences.recordsUncopiedSnips = value
        self.preferences = preferences
    }

    func pauseClipboardMonitoring(for interval: TimeInterval?) {
        let pauseDate = interval.map { Date().addingTimeInterval($0) } ?? .distantFuture
        monitoringPausedUntil = pauseDate
        monitor.pause(until: pauseDate)
    }

    func resumeClipboardMonitoring() {
        monitoringPausedUntil = nil
        monitor.pause(until: nil)
    }

    var isClipboardMonitoringPaused: Bool {
        guard let monitoringPausedUntil else { return false }
        return monitoringPausedUntil > Date()
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

    func toggleClipboardCollection(_ collectionName: String, for item: ClipboardItem) {
        historyStore.toggleCollection(collectionName, for: item)
    }

    func deleteClipboardItem(_ item: ClipboardItem) {
        historyStore.delete(item)
    }

    func openClipboardItem(_ item: ClipboardItem) {
        switch item.kind {
        case let .link(urlString):
            if let url = URL(string: urlString) {
                dependencies.systemServices.workspace.open(url)
            }
        case let .fileURLs(paths):
            paths.first.map(URL.init(fileURLWithPath:)).map(dependencies.systemServices.workspace.open)
        case .text, .image, .snip:
            break
        }
    }

    func revealClipboardFiles(_ item: ClipboardItem) {
        guard case let .fileURLs(paths) = item.kind else { return }
        dependencies.systemServices.workspace.activateFileViewerSelecting(paths.map(URL.init(fileURLWithPath:)))
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
              preferences.recordsUncopiedSnips,
              let image = try? controller.exportedImage(appearance: controller.automationOutputAppearance),
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
        sessionID: UUID? = nil,
        willBeCopied: Bool = false
    ) {
        guard preferences.isEnabled,
              preferences.recordsUncopiedSnips || willBeCopied else {
            return
        }

        let preferences = preferences
        let title = documents?.recoverySessionTitle(for: controller, documentURL: documents?.currentDocumentURL) ?? controller.capture.sourceName
        let searchText = [title, searchableText, controller.capture.sourceName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        Task { @MainActor [weak self] in
            do {
                let image = try await controller.renderedImageForExport(
                    appearance: controller.automationOutputAppearance
                )
                let pngData = try await Task.detached(
                    priority: .utility
                ) {
                    try ImageExporter.pngData(for: image)
                }.value
                // This result is needed before the clipboard-history record
                // is written. Match the capture task's QoS so Vision does not
                // introduce a priority inversion while recognizing text.
                let recognizedText = await Task.detached(priority: .userInitiated) {
                    ClipboardTextRecognition.recognizedText(in: pngData)
                }.value

                guard let self, self.preferences.isEnabled else {
                    return
                }

                self.historyStore.recordSnip(
                    pngData: pngData,
                    title: title,
                    searchableText: [searchText, recognizedText].filter { !$0.isEmpty }.joined(separator: " "),
                    sessionID: sessionID,
                    preferences: preferences
                )
            } catch {
                // Clipboard history is auxiliary; capture should remain successful.
            }
        }
    }

}
