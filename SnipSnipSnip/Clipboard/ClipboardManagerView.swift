import AppKit
import SwiftUI

struct ClipboardManagerView: View {
    @ObservedObject var clipboard: ClipboardWorkflowModel
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var showsPreview = false
    @FocusState private var isHistoryFocused: Bool
    @State private var selectedItemID: ClipboardItem.ID?
    @FocusState private var isSearchFocused: Bool
    @State private var timeFilter: ClipboardTimeFilter = .all
    @State private var sourceFilter: String?
    @State private var collectionFilter: String?
    @State private var showsFilters = false
    @State private var showsClearConfirmation = false
    @State private var drafts = ClipboardDraftStore()
    @State private var copyFeedback: CopyFeedback?
    @State private var lastSuccessfulCopyMessage: String?

    private struct CopyFeedback {
        let id = UUID()
        let itemID: UUID
    }

    private var query: ClipboardHistoryQuery {
        ClipboardHistoryQuery(text: clipboard.searchQuery, kind: clipboard.filter,
                              time: timeFilter, source: sourceFilter, collection: collectionFilter)
    }

    private var sourceOptions: [(label: String, value: String)] {
        var seen = Set<String>()
        return clipboard.clipboardHistoryItems.compactMap { item in
            guard let app = item.sourceApp else { return nil }
            let value = app.bundleIdentifier ?? app.displayName
            guard seen.insert(value).inserted else { return nil }
            return (app.displayName, value)
        }
        .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private var collectionOptions: [String] {
        Array(Set(clipboard.clipboardHistoryItems.flatMap(\.collectionNames)))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let snapshot = ClipboardHistorySnapshot(items: clipboard.clipboardHistoryItems, query: query, now: context.date)
            let selected = snapshot.items.first { $0.id == selectedItemID } ?? snapshot.items.first
            VStack(spacing: 0) {
                if showsPreview { previewHeader } else { header(count: snapshot.items.count) }
                if let problem = clipboard.storageProblem {
                    storageWarning(problem)
                }
                Divider()
                content(snapshot: snapshot, selected: selected, now: context.date)
                Divider()
                footer(snapshot: snapshot, selected: selected)
            }
            .background { ClipboardPaletteSurface() }
            .background(shortcutHandler(items: snapshot.items, selected: selected))
            .onAppear {
                selectedItemID = selected?.id
                isSearchFocused = true
            }
            .onChange(of: snapshot.items.map(\.id)) { _, ids in
                if let selectedItemID, ids.contains(selectedItemID) { return }
                selectedItemID = ids.first
            }
        }
        .frame(minWidth: 400, minHeight: 460)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: showsPreview)
        .onChange(of: clipboard.preferences.isEnabled) { _, enabled in
            if !enabled { drafts.removeAll(); copyFeedback = nil }
        }
        .onChange(of: clipboard.items.map(\.id) + clipboard.historyStore.pendingDeletions.map { $0.item.id }) { _, ids in
            drafts.retainItems(Set(ids))
        }
        .onReceive(NotificationCenter.default.publisher(for: ClipboardManagerWindowID.didShowNotification)) { _ in
            showsPreview = false
            isSearchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if ClipboardManagerWindowID.isClipboardManagerWindow(notification.object as? NSWindow) {
                drafts.removeAll()
                copyFeedback = nil
            }
        }
        .task(id: copyFeedback?.id) {
            guard copyFeedback != nil else { return }
            do {
                try await Task.sleep(for: .seconds(1.8))
                copyFeedback = nil
            } catch { /* A later copy or window closure superseded this confirmation. */ }
        }
        .confirmationDialog(
            "Permanently delete unpinned Clipboard History items?",
            isPresented: $showsClearConfirmation, titleVisibility: .visible
        ) {
            Button("Permanently Delete Unpinned Items", role: .destructive) {
                clipboard.clearUnpinnedClipboardItems()
            }
        } message: {
            Text("Pinned items will be kept. This action cannot be undone.")
        }
    }

    private func header(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "clipboard")
                    .font(.system(size: 22, weight: .medium))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clipboard History").font(.system(size: 16, weight: .semibold))
                    Text("\(count) items").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                monitoringMenu
                windowActions
            }
            .padding(.horizontal, 20)

            HStack(spacing: 10) {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search clipboard history", text: $clipboard.searchQuery)
                        .font(.system(size: 14))
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)
                        .accessibilityLabel("Search Clipboard History")
                        .accessibilityIdentifier("clipboard.search")
                    if !clipboard.searchQuery.isEmpty {
                        Button {
                            clipboard.searchQuery = ""
                            isSearchFocused = true
                        } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Clear Search")
                        .accessibilityLabel("Clear Search")
                    }
                }
                .padding(.horizontal, 13)
                .frame(height: 40)
                .background(Color(nsColor: .textBackgroundColor).opacity(reduceTransparency ? 1 : 0.8), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(contrast == .increased ? Color.primary : Color(nsColor: .separatorColor).opacity(0.4)))
                Button { showsFilters.toggle() } label: {
                    Image(systemName: query.secondaryFilterCount == 0 ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                        .font(.system(size: 16))
                        .frame(width: 34, height: 34)
                        .background(Color(nsColor: .textBackgroundColor), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Filters")
                .accessibilityLabel("Filters")
                .accessibilityValue(String(localized: "\(query.secondaryFilterCount) active filters"))
                .popover(isPresented: $showsFilters) {
                    ClipboardFilterPopover(time: $timeFilter, source: $sourceFilter, collection: $collectionFilter,
                        sources: sourceOptions, collections: collectionOptions, dismiss: { showsFilters = false })
                }
                .accessibilityIdentifier("clipboard.filters")
            }
            .padding(.horizontal, 20)

            ClipboardScopePicker(selection: $clipboard.filter)

            if query.secondaryFilterCount > 0 {
                HStack(spacing: 6) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            if timeFilter != .all {
                                ClipboardActiveFilter(title: timeFilter.label, symbol: "calendar") { timeFilter = .all }
                            }
                            if let sourceFilter {
                                ClipboardActiveFilter(title: sourceOptions.first { $0.value == sourceFilter }?.label ?? sourceFilter,
                                                      symbol: "app") { self.sourceFilter = nil }
                            }
                            if let collectionFilter {
                                ClipboardActiveFilter(title: collectionFilter, symbol: "folder") { self.collectionFilter = nil }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    Button("Clear Filters", action: clearFilters).buttonStyle(.borderless).fixedSize()
                }
                .padding(.horizontal, 20)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    private var windowActions: some View {
        Menu {
            Button("Search Clipboard History", action: focusSearch)
                .keyboardShortcut("f", modifiers: .command)
            Divider()
            Button("Permanently Delete Unpinned Items…", role: .destructive) {
                showsClearConfirmation = true
            }
            .disabled(clipboard.clipboardHistoryItems.allSatisfy(\.isPinned)
                      && clipboard.historyStore.pendingDeletions.allSatisfy { $0.item.isPinned })
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 30, height: 30)
                .background(Color(nsColor: .textBackgroundColor), in: Circle())
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Clipboard Actions")
        .accessibilityLabel("Clipboard Actions")
        .accessibilityIdentifier("clipboard.actions")
    }

    private var previewHeader: some View {
        HStack {
            Button(action: closePreview) { Label("Back", systemImage: "chevron.left") }
                .buttonStyle(.plain)
                .accessibilityIdentifier("clipboard.back")
            Spacer()
            Text("Preview").font(.subheadline.weight(.semibold))
            Spacer()
            windowActions
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var monitoringMenu: some View {
        Menu {
            if clipboard.isClipboardMonitoringPaused {
                Button("Resume Monitoring", action: clipboard.resumeClipboardMonitoring)
            } else {
                Button("Pause Monitoring for 5 Minutes") { clipboard.pauseClipboardMonitoring(for: 5 * 60) }
                Button("Pause Monitoring for 1 Hour") { clipboard.pauseClipboardMonitoring(for: 60 * 60) }
                Button("Pause Monitoring Until Restart") { clipboard.pauseClipboardMonitoring(for: nil) }
            }
        } label: {
            Label(clipboard.monitoringStatus,
                  systemImage: clipboard.isClipboardMonitoringPaused ? "pause.circle" : "dot.radiowaves.left.and.right")
                .labelStyle(.iconOnly)
                .frame(width: 30, height: 30)
                .background(Color(nsColor: .textBackgroundColor), in: Circle())
        }
        .menuIndicator(.hidden)
        .help(clipboard.monitoringStatus)
        .accessibilityLabel(clipboard.monitoringStatus)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!clipboard.preferences.isEnabled || !clipboard.historyStore.isStorageAvailable)
        .accessibilityIdentifier("clipboard.monitoring")
    }

    private func storageWarning(_ problem: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(problem).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            Button("Try Again", action: clipboard.retryClipboardStorage)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private func content(snapshot: ClipboardHistorySnapshot, selected: ClipboardItem?, now: Date) -> some View {
        if !clipboard.preferences.isEnabled {
            ContentUnavailableView("Clipboard History Disabled", systemImage: "clipboard",
                description: Text("Enable clipboard history in Settings > Snip Library > Clipboard."))
        } else if !clipboard.historyStore.isStorageAvailable {
            ContentUnavailableView("Clipboard History Unavailable", systemImage: "exclamationmark.triangle",
                description: Text("Stored history could not be opened. Use Try Again above after resolving the storage or Keychain problem."))
        } else if snapshot.items.isEmpty, query.isFiltering {
            ContentUnavailableView {
                Label("No Matching Clipboard Items", systemImage: "magnifyingglass")
            } description: {
                Text("No items match the current search and filters. Your history has not been deleted.")
            } actions: { Button("Clear Filters", action: clearFilters) }
        } else if snapshot.items.isEmpty, clipboard.isClipboardMonitoringPaused {
            ContentUnavailableView {
                Label("Monitoring Paused", systemImage: "pause.circle")
            } description: {
                Text("No clipboard items have been saved yet. Resume monitoring to save new copies.")
            } actions: { Button("Resume Monitoring", action: clipboard.resumeClipboardMonitoring) }
        } else if snapshot.items.isEmpty {
            ContentUnavailableView("No Clipboard Items Yet", systemImage: "clipboard",
                description: Text("Copy text, a link, an image, or a file to start your history."))
        } else {
            ZStack {
                historyList(snapshot: snapshot, now: now)
                    .opacity(showsPreview ? 0 : 1)
                    .disabled(showsPreview)
                    .allowsHitTesting(!showsPreview)
                    .accessibilityHidden(showsPreview)
                if showsPreview, let selected {
                    inspector(for: selected)
                        .transition(.opacity)
                }
            }
        }
    }

    private func historyList(snapshot: ClipboardHistorySnapshot, now: Date) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(snapshot.sections) { section in
                        HStack(spacing: 8) {
                            Text(section.title(now: now)).textCase(.uppercase)
                            Text("\(section.entries.count)").monospacedDigit().foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                        ForEach(section.entries) { entry in
                            ClipboardItemRow(entry: entry, image: clipboard.clipboardPreviewImage(for: entry.item),
                                isSelected: selectedItemID == entry.id, isEdited: drafts.isEdited(entry.item),
                                justCopied: copyFeedback?.itemID == entry.id, now: now, commands: commands(for: entry.item),
                                activate: {
                                    selectedItemID = entry.id
                                    isSearchFocused = false
                                    isHistoryFocused = true
                                    copy(entry.item)
                                }, preview: { showPreview(entry.item) })
                                .id(entry.id)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 18)
            }
            .focusable(!showsPreview)
            .focusEffectDisabled()
            .focused($isHistoryFocused)
            .accessibilityLabel("Clipboard Items")
            .accessibilityIdentifier("clipboard.list")
            .onChange(of: selectedItemID) { _, id in
                if let id {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { proxy.scrollTo(id) }
                }
            }
        }
    }

    private func inspector(for item: ClipboardItem) -> some View {
        ClipboardItemInspector(item: item, image: clipboard.clipboardPreviewImage(for: item),
            text: Binding(get: { drafts.text(for: item) }, set: { drafts.setText($0, for: item) }),
            isEdited: drafts.isEdited(item), collections: collectionOptions, commands: commands(for: item),
            reset: { drafts.reset(item) }, prettyPrintJSON: { prettyPrintJSON(item) },
            addCollection: { clipboard.addClipboardCollection($0, for: item) },
            removeCollection: { clipboard.toggleClipboardCollection($0, for: item) })
    }

    private func footer(snapshot: ClipboardHistorySnapshot, selected: ClipboardItem?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = clipboard.actionMessage, message != lastSuccessfulCopyMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("clipboard.status")
            }
            HStack(spacing: 10) {
                if clipboard.historyStore.canUndoDeletion {
                    Button("Undo Delete", action: undoDeletion)
                        .help("Restore the last deleted item within 30 seconds. Command-Z while browsing.")
                }
                if !showsPreview, !clipboard.historyStore.canUndoDeletion {
                    Text("Click to copy · ↑↓ to browse")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if !showsPreview, let selected {
                    Button("Preview", systemImage: "eye") { showPreview(selected) }
                        .buttonStyle(.borderless)
                        .help("Preview the selected item. Space while browsing.")
                        .accessibilityIdentifier("clipboard.preview")
                }
                if showsPreview, let selected, selected.supportsPlainTextSanitization {
                    Menu {
                        Button("Copy Original") { copy(selected, original: true) }
                        Button("Copy Plain Text") { copy(selected, plainText: true) }
                    } label: { Text("Copy Options") }
                    .fixedSize()
                    .help("Copy the stored original with its formatting, or just its original plain text.")
                }
                Button {
                    if let selected { copy(selected) }
                } label: {
                    HStack(spacing: 12) {
                        Text(selected.map { drafts.isEdited($0) } == true ? "Copy Edited" : "Copy")
                        Text("⌘↩").font(.caption).accessibilityHidden(true)
                    }
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .padding(.horizontal, 13)
                    .frame(height: 32)
                    .background(Color.primary, in: RoundedRectangle(cornerRadius: 9))
                    .opacity(selected == nil ? 0.4 : 1)
                }
                .buttonStyle(.plain)
                .disabled(selected == nil)
                .help("Return while browsing or Command-Return while editing.")
                .accessibilityIdentifier("clipboard.copy")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func commands(for item: ClipboardItem) -> ClipboardItemCommands {
        ClipboardItemCommands(copyTitle: drafts.isEdited(item) ? String(localized: "Copy Edited") : String(localized: "Copy"),
            copy: { copy(item) }, copyOriginal: { copy(item, original: true) },
            copyPlainText: { copy(item, plainText: true) },
            togglePinned: { clipboard.togglePinnedClipboardItem(item) },
            delete: { clipboard.deleteClipboardItem(item) },
            open: {
                if case .snip = item.kind { clipboard.openClipboardSnip(item) }
                else { clipboard.openClipboardItem(item) }
            }, reveal: { clipboard.revealClipboardFiles(item) })
    }

    private func copy(_ item: ClipboardItem, original: Bool = false, plainText: Bool = false) {
        let succeeded: Bool
        if !original, !plainText, drafts.isEdited(item) {
            succeeded = clipboard.copyEditedText(drafts.text(for: item))
        } else {
            succeeded = clipboard.copyItem(item, plainTextOnly: plainText)
        }
        copyFeedback = succeeded ? CopyFeedback(itemID: item.id) : nil
        lastSuccessfulCopyMessage = succeeded ? clipboard.actionMessage : nil
        if let message = clipboard.actionMessage { AppAccessibility.announce(message) }
    }

    private func showPreview(_ item: ClipboardItem) {
        selectedItemID = item.id
        isSearchFocused = false
        isHistoryFocused = false
        showsPreview = true
    }

    private func closePreview() {
        showsPreview = false
        isHistoryFocused = true
    }

    private func focusSearch() {
        showsPreview = false
        isHistoryFocused = false
        isSearchFocused = true
    }

    private func clearFilters() {
        clipboard.searchQuery = ""
        clipboard.filter = .all
        timeFilter = .all
        sourceFilter = nil
        collectionFilter = nil
    }

    private func undoDeletion() {
        if let id = clipboard.undoClipboardDeletion() {
            clearFilters()
            selectedItemID = id
        }
    }

    private func prettyPrintJSON(_ item: ClipboardItem) {
        guard let data = drafts.text(for: item).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let formatted = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: formatted, encoding: .utf8) else {
            clipboard.actionMessage = "The edited text is not valid JSON."
            return
        }
        drafts.setText(text, for: item)
    }

    private func shortcutHandler(items: [ClipboardItem], selected: ClipboardItem?) -> some View {
        ClipboardShortcutHandler(
            onNumberShortcut: { number in
                guard number > 0, number <= items.count else { return }
                copy(items[number - 1])
            },
            onMove: { direction in
                guard !items.isEmpty else { selectedItemID = nil; return }
                let index = items.firstIndex { $0.id == selectedItemID } ?? 0
                if direction == .up { selectedItemID = items[max(index - 1, 0)].id }
                if direction == .down { selectedItemID = items[min(index + 1, items.count - 1)].id }
            },
            onReturn: { _ in if let selected { copy(selected) } },
            onPreview: { if let selected { showPreview(selected) } },
            onUndoDeletion: undoDeletion, hasDeletionUndo: clipboard.historyStore.canUndoDeletion,
            onFocusSearch: focusSearch, isSearchFocused: isSearchFocused,
            onEscape: {
                if showsPreview { closePreview() }
                else if !clipboard.searchQuery.isEmpty { clipboard.searchQuery = "" }
                else { NSApp.keyWindow?.performClose(nil) }
            }
        )
        .frame(width: 0, height: 0)
    }
}
