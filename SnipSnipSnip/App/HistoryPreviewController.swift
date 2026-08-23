import AppKit
import Combine
import SwiftUI

@MainActor
struct HistoryPreviewPrimaryAction {
    let title: String
    let systemImage: String
    let help: String
    let perform: @MainActor (DocumentHistoryEntry) -> Void
}

@MainActor
struct HistoryPreviewRequest {
    let contextTitle: String
    let entries: [DocumentHistoryEntry]
    let selectedEntryID: UUID
    let primaryAction: HistoryPreviewPrimaryAction?
    let onFloat: @MainActor (DocumentHistoryEntry) -> Void
}

nonisolated enum HistoryPreviewZoomContinuityPolicy {
    private static let maximumAspectRatioChange: CGFloat = 1.8

    static func shouldPreserveManualZoom(from previousSize: CGSize, to nextSize: CGSize) -> Bool {
        guard previousSize.width > 0,
              previousSize.height > 0,
              nextSize.width > 0,
              nextSize.height > 0
        else {
            return false
        }

        let previousAspectRatio = previousSize.width / previousSize.height
        let nextAspectRatio = nextSize.width / nextSize.height
        let ratioChange = max(previousAspectRatio, nextAspectRatio)
            / min(previousAspectRatio, nextAspectRatio)
        return ratioChange <= maximumAspectRatioChange
    }
}

nonisolated enum HistoryPreviewWindowSizing {
    static let defaultSize = CGSize(width: 640, height: 460)
    static let minimumSize = CGSize(width: 440, height: 300)

    static func initialFrame(parentFrame: CGRect?, visibleFrame: CGRect) -> CGRect {
        let width = min(defaultSize.width, max(visibleFrame.width - 40, 1))
        let height = min(defaultSize.height, max(visibleFrame.height - 40, 1))
        let size = CGSize(width: width, height: height)

        guard let parentFrame else {
            return CGRect(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.midY - size.height / 2,
                width: size.width,
                height: size.height
            ).integral
        }

        let outsideTrailingX = parentFrame.maxX + 12
        let canFitBesideParent = outsideTrailingX + size.width <= visibleFrame.maxX - 12
        let proposedX = canFitBesideParent
            ? outsideTrailingX
            : min(parentFrame.maxX - size.width - 28, visibleFrame.maxX - size.width - 20)
        let proposedY = min(parentFrame.maxY - size.height - 44, visibleFrame.maxY - size.height - 20)

        return CGRect(
            x: min(max(proposedX, visibleFrame.minX + 20), visibleFrame.maxX - size.width - 20),
            y: min(max(proposedY, visibleFrame.minY + 20), visibleFrame.maxY - size.height - 20),
            width: size.width,
            height: size.height
        ).integral
    }
}

@MainActor
final class HistoryPreviewWindowModel: ObservableObject {
    @Published private(set) var contextTitle: String
    @Published private(set) var entries: [DocumentHistoryEntry]
    @Published private(set) var selectedIndex: Int
    @Published private(set) var imageModel: FloatingReferenceWindowModel?
    @Published private(set) var displayedEntryID: UUID?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var primaryActionTitle: String?
    @Published private(set) var primaryActionSystemImage: String?
    @Published private(set) var primaryActionHelp: String?

    init(request: HistoryPreviewRequest) {
        let normalizedEntries = Self.normalizedEntries(request.entries)
        contextTitle = request.contextTitle
        entries = normalizedEntries
        selectedIndex = Self.selectedIndex(
            selectedEntryID: request.selectedEntryID,
            entries: normalizedEntries
        )
        primaryActionTitle = request.primaryAction?.title
        primaryActionSystemImage = request.primaryAction?.systemImage
        primaryActionHelp = request.primaryAction?.help
    }

    var selectedEntry: DocumentHistoryEntry? {
        entries.indices.contains(selectedIndex) ? entries[selectedIndex] : nil
    }

    var canSelectPrevious: Bool {
        selectedIndex > 0
    }

    var canSelectNext: Bool {
        selectedIndex + 1 < entries.count
    }

    var positionLabel: String {
        guard !entries.isEmpty else {
            return "No items"
        }
        return "\(selectedIndex + 1) of \(entries.count)"
    }

    func update(request: HistoryPreviewRequest) {
        contextTitle = request.contextTitle
        entries = Self.normalizedEntries(request.entries)
        selectedIndex = Self.selectedIndex(
            selectedEntryID: request.selectedEntryID,
            entries: entries
        )
        primaryActionTitle = request.primaryAction?.title
        primaryActionSystemImage = request.primaryAction?.systemImage
        primaryActionHelp = request.primaryAction?.help
        errorMessage = nil
    }

    @discardableResult
    func select(offset: Int) -> DocumentHistoryEntry? {
        let proposedIndex = selectedIndex + offset
        guard entries.indices.contains(proposedIndex) else {
            return nil
        }

        selectedIndex = proposedIndex
        errorMessage = nil
        return selectedEntry
    }

    func beginLoading() {
        isLoading = true
        errorMessage = nil
    }

    func display(
        image: CGImage,
        for entry: DocumentHistoryEntry,
        outOfCapturePatternSettings: EditorOutOfCapturePatternSettings
    ) {
        let subtitle = entry.savedAt.formatted(date: .abbreviated, time: .shortened)
        if let imageModel {
            imageModel.updateContent(
                title: entry.libraryDisplayTitle,
                subtitle: subtitle,
                image: image,
                outOfCapturePatternSettings: outOfCapturePatternSettings
            )
        } else {
            imageModel = FloatingReferenceWindowModel(
                title: entry.libraryDisplayTitle,
                subtitle: subtitle,
                image: image,
                outOfCapturePatternSettings: outOfCapturePatternSettings,
                preservesZoomAcrossImageChanges: true,
                togglesFitOnDoubleClick: true
            )
        }

        displayedEntryID = entry.id
        isLoading = false
        errorMessage = nil
    }

    func failLoading(message: String) {
        isLoading = false
        errorMessage = message
    }

    private static func normalizedEntries(_ entries: [DocumentHistoryEntry]) -> [DocumentHistoryEntry] {
        var seen: Set<UUID> = []
        return entries.filter { seen.insert($0.id).inserted }
    }

    private static func selectedIndex(
        selectedEntryID: UUID,
        entries: [DocumentHistoryEntry]
    ) -> Int {
        entries.firstIndex(where: { $0.id == selectedEntryID }) ?? 0
    }
}

@MainActor
final class HistoryPreviewCoordinator {
    private let files: any FileSystemServicing
    private var windowController: HistoryPreviewWindowController?
    private var request: HistoryPreviewRequest?
    private var currentPatternSettings: EditorOutOfCapturePatternSettings = .default
    private var loadTask: Task<Void, Never>?
    private var imageCache: [URL: CGImage] = [:]
    private var cacheOrder: [URL] = []
    private let maximumCachedImages = 6

    init(files: any FileSystemServicing) {
        self.files = files
    }

    func present(
        _ request: HistoryPreviewRequest,
        outOfCapturePatternSettings: EditorOutOfCapturePatternSettings
    ) {
        guard !request.entries.isEmpty else {
            return
        }

        self.request = request
        currentPatternSettings = outOfCapturePatternSettings
        let model: HistoryPreviewWindowModel
        if let windowController {
            model = windowController.model
            model.update(request: request)
            windowController.show(parentWindow: preferredParentWindow())
        } else {
            model = HistoryPreviewWindowModel(request: request)
            let controller = HistoryPreviewWindowController(
                model: model,
                initialFrame: initialWindowFrame(),
                onNavigate: { [weak self] offset in
                    self?.navigate(offset: offset)
                },
                onRetry: { [weak self] in
                    self?.loadSelectedEntry()
                },
                onFloat: { [weak self] in
                    self?.floatSelectedEntry()
                },
                onPrimaryAction: { [weak self] in
                    self?.performPrimaryAction()
                },
                onClose: { [weak self] in
                    self?.previewWindowDidClose()
                }
            )
            windowController = controller
            controller.show(parentWindow: preferredParentWindow())
        }

        loadSelectedEntry()
    }

    func close() {
        loadTask?.cancel()
        loadTask = nil
        request = nil
        let controller = windowController
        windowController = nil
        controller?.close()
    }

    func close(ifShowing entryID: UUID) {
        guard windowController?.model.selectedEntry?.id == entryID else {
            return
        }
        close()
    }

    private func navigate(offset: Int) {
        guard windowController?.model.select(offset: offset) != nil else {
            return
        }
        loadSelectedEntry()
    }

    private func loadSelectedEntry() {
        guard let model = windowController?.model,
              let entry = model.selectedEntry
        else {
            return
        }

        loadTask?.cancel()
        model.beginLoading()

        if let cachedImage = imageCache[entry.packageURL] {
            model.display(
                image: cachedImage,
                for: entry,
                outOfCapturePatternSettings: currentPatternSettings
            )
            return
        }

        let entryID = entry.id
        let packageURL = entry.packageURL
        let files = self.files
        let settings = currentPatternSettings
        loadTask = Task { @MainActor [weak self, weak model] in
            do {
                guard let image = try await HistoryPreviewImageLoader.loadImage(
                    from: packageURL,
                    files: files
                ) else {
                    guard model?.selectedEntry?.id == entryID else {
                        return
                    }
                    model?.failLoading(message: "This history preview is unavailable.")
                    return
                }

                guard !Task.isCancelled,
                      let self,
                      model?.selectedEntry?.id == entryID
                else {
                    return
                }

                cache(image, for: packageURL)
                model?.display(
                    image: image,
                    for: entry,
                    outOfCapturePatternSettings: settings
                )
            } catch is CancellationError {
                return
            } catch {
                guard model?.selectedEntry?.id == entryID else {
                    return
                }
                model?.failLoading(message: "This history preview could not be loaded. Try again.")
            }
        }
    }

    private func cache(_ image: CGImage, for packageURL: URL) {
        imageCache[packageURL] = image
        cacheOrder.removeAll { $0 == packageURL }
        cacheOrder.append(packageURL)

        while cacheOrder.count > maximumCachedImages {
            let removedURL = cacheOrder.removeFirst()
            imageCache[removedURL] = nil
        }
    }

    private func floatSelectedEntry() {
        guard let entry = windowController?.model.selectedEntry else {
            return
        }
        request?.onFloat(entry)
    }

    private func performPrimaryAction() {
        guard let entry = windowController?.model.selectedEntry,
              let action = request?.primaryAction
        else {
            return
        }

        action.perform(entry)
    }

    private func previewWindowDidClose() {
        loadTask?.cancel()
        loadTask = nil
        request = nil
        windowController = nil
    }

    private func preferredParentWindow() -> NSWindow? {
        if let keyWindow = NSApp.keyWindow,
           keyWindow !== windowController?.window {
            return keyWindow
        }
        return NSApp.mainWindow
    }

    private func initialWindowFrame() -> CGRect {
        let parentWindow = preferredParentWindow()
        let screen = parentWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        return HistoryPreviewWindowSizing.initialFrame(
            parentFrame: parentWindow?.frame,
            visibleFrame: visibleFrame
        )
    }
}

@MainActor
final class HistoryPreviewWindowController: NSWindowController, NSWindowDelegate {
    let model: HistoryPreviewWindowModel
    private weak var parentWindow: NSWindow?
    private var didNotifyClose = false
    private let onClose: () -> Void

    init(
        model: HistoryPreviewWindowModel,
        initialFrame: CGRect,
        onNavigate: @escaping (Int) -> Void,
        onRetry: @escaping () -> Void,
        onFloat: @escaping () -> Void,
        onPrimaryAction: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.model = model
        self.onClose = onClose

        let panel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "History Preview"
        panel.titleVisibility = .visible
        panel.titlebarAppearsTransparent = false
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .normal
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.minSize = HistoryPreviewWindowSizing.minimumSize
        panel.setFrameAutosaveName("HistoryPreviewWindow")
        panel.contentView = NSHostingView(
            rootView: HistoryPreviewWindowView(
                model: model,
                onNavigate: onNavigate,
                onRetry: onRetry,
                onFloat: onFloat,
                onPrimaryAction: onPrimaryAction
            )
        )

        super.init(window: panel)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("HistoryPreviewWindowController is programmatic-only; use init(model:initialFrame:...) instead of init(coder:).")
    }

    func show(parentWindow: NSWindow?) {
        if self.parentWindow !== parentWindow {
            detachFromParent()
            self.parentWindow = parentWindow
            if let window, let parentWindow {
                parentWindow.addChildWindow(window, ordered: .above)
            }
        }

        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    override func close() {
        detachFromParent()
        super.close()
        notifyCloseIfNeeded()
    }

    func windowWillClose(_ notification: Notification) {
        detachFromParent()
        notifyCloseIfNeeded()
    }

    private func detachFromParent() {
        guard let window, let parentWindow else {
            return
        }
        parentWindow.removeChildWindow(window)
        self.parentWindow = nil
    }

    private func notifyCloseIfNeeded() {
        guard !didNotifyClose else {
            return
        }
        didNotifyClose = true
        onClose()
    }
}

private struct HistoryPreviewWindowView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: HistoryPreviewWindowModel
    let onNavigate: (Int) -> Void
    let onRetry: () -> Void
    let onFloat: () -> Void
    let onPrimaryAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            commandBar
            Divider()
            previewStage
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onMoveCommand { direction in
            switch direction {
            case .left, .up:
                if model.canSelectPrevious {
                    onNavigate(-1)
                }
            case .right, .down:
                if model.canSelectNext {
                    onNavigate(1)
                }
            default:
                break
            }
        }
        .accessibilityIdentifier("history.preview.window")
        .onExitCommand {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    private var commandBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Button {
                    onNavigate(-1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!model.canSelectPrevious)
                .help("Show the previous \(model.contextTitle.lowercased()) item.")
                .accessibilityLabel("Previous history item")

                Button {
                    onNavigate(1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!model.canSelectNext)
                .help("Show the next \(model.contextTitle.lowercased()) item.")
                .accessibilityLabel("Next history item")
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.selectedEntry?.libraryDisplayTitle ?? "Screenshot")
                        .font(.caption.weight(.semibold))

                    if model.selectedEntry?.hasUnsavedChanges == true {
                        Text("Unsaved changes")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }

                Text("\(model.contextTitle) · \(model.positionLabel) · \(dateLabel)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            if let imageModel = model.imageModel {
                HistoryPreviewZoomControls(model: imageModel)
            }

            Menu {
                Button("Float Reference", systemImage: "pin", action: onFloat)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .help("More preview actions.")

            if let title = model.primaryActionTitle,
               let systemImage = model.primaryActionSystemImage {
                Button(action: onPrimaryAction) {
                    Label(title, systemImage: systemImage)
                }
                .buttonStyle(.borderedProminent)
                .help(model.primaryActionHelp ?? title)
                .accessibilityIdentifier("history.preview.primary-action")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
        .background(.bar)
    }

    private var previewStage: some View {
        ZStack {
            if let imageModel = model.imageModel {
                ZoomableReferenceImageView(model: imageModel)
                    .id(model.displayedEntryID)
                    .opacity(model.isLoading ? 0.55 : 1)
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: 0.16),
                        value: model.isLoading
                    )
                    .help("History preview. Scroll to pan, pinch or Command-scroll to zoom, and double-click to switch between Fit and Actual Size.")
            } else {
                Color(nsColor: .underPageBackgroundColor)
            }

            if model.isLoading {
                ProgressView("Loading Preview…")
                    .controlSize(.small)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityIdentifier("history.preview.loading")
            } else if let errorMessage = model.errorMessage {
                ContentUnavailableView {
                    Label("Preview Unavailable", systemImage: "photo.badge.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again", action: onRetry)
                }
                .accessibilityIdentifier("history.preview.error")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dateLabel: String {
        model.selectedEntry?.savedAt.formatted(date: .abbreviated, time: .shortened) ?? ""
    }
}

struct HistoryPreviewZoomControls: View {
    @ObservedObject var model: FloatingReferenceWindowModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            zoomControls(includesSlider: true)
            zoomControls(includesSlider: false)
        }
    }

    private func zoomControls(includesSlider: Bool) -> some View {
        HStack(spacing: 6) {
            Button {
                model.requestZoom(.zoomOut)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .disabled(!model.zoomState.canZoomOut)
            .keyboardShortcut("-", modifiers: .command)
            .help("Zoom out.")

            if includesSlider {
                Slider(value: zoomBinding, in: 1...1600)
                    .frame(width: 84)
                    .help("Set preview zoom.")
            }

            Menu {
                Button("Fit to View") {
                    model.requestZoom(.fit)
                }
                .keyboardShortcut("9", modifiers: .command)

                Button("Actual Size (1:1)") {
                    model.requestZoom(.actualSize)
                }
                .keyboardShortcut("0", modifiers: .command)
            } label: {
                Text("\(model.zoomState.percentage)%")
                    .monospacedDigit()
                    .frame(minWidth: 38)
            }
            .menuStyle(.borderlessButton)
            .help("Fit the screenshot to the window or show it at actual size.")

            Button {
                model.requestZoom(.zoomIn)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .disabled(!model.zoomState.canZoomIn)
            .keyboardShortcut("+", modifiers: .command)
            .help("Zoom in.")
        }
    }

    private var zoomBinding: Binding<Double> {
        Binding(
            get: { max(1, Double(model.zoomState.percentage)) },
            set: { model.requestZoom(.setPercentage($0)) }
        )
    }
}

nonisolated enum HistoryPreviewImageLoader {
    static func loadImage(
        from packageURL: URL,
        files: any FileSystemServicing
    ) async throws -> CGImage? {
        let task = Task.detached(priority: .userInitiated) { () throws -> CGImage? in
            try Task.checkCancellation()
            return try SSSDocumentPackage.loadDisplayPreview(
                from: packageURL,
                allowsExternalRecoveryBase: true,
                files: files
            )?.image
        }

        return try await withTaskCancellationHandler(operation: {
            try await task.value
        }, onCancel: {
            task.cancel()
        })
    }
}
