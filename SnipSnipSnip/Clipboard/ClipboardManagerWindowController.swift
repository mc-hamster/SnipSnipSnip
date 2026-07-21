import AppKit
import SwiftUI

enum ClipboardManagerWindowID {
    static let identifier = "clipboard-history"

    static func isClipboardManagerWindow(_ window: NSWindow?) -> Bool {
        window?.identifier?.rawValue == identifier
    }
}

@MainActor
final class ClipboardManagerWindowController: NSWindowController {
    private weak var clipboard: ClipboardWorkflowModel?
    private let workspace: any WorkspaceServicing
    private var previousApplicationProcessIdentifier: pid_t?
    private var hasPositionedWindow = false

    init(clipboard: ClipboardWorkflowModel, workspace: any WorkspaceServicing) {
        self.clipboard = clipboard
        self.workspace = workspace

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier(ClipboardManagerWindowID.identifier)
        panel.title = "Clipboard History"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: ClipboardManagerView(clipboard: clipboard))

        super.init(window: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("ClipboardManagerWindowController is programmatic-only; use init(model:) instead of init(coder:).")
    }

    func show() {
        guard let window else {
            return
        }

        if !window.isVisible {
            previousApplicationProcessIdentifier = workspace.frontmostApplicationProcessIdentifier
        }

        if !hasPositionedWindow {
            window.center()
            hasPositionedWindow = true
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct ClipboardManagerView: View {
    @ObservedObject var clipboard: ClipboardWorkflowModel
    @State private var selectedItemID: ClipboardItem.ID?
    @FocusState private var isSearchFocused: Bool
    @State private var timeFilter: ClipboardTimeFilter = .all
    @State private var sourceFilter: String?
    @State private var collectionFilter: String?
    @State private var showsClearConfirmation = false
    @State private var editedText = ""
    @State private var newCollectionName = ""

    private var filteredItems: [ClipboardItem] {
        clipboard.clipboardHistoryItems.filter { item in
            switch clipboard.filter {
            case .all:
                break
            case .pinned:
                guard item.isPinned else { return false }
            default:
                guard item.kind.filter == clipboard.filter else { return false }
            }

            if let sourceFilter,
               item.sourceApp?.bundleIdentifier != sourceFilter,
               item.sourceApp?.displayName != sourceFilter {
                return false
            }

            if !timeFilter.includes(item.copiedAt) {
                return false
            }
            if let collectionFilter,
               !item.collectionNames.contains(where: { $0.localizedCaseInsensitiveCompare(collectionFilter) == .orderedSame }) {
                return false
            }

            return item.matchesSearchQuery(clipboard.searchQuery)
        }
    }

    private var selectedItem: ClipboardItem? {
        filteredItems.first(where: { $0.id == selectedItemID }) ?? filteredItems.first
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
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .background(shortcutHandler)
        .frame(minWidth: 460, minHeight: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            selectedItemID = filteredItems.first?.id
            isSearchFocused = true
        }
        .onChange(of: filteredItems.map(\.id)) { _, ids in
            if let selectedItemID, ids.contains(selectedItemID) {
                return
            }

            selectedItemID = ids.first
        }
        .onChange(of: selectedItemID) { _, _ in
            editedText = selectedItem?.plainTextValue ?? ""
        }
        .confirmationDialog(
            "Clear unpinned clipboard history?",
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Unpinned History", role: .destructive) {
                clipboard.clearUnpinnedClipboardItems()
            }
        } message: {
            Text("Pinned items will be kept. This action cannot be undone.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("Search clipboard history", text: $clipboard.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .focused($isSearchFocused)

                Button {
                    showsClearConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Clear unpinned clipboard history")
                .disabled(clipboard.clipboardHistoryItems.allSatisfy(\.isPinned))
            }

            Picker("Filter", selection: $clipboard.filter) {
                ForEach(ClipboardItemFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.menu)

            HStack(spacing: 10) {
                Picker("When", selection: $timeFilter) {
                    ForEach(ClipboardTimeFilter.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.menu)

                Picker("Source", selection: $sourceFilter) {
                    Text("All Sources").tag(String?.none)
                    ForEach(sourceOptions, id: \.value) { option in
                        Text(option.label).tag(Optional(option.value))
                    }
                }
                .pickerStyle(.menu)

                if !collectionOptions.isEmpty {
                    Picker("Collection", selection: $collectionFilter) {
                        Text("All Collections").tag(String?.none)
                        ForEach(collectionOptions, id: \.self) { name in
                            Text(name).tag(Optional(name))
                        }
                    }
                    .pickerStyle(.menu)
                }

                Spacer()

                Menu {
                    if clipboard.isClipboardMonitoringPaused {
                        Button("Resume Now", action: clipboard.resumeClipboardMonitoring)
                    } else {
                        Button("Pause for 5 Minutes") { clipboard.pauseClipboardMonitoring(for: 5 * 60) }
                        Button("Pause for 1 Hour") { clipboard.pauseClipboardMonitoring(for: 60 * 60) }
                        Button("Pause Until Restart") { clipboard.pauseClipboardMonitoring(for: nil) }
                    }
                } label: {
                    Label(
                        clipboard.isClipboardMonitoringPaused ? "Paused" : "Recording",
                        systemImage: clipboard.isClipboardMonitoringPaused ? "pause.circle.fill" : "record.circle"
                    )
                }
                .menuStyle(.borderlessButton)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if !clipboard.preferences.isEnabled {
            ContentUnavailableView(
                "Clipboard History Disabled",
                systemImage: "clipboard",
                description: Text("Enable clipboard history in Settings > Clipboard.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredItems.isEmpty {
            ContentUnavailableView(
                "No Clipboard Items",
                systemImage: "clipboard",
                description: Text("Copied text, links, images, files, and \(AppBranding.displayName) screenshots appear here.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HSplitView {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                                ClipboardItemRow(
                                    item: item,
                                    image: clipboard.clipboardPreviewImage(for: item),
                                    shortcutNumber: index < 9 ? index + 1 : nil,
                                    isSelected: selectedItemID == item.id,
                                    onCopy: { clipboard.copyClipboardItem(item) },
                                    onCopyPlainText: { clipboard.copyClipboardItemAsPlainText(item) },
                                    onTogglePinned: { clipboard.togglePinnedClipboardItem(item) },
                                    onDelete: { clipboard.deleteClipboardItem(item) },
                                    onOpenSnip: { clipboard.openClipboardSnip(item) }
                                )
                                .id(item.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedItemID = item.id
                                }

                                if item.id != filteredItems.last?.id {
                                    Divider()
                                        .padding(.leading, 76)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .frame(minWidth: 380)
                    .focusable()
                    .onMoveCommand(perform: moveSelection)
                    .onChange(of: selectedItemID) { _, id in
                        guard let id else { return }
                        proxy.scrollTo(id, anchor: .center)
                    }
                }

                detailView
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 420, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        if let item = selectedItem {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let image = clipboard.clipboardPreviewImage(for: item) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 220)
                            .frame(maxWidth: .infinity)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    }

                    Text(item.semanticType?.label ?? item.kind.typeLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    if item.supportsPlainTextSanitization {
                        if item.semanticType == .color, let color = Color.clipboardColor(from: editedText) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(color)
                                .frame(height: 64)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                        }
                        TextEditor(text: $editedText)
                            .font(.body.monospaced())
                            .frame(minHeight: 150)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))

                        HStack {
                            Menu("Transform") {
                                Button("Trim Whitespace") { editedText = editedText.trimmingCharacters(in: .whitespacesAndNewlines) }
                                Button("UPPERCASE") { editedText = editedText.uppercased() }
                                Button("lowercase") { editedText = editedText.lowercased() }
                                Button("Pretty Print JSON") { prettyPrintEditedJSON() }
                            }
                            Button("Copy Edited") { clipboard.copyEditedText(editedText) }
                                .disabled(editedText.isEmpty)
                        }
                    } else if case let .fileURLs(paths) = item.kind {
                        ForEach(paths, id: \.self) { path in
                            Label {
                                Text(path).textSelection(.enabled)
                            } icon: {
                                Image(systemName: FileManager.default.fileExists(atPath: path) ? "doc" : "exclamationmark.triangle")
                            }
                        }
                        HStack {
                            Button("Open") { clipboard.openClipboardItem(item) }
                            Button("Reveal") { clipboard.revealClipboardFiles(item) }
                        }
                    } else {
                        Text(item.searchableText)
                            .textSelection(.enabled)
                    }

                    Divider()
                    LabeledContent("Copied", value: item.copiedAt.formatted(date: .abbreviated, time: .standard))
                    if let source = item.sourceApp {
                        LabeledContent("Source", value: source.displayName)
                    }
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file))
                    if let payload = item.storedPayload {
                        LabeledContent("Items", value: "\(payload.items.count)")
                    }

                    if !item.collectionNames.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Collections").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(item.collectionNames, id: \.self) { name in
                                HStack {
                                    Text(name)
                                    Spacer()
                                    Button("Remove") { clipboard.toggleClipboardCollection(name, for: item) }
                                        .buttonStyle(.borderless)
                                }
                            }
                        }
                    }

                    HStack {
                        TextField("Collection name", text: $newCollectionName)
                        Button("Add") {
                            clipboard.toggleClipboardCollection(newCollectionName, for: item)
                            newCollectionName = ""
                        }
                        .disabled(newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if case .link = item.kind {
                        Button("Open Link") { clipboard.openClipboardItem(item) }
                    }
                }
                .padding(16)
            }
        } else {
            ContentUnavailableView("No Selection", systemImage: "clipboard")
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("\(filteredItems.count) shown")
                .foregroundStyle(.secondary)

            if let actionMessage = clipboard.actionMessage {
                Text(actionMessage)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let selectedItem, selectedItem.supportsPlainTextSanitization {
                Menu("Plain Text") {
                    Button("Copy Plain Text") {
                        clipboard.copyClipboardItemAsPlainText(selectedItem)
                    }
                }
                .help("Sanitize formatting by writing only the plain text value.")
            }

            Button("Copy") {
                if let selectedItem {
                    clipboard.copyClipboardItem(selectedItem)
                }
            }
            .disabled(selectedItem == nil)

        }
        .padding(12)
    }

    private var shortcutHandler: some View {
        ClipboardShortcutHandler(
            onNumberShortcut: { number in
                guard number > 0, number <= filteredItems.count else { return }
                clipboard.copyClipboardItem(filteredItems[number - 1])
            },
            onMove: moveSelection,
            onReturn: { modifiers in
                guard let selectedItem else { return }
                if modifiers.contains(.command) {
                    clipboard.copyClipboardItem(selectedItem)
                }
            },
            onEscape: {
                if !clipboard.searchQuery.isEmpty {
                    clipboard.searchQuery = ""
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
        )
        .frame(width: 0, height: 0)
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !filteredItems.isEmpty else {
            selectedItemID = nil
            return
        }

        let currentIndex = selectedItemID.flatMap { id in
            filteredItems.firstIndex(where: { $0.id == id })
        } ?? 0

        switch direction {
        case .up:
            selectedItemID = filteredItems[max(currentIndex - 1, 0)].id
        case .down:
            selectedItemID = filteredItems[min(currentIndex + 1, filteredItems.count - 1)].id
        default:
            break
        }
    }

    private func prettyPrintEditedJSON() {
        guard let data = editedText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let formatted = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: formatted, encoding: .utf8) else {
            clipboard.actionMessage = "The edited text is not valid JSON."
            return
        }
        editedText = text
    }
}

private enum ClipboardTimeFilter: String, CaseIterable, Identifiable {
    case all, today, sevenDays, thirtyDays

    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "Any Time"
        case .today: "Today"
        case .sevenDays: "Last 7 Days"
        case .thirtyDays: "Last 30 Days"
        }
    }

    func includes(_ date: Date) -> Bool {
        switch self {
        case .all:
            true
        case .today:
            Calendar.current.isDateInToday(date)
        case .sevenDays:
            date >= (Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast)
        case .thirtyDays:
            date >= (Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast)
        }
    }
}

private struct ClipboardItemRow: View {
    let item: ClipboardItem
    let image: NSImage?
    let shortcutNumber: Int?
    let isSelected: Bool
    let onCopy: () -> Void
    let onCopyPlainText: () -> Void
    let onTogglePinned: () -> Void
    let onDelete: () -> Void
    let onOpenSnip: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            preview
                .frame(width: 52, height: 42)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.semanticType?.label ?? item.kind.typeLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    if let shortcutNumber {
                        Text("⌥\(shortcutNumber)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }

                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 6)
                }

                Text(item.title)
                    .lineLimit(2)
                    .font(.callout)

                HStack(spacing: 6) {
                    Text(item.copiedAt.formatted(date: .abbreviated, time: .shortened))
                    if let sourceApp = item.sourceApp {
                        Text("•")
                        Text(sourceApp.displayName)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            actions
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.22))
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Image(systemName: systemImageName)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            copyButton

            Menu {
                if item.supportsPlainTextSanitization {
                    Button("Copy Plain Text", action: onCopyPlainText)
                    Divider()
                }
                Button(item.isPinned ? "Unpin" : "Pin", action: onTogglePinned)
                if case .snip = item.kind {
                    Button("Open Snip in Editor", action: onOpenSnip)
                }
                Divider()
                Button("Delete", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .help("More actions")
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private var copyButton: some View {
        if let shortcutNumber {
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy. Press Option-\(shortcutNumber) while Clipboard History is focused.")
        } else {
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy")
        }
    }

    private var systemImageName: String {
        switch item.kind {
        case .text:
            return "text.alignleft"
        case .link:
            return "link"
        case .image:
            return "photo"
        case .fileURLs:
            return "doc"
        case .snip:
            return "scissors"
        }
    }

}

private extension Color {
    static func clipboardColor(from text: String) -> Color? {
        let hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard [3, 4, 6, 8].contains(hex.count) else { return nil }
        let expanded = hex.count <= 4 ? hex.map { "\($0)\($0)" }.joined() : hex
        guard let value = UInt64(expanded, radix: 16) else { return nil }
        let hasAlpha = expanded.count == 8
        let red = Double((value >> (hasAlpha ? 24 : 16)) & 0xff) / 255
        let green = Double((value >> (hasAlpha ? 16 : 8)) & 0xff) / 255
        let blue = Double((value >> (hasAlpha ? 8 : 0)) & 0xff) / 255
        let alpha = hasAlpha ? Double(value & 0xff) / 255 : 1
        return Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}

private struct ClipboardShortcutHandler: NSViewRepresentable {
    let onNumberShortcut: (Int) -> Void
    let onMove: (MoveCommandDirection) -> Void
    let onReturn: (NSEvent.ModifierFlags) -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> ClipboardShortcutView {
        let view = ClipboardShortcutView()
        view.onNumberShortcut = onNumberShortcut
        view.onMove = onMove
        view.onReturn = onReturn
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ view: ClipboardShortcutView, context: Context) {
        view.onNumberShortcut = onNumberShortcut
        view.onMove = onMove
        view.onReturn = onReturn
        view.onEscape = onEscape
    }
}

private final class ClipboardShortcutView: NSView {
    var onNumberShortcut: ((Int) -> Void)?
    var onMove: ((MoveCommandDirection) -> Void)?
    var onReturn: ((NSEvent.ModifierFlags) -> Void)?
    var onEscape: (() -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if window == nil {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            return
        }

        guard monitor == nil else {
            return
        }

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else {
                return event
            }

            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            let isEditingMultilineText = (self.window?.firstResponder as? NSTextView)?.isFieldEditor == false
            if modifiers == .option,
               let characters = event.charactersIgnoringModifiers,
               let number = Int(characters),
               (1...9).contains(number) {
                self.onNumberShortcut?(number)
                return nil
            }

            switch event.keyCode {
            case 125 where modifiers.isEmpty && !isEditingMultilineText:
                self.onMove?(.down)
                return nil
            case 126 where modifiers.isEmpty && !isEditingMultilineText:
                self.onMove?(.up)
                return nil
            case 36 where modifiers.isEmpty && isEditingMultilineText:
                return event
            case 36 where modifiers.isSubset(of: [.command, .shift]):
                self.onReturn?(modifiers)
                return nil
            case 53 where modifiers.isEmpty:
                self.onEscape?()
                return nil
            default:
                return event
            }
        }
    }
}
