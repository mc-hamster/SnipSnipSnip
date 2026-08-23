import AppKit
import Combine
import SwiftUI

enum SnipLibraryScope: String, CaseIterable, Identifiable {
    case recent
    case history
    case recycleBin

    var id: Self { self }

    var title: String {
        switch self {
        case .recent:
            WorkflowVocabulary.Library.recentSnips
        case .history:
            WorkflowVocabulary.Library.snipHistory
        case .recycleBin:
            WorkflowVocabulary.Library.recycleBin
        }
    }

    var systemImage: String {
        switch self {
        case .recent: "clock"
        case .history: "clock.arrow.circlepath"
        case .recycleBin: "trash"
        }
    }
}

@MainActor
struct SnipLibraryRequest {
    let outOfCapturePatternSettings: EditorOutOfCapturePatternSettings
    let loadPage: (
        SnipLibraryScope,
        String,
        Int,
        Int
    ) async -> DocumentHistoryPage
    let onOpenRecent: (DocumentHistoryEntry) -> Void
    let onOpenHistory: (DocumentHistoryEntry) -> Void
    let onRestoreRecycled: (DocumentHistoryEntry) -> Void
    let onFloat: (DocumentHistoryEntry) -> Void
    let onDelete: (DocumentHistoryEntry) -> Void
    let onPermanentlyDelete: (DocumentHistoryEntry) -> Void
    let onEmptyRecycleBin: () -> Void
}

@MainActor
final class SnipLibraryWindowModel: ObservableObject {
    @Published var scope: SnipLibraryScope
    @Published var searchQuery: String
    @Published var selectedEntryID: UUID?
    @Published private(set) var entries: [DocumentHistoryEntry] = []
    @Published private(set) var totalCount = 0
    @Published private(set) var isLoadingEntries = false
    @Published private(set) var entryLoadErrorMessage: String?
    @Published private(set) var imageModel: FloatingReferenceWindowModel?
    @Published private(set) var displayedEntryID: UUID?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private(set) var request: SnipLibraryRequest

    init(
        request: SnipLibraryRequest,
        initialScope: SnipLibraryScope,
        searchQuery: String = "",
        selectedEntryID: UUID? = nil
    ) {
        self.request = request
        scope = initialScope
        self.searchQuery = searchQuery
        self.selectedEntryID = selectedEntryID
    }

    var visibleEntries: [DocumentHistoryEntry] {
        entries
    }

    var selectedEntry: DocumentHistoryEntry? {
        guard let selectedEntryID else {
            return nil
        }
        return visibleEntries.first { $0.id == selectedEntryID }
    }

    var primaryActionTitle: String {
        scope == .recycleBin ? "Restore" : "Open"
    }

    var hasMoreEntries: Bool {
        entries.count < totalCount
    }

    var resultsLabel: String {
        guard !isLoadingEntries || !entries.isEmpty else {
            return "Loading…"
        }
        if totalCount == 1 {
            return "1 Screenshot"
        }
        return "\(totalCount) Screenshots"
    }

    var emptyTitle: String {
        switch scope {
        case .recent: "No Recent Snips"
        case .history: "No Snip History"
        case .recycleBin: "Recycle Bin is Empty"
        }
    }

    var emptyDescription: String {
        let hasQuery = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasQuery {
            return "No screenshots matched your search."
        }
        switch scope {
        case .recent:
            return "Screenshots you move away from appear here for easy return."
        case .history:
            return "Saved checkpoints and autosaves appear here."
        case .recycleBin:
            return "Deleted screenshots remain recoverable here until retention expires."
        }
    }

    func update(request: SnipLibraryRequest) {
        self.request = request
    }

    func changeScope(_ newScope: SnipLibraryScope) {
        scope = newScope
        prepareForEntryReload(preferredSelection: nil)
    }

    func searchDidChange() {
        prepareForEntryReload(preferredSelection: selectedEntryID)
    }

    func select(_ entryID: UUID?) {
        selectedEntryID = entryID
        errorMessage = nil
    }

    func beginLoading() {
        isLoading = true
        errorMessage = nil
    }

    func display(image: CGImage, for entry: DocumentHistoryEntry) {
        let subtitle = entry.savedAt.formatted(date: .abbreviated, time: .shortened)
        if let imageModel {
            imageModel.updateContent(
                title: entry.libraryDisplayTitle,
                subtitle: subtitle,
                image: image,
                outOfCapturePatternSettings: request.outOfCapturePatternSettings
            )
        } else {
            imageModel = FloatingReferenceWindowModel(
                title: entry.libraryDisplayTitle,
                subtitle: subtitle,
                image: image,
                outOfCapturePatternSettings: request.outOfCapturePatternSettings,
                preservesZoomAcrossImageChanges: true,
                togglesFitOnDoubleClick: true
            )
        }
        displayedEntryID = entry.id
        isLoading = false
        errorMessage = nil
    }

    func failLoading(_ message: String) {
        isLoading = false
        errorMessage = message
    }

    func clearPreview() {
        imageModel = nil
        displayedEntryID = nil
        isLoading = false
        errorMessage = nil
    }

    func prepareForEntryReload(preferredSelection: UUID?) {
        entries = []
        totalCount = 0
        selectedEntryID = preferredSelection
        isLoadingEntries = true
        entryLoadErrorMessage = nil
        clearPreview()
    }

    func beginLoadingMoreEntries() {
        isLoadingEntries = true
        entryLoadErrorMessage = nil
    }

    func install(
        page: DocumentHistoryPage,
        appending: Bool,
        preferredSelection: UUID?
    ) {
        if appending {
            let existingIDs = Set(entries.map(\.id))
            entries.append(contentsOf: page.entries.filter { !existingIDs.contains($0.id) })
        } else {
            entries = page.entries
        }
        totalCount = page.totalCount
        isLoadingEntries = false
        entryLoadErrorMessage = nil

        let selectionToKeep = preferredSelection ?? selectedEntryID
        if let selectionToKeep,
           entries.contains(where: { $0.id == selectionToKeep }) {
            selectedEntryID = selectionToKeep
        } else {
            selectedEntryID = entries.first?.id
        }
        if selectedEntryID == nil {
            clearPreview()
        }
    }

    func failEntryLoading(_ message: String) {
        isLoadingEntries = false
        entryLoadErrorMessage = message
        if entries.isEmpty {
            selectedEntryID = nil
            clearPreview()
        }
    }
}

@MainActor
final class SnipLibraryCoordinator {
    private static let pageSize = 50
    private static let frameAutosaveName = "SnipLibraryWindow"

    private let files: any FileSystemServicing
    private var windowController: NSWindowController?
    private var model: SnipLibraryWindowModel?
    private var previewLoadTask: Task<Void, Never>?
    private var entryLoadTask: Task<Void, Never>?
    private var searchDebounceTask: Task<Void, Never>?
    private var imageCache: [URL: CGImage] = [:]
    private var cacheOrder: [URL] = []
    private let maximumCachedImages = 8
    private var rememberedScope: SnipLibraryScope = .recent
    private var rememberedSearchQuery = ""
    private var rememberedSelectionByScope: [SnipLibraryScope: UUID] = [:]

    init(files: any FileSystemServicing) {
        self.files = files
    }

    var isPresented: Bool { windowController?.window?.isVisible == true }

    func present(
        _ request: SnipLibraryRequest,
        initialScope: SnipLibraryScope? = nil,
        searchQuery: String? = nil,
        selectedEntryID: UUID? = nil,
        parentWindow: NSWindow? = nil
    ) {
        let resolvedScope = initialScope ?? rememberedScope
        let resolvedSearchQuery = searchQuery ?? rememberedSearchQuery
        let resolvedSelection = selectedEntryID
            ?? rememberedSelectionByScope[resolvedScope]
        let resolvedModel: SnipLibraryWindowModel
        if let model, let windowController {
            resolvedModel = model
            model.update(request: request)
            model.scope = resolvedScope
            model.searchQuery = resolvedSearchQuery
            model.prepareForEntryReload(preferredSelection: resolvedSelection)
            windowController.showWindow(nil)
            windowController.window?.makeKeyAndOrderFront(nil)
        } else {
            let model = SnipLibraryWindowModel(
                request: request,
                initialScope: resolvedScope,
                searchQuery: resolvedSearchQuery,
                selectedEntryID: resolvedSelection
            )
            model.prepareForEntryReload(preferredSelection: resolvedSelection)
            let rootView = SnipLibraryWindowView(
                model: model,
                onSelect: { [weak self] id in self?.select(id) },
                onChangeScope: { [weak self] scope in self?.changeScope(scope) },
                onSearchChanged: { [weak self] in self?.searchChanged() },
                onRetryPreview: { [weak self] in self?.loadSelectedEntry() },
                onRetryEntries: { [weak self] in self?.reloadEntries() },
                onLoadMore: { [weak self] in self?.loadNextPage() },
                onPrimaryAction: { [weak self] in self?.performPrimaryAction() },
                onFloat: { [weak self] in self?.floatSelectedEntry() },
                onDelete: { [weak self] in self?.deleteSelectedEntry() },
                onEmptyRecycleBin: { [weak self] in self?.emptyRecycleBin() }
            )
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 980, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = WorkflowVocabulary.Library.snipLibrary
            window.minSize = CGSize(width: 760, height: 500)
            window.contentView = NSHostingView(rootView: rootView)
            let restoredFrame = window.setFrameUsingName(Self.frameAutosaveName)
            window.setFrameAutosaveName(Self.frameAutosaveName)
            if !restoredFrame {
                window.setFrame(
                    initialFrame(parentWindow: parentWindow),
                    display: true
                )
            }
            let controller = SnipLibraryWindowController(window: window) { [weak self] in
                self?.windowDidClose()
            }
            self.model = model
            windowController = controller
            resolvedModel = model
            controller.showWindow(nil)
            window.makeKeyAndOrderFront(nil)
        }
        rememberedScope = resolvedScope
        rememberedSearchQuery = resolvedSearchQuery
        reloadEntries(preferredSelection: resolvedModel.selectedEntryID)
    }

    func update(_ request: SnipLibraryRequest) {
        guard let model else { return }
        model.update(request: request)
        reloadEntries(preferredSelection: model.selectedEntryID)
    }

    func close() {
        rememberCurrentPresentationState()
        cancelTasks()
        let controller = windowController
        windowController = nil
        model = nil
        controller?.close()
    }

    private func select(_ entryID: UUID?) {
        model?.select(entryID)
        if let model, let entryID {
            rememberedSelectionByScope[model.scope] = entryID
        }
        loadSelectedEntry()
    }

    private func changeScope(_ scope: SnipLibraryScope) {
        searchDebounceTask?.cancel()
        model?.changeScope(scope)
        rememberedScope = scope
        reloadEntries(
            preferredSelection: rememberedSelectionByScope[scope]
        )
    }

    private func searchChanged() {
        guard let model else { return }
        let preferredSelection = model.selectedEntryID
        model.searchDidChange()
        rememberedSearchQuery = model.searchQuery
        searchDebounceTask?.cancel()
        searchDebounceTask = Task { @MainActor [weak self, weak model] in
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, model === self?.model else { return }
            self?.reloadEntries(preferredSelection: preferredSelection)
        }
    }

    private func reloadEntries(preferredSelection: UUID? = nil) {
        guard let model else { return }
        entryLoadTask?.cancel()
        model.prepareForEntryReload(preferredSelection: preferredSelection)
        loadPage(offset: 0, preferredSelection: preferredSelection)
    }

    private func loadNextPage() {
        guard let model,
              model.hasMoreEntries,
              !model.isLoadingEntries else {
            return
        }
        model.beginLoadingMoreEntries()
        loadPage(offset: model.entries.count, preferredSelection: model.selectedEntryID)
    }

    private func loadPage(offset: Int, preferredSelection: UUID?) {
        guard let model else { return }
        let scope = model.scope
        let query = model.searchQuery
        let request = model.request
        entryLoadTask?.cancel()
        entryLoadTask = Task { @MainActor [weak self, weak model] in
            let page = await request.loadPage(
                scope,
                query,
                offset,
                Self.pageSize
            )
            guard !Task.isCancelled,
                  let self,
                  let model,
                  model === self.model,
                  model.scope == scope,
                  model.searchQuery == query else {
                return
            }
            model.install(
                page: page,
                appending: offset > 0,
                preferredSelection: preferredSelection
            )
            if offset == 0 {
                select(model.selectedEntryID)
            }
        }
    }

    private func loadSelectedEntry() {
        guard let model, let entry = model.selectedEntry else {
            model?.clearPreview()
            return
        }
        previewLoadTask?.cancel()
        model.beginLoading()
        if let image = imageCache[entry.packageURL] {
            model.display(image: image, for: entry)
            return
        }

        let entryID = entry.id
        let packageURL = entry.packageURL
        let files = self.files
        previewLoadTask = Task { @MainActor [weak self, weak model] in
            do {
                guard let image = try await HistoryPreviewImageLoader.loadImage(
                    from: packageURL,
                    files: files
                ) else {
                    guard model?.selectedEntry?.id == entryID else { return }
                    model?.failLoading("This screenshot preview is unavailable.")
                    return
                }
                guard !Task.isCancelled,
                      let self,
                      model?.selectedEntry?.id == entryID else { return }
                cache(image, for: packageURL)
                model?.display(image: image, for: entry)
            } catch is CancellationError {
                return
            } catch {
                guard model?.selectedEntry?.id == entryID else { return }
                model?.failLoading("This screenshot preview could not be loaded. Try again.")
            }
        }
    }

    private func cache(_ image: CGImage, for url: URL) {
        imageCache[url] = image
        cacheOrder.removeAll { $0 == url }
        cacheOrder.append(url)
        while cacheOrder.count > maximumCachedImages {
            imageCache[cacheOrder.removeFirst()] = nil
        }
    }

    private func performPrimaryAction() {
        guard let model, let entry = model.selectedEntry else { return }
        switch model.scope {
        case .recent:
            model.request.onOpenRecent(entry)
        case .history:
            model.request.onOpenHistory(entry)
        case .recycleBin:
            model.request.onRestoreRecycled(entry)
        }
    }

    private func floatSelectedEntry() {
        guard let model, let entry = model.selectedEntry else { return }
        model.request.onFloat(entry)
    }

    private func deleteSelectedEntry() {
        guard let model, let entry = model.selectedEntry else { return }
        if model.scope == .recycleBin {
            model.request.onPermanentlyDelete(entry)
        } else {
            model.request.onDelete(entry)
        }
    }

    private func emptyRecycleBin() {
        model?.request.onEmptyRecycleBin()
    }

    private func windowDidClose() {
        rememberCurrentPresentationState()
        cancelTasks()
        windowController = nil
        model = nil
    }

    private func rememberCurrentPresentationState() {
        guard let model else { return }
        rememberedScope = model.scope
        rememberedSearchQuery = model.searchQuery
        if let selectedEntryID = model.selectedEntryID {
            rememberedSelectionByScope[model.scope] = selectedEntryID
        }
    }

    private func cancelTasks() {
        previewLoadTask?.cancel()
        entryLoadTask?.cancel()
        searchDebounceTask?.cancel()
        previewLoadTask = nil
        entryLoadTask = nil
        searchDebounceTask = nil
    }

    private func initialFrame(parentWindow: NSWindow?) -> CGRect {
        let fallbackVisibleFrame = NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visibleFrame = parentWindow?.screen?.visibleFrame
            ?? fallbackVisibleFrame
        let size = CGSize(
            width: min(980, visibleFrame.width),
            height: min(640, visibleFrame.height)
        )
        let parentFrame = parentWindow?.frame
            ?? CGRect(origin: visibleFrame.origin, size: visibleFrame.size)
        let origin = CGPoint(
            x: parentFrame.midX - size.width / 2,
            y: parentFrame.midY - size.height / 2
        )
        let maximumX = max(visibleFrame.minX, visibleFrame.maxX - size.width)
        let maximumY = max(visibleFrame.minY, visibleFrame.maxY - size.height)
        return CGRect(
            x: min(max(origin.x, visibleFrame.minX), maximumX),
            y: min(max(origin.y, visibleFrame.minY), maximumY),
            width: size.width,
            height: size.height
        )
    }
}

private final class SnipLibraryWindowController: NSWindowController, NSWindowDelegate {
    private var didNotifyClose = false
    private let onClose: () -> Void

    init(window: NSWindow, onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("SnipLibraryWindowController is programmatic-only.")
    }

    override func close() {
        super.close()
        notifyClose()
    }

    func windowWillClose(_ notification: Notification) {
        notifyClose()
    }

    private func notifyClose() {
        guard !didNotifyClose else { return }
        didNotifyClose = true
        onClose()
    }
}

private struct SnipLibraryWindowView: View {
    @ObservedObject var model: SnipLibraryWindowModel
    let onSelect: (UUID?) -> Void
    let onChangeScope: (SnipLibraryScope) -> Void
    let onSearchChanged: () -> Void
    let onRetryPreview: () -> Void
    let onRetryEntries: () -> Void
    let onLoadMore: () -> Void
    let onPrimaryAction: () -> Void
    let onFloat: () -> Void
    let onDelete: () -> Void
    let onEmptyRecycleBin: () -> Void

    var body: some View {
        HSplitView {
            browserPane
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 430)
                .background(
                    SnipLibrarySplitViewAutosaveBridge(
                        name: "SnipLibrarySplitView"
                    )
                )
            previewPane
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand { NSApp.keyWindow?.performClose(nil) }
        .accessibilityIdentifier("snip.library.window")
    }

    private var browserPane: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Library Section", selection: scopeBinding) {
                    ForEach(SnipLibraryScope.allCases) { scope in
                        Label(scope.title, systemImage: scope.systemImage).tag(scope)
                    }
                }
                .pickerStyle(.segmented)

                TextField("Search \(model.scope.title)", text: searchBinding)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(12)

            Divider()

            HStack {
                Text(model.resultsLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            Divider()

            if model.isLoadingEntries, model.visibleEntries.isEmpty {
                ProgressView("Loading Screenshots…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = model.entryLoadErrorMessage,
                      model.visibleEntries.isEmpty {
                ContentUnavailableView {
                    Label("Snip Library Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again", action: onRetryEntries)
                }
            } else if model.visibleEntries.isEmpty {
                ContentUnavailableView(
                    model.emptyTitle,
                    systemImage: model.scope.systemImage,
                    description: Text(model.emptyDescription)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.visibleEntries, selection: selectionBinding) { entry in
                    HStack(spacing: 10) {
                        DocumentPreviewThumbnailView(
                            packageURL: entry.packageURL,
                            thumbnailSize: CGSize(width: 84, height: 56),
                            cornerRadius: 8
                        )
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.libraryDisplayTitle)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(entry.savedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                    .tag(entry.id)
                    .onAppear {
                        if entry.id == model.visibleEntries.last?.id {
                            onLoadMore()
                        }
                    }
                }
                .accessibilityIdentifier("snip.library.list")

                if model.isLoadingEntries {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.vertical, 8)
                } else if model.hasMoreEntries {
                    Button("Load More", action: onLoadMore)
                        .buttonStyle(.link)
                        .padding(.vertical, 8)
                } else if model.entryLoadErrorMessage != nil {
                    Button("Try Again", action: onRetryEntries)
                        .buttonStyle(.link)
                        .padding(.vertical, 8)
                }
            }

            if model.scope == .recycleBin,
               model.totalCount > 0,
               model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Divider()
                Button(role: .destructive, action: onEmptyRecycleBin) {
                    Label("Empty Recycle Bin", systemImage: "trash.slash")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var previewPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.selectedEntry?.libraryDisplayTitle ?? "Screenshot")
                        .font(.headline)
                    if let entry = model.selectedEntry {
                        Text(entry.savedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if let imageModel = model.imageModel {
                    HistoryPreviewZoomControls(model: imageModel)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 54)
            .background(.bar)

            Divider()

            ZStack {
                if let imageModel = model.imageModel, model.selectedEntry != nil {
                    ZoomableReferenceImageView(model: imageModel)
                        .id(model.displayedEntryID)
                        .opacity(model.isLoading ? 0.55 : 1)
                } else {
                    Color(nsColor: .underPageBackgroundColor)
                }

                if model.isLoading {
                    ProgressView("Loading Preview…")
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                } else if let errorMessage = model.errorMessage {
                    ContentUnavailableView {
                        Label("Preview Unavailable", systemImage: "photo.badge.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try Again", action: onRetryPreview)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 10) {
                Button(role: model.scope == .recycleBin ? .destructive : nil, action: onDelete) {
                    Label(model.scope == .recycleBin ? "Permanently Delete" : "Delete", systemImage: model.scope == .recycleBin ? "trash.slash" : "trash")
                }
                .disabled(model.selectedEntry == nil)

                Button("Float Reference", systemImage: "pin", action: onFloat)
                    .disabled(model.selectedEntry == nil)

                Spacer()

                Button(model.primaryActionTitle, action: onPrimaryAction)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selectedEntry == nil)
            }
            .padding(12)
        }
    }

    private var scopeBinding: Binding<SnipLibraryScope> {
        Binding(
            get: { model.scope },
            set: { value in onChangeScope(value) }
        )
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: { model.searchQuery },
            set: { value in
                model.searchQuery = value
                onSearchChanged()
            }
        )
    }

    private var selectionBinding: Binding<UUID?> {
        Binding(
            get: { model.selectedEntryID },
            set: { value in onSelect(value) }
        )
    }
}

private struct SnipLibrarySplitViewAutosaveBridge: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { configureSplitView(containing: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configureSplitView(containing: nsView) }
    }

    private func configureSplitView(containing view: NSView) {
        var ancestor = view.superview
        while let candidate = ancestor {
            if let splitView = candidate as? NSSplitView {
                splitView.autosaveName = NSSplitView.AutosaveName(name)
                return
            }
            ancestor = candidate.superview
        }
    }
}

@MainActor
extension DocumentWorkflowModel {
    func presentSnipLibrary(
        initialScope: SnipLibraryScope? = nil,
        searchQuery: String? = nil,
        selectedEntryID: UUID? = nil
    ) {
        snipLibraryCoordinator.present(
            snipLibraryRequest(),
            initialScope: initialScope,
            searchQuery: searchQuery,
            selectedEntryID: selectedEntryID,
            parentWindow: NSApp.keyWindow ?? NSApp.mainWindow
        )
    }

    func refreshPresentedSnipLibrary() {
        guard snipLibraryCoordinator.isPresented else {
            return
        }
        snipLibraryCoordinator.update(snipLibraryRequest())
    }

    private func snipLibraryRequest() -> SnipLibraryRequest {
        let store = recoveryStore
        let currentSessionID = currentRecoverySessionID
        return SnipLibraryRequest(
            outOfCapturePatternSettings: editorOutOfCapturePatternSettings,
            loadPage: { scope, query, offset, limit in
                await Task.detached(priority: .userInitiated) {
                    switch scope {
                    case .recent:
                        store.recentSnipPage(
                            matching: query,
                            excluding: currentSessionID,
                            offset: offset,
                            limit: limit
                        )
                    case .history:
                        store.snipHistorySessionPage(
                            matching: query,
                            offset: offset,
                            limit: limit
                        )
                    case .recycleBin:
                        store.recycledSnipPage(
                            matching: query,
                            offset: offset,
                            limit: limit
                        )
                    }
                }.value
            },
            onOpenRecent: { [weak self] entry in
                self?.restoreRecentSnipEntry(entry)
            },
            onOpenHistory: { [weak self] entry in
                self?.restoreHistoryEntry(entry)
            },
            onRestoreRecycled: { [weak self] entry in
                self?.restoreRecycledHistoryEntry(entry)
            },
            onFloat: { [weak self] entry in
                self?.floatHistoryReference(entry)
            },
            onDelete: { [weak self] entry in
                self?.deleteCaptureHistorySession(entry)
            },
            onPermanentlyDelete: { [weak self] entry in
                self?.requestPermanentlyDeleteRecycledHistoryEntry(entry)
            },
            onEmptyRecycleBin: { [weak self] in
                self?.requestEmptyRecycleBin()
            }
        )
    }
}
