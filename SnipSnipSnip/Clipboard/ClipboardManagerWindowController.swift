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
    private weak var model: AppModel?
    private var previousFrontmostApplication: NSRunningApplication?

    init(model: AppModel) {
        self.model = model

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
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
        panel.contentView = NSHostingView(rootView: ClipboardManagerView(model: model))

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

        if let frontmostApplication = NSWorkspace.shared.frontmostApplication,
           frontmostApplication.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousFrontmostApplication = frontmostApplication
        }

        if !window.isVisible {
            window.center()
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func activatePreviousApplicationForPaste() {
        previousFrontmostApplication?.activate(options: [])
    }
}

struct ClipboardManagerView: View {
    @ObservedObject var model: AppModel
    @State private var selectedItemID: ClipboardItem.ID?
    @FocusState private var isSearchFocused: Bool

    private var filteredItems: [ClipboardItem] {
        model.clipboardHistoryItems.filter { item in
            switch model.clipboardFilter {
            case .all:
                break
            case .pinned:
                guard item.isPinned else { return false }
            default:
                guard item.kind.filter == model.clipboardFilter else { return false }
            }

            return item.matchesSearchQuery(model.clipboardSearchQuery)
        }
    }

    private var selectedItem: ClipboardItem? {
        filteredItems.first(where: { $0.id == selectedItemID }) ?? filteredItems.first
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
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("Search clipboard history", text: $model.clipboardSearchQuery)
                    .textFieldStyle(.roundedBorder)
                    .focused($isSearchFocused)

                Button {
                    model.clearUnpinnedClipboardItems()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Clear unpinned clipboard history")
                .disabled(model.clipboardHistoryItems.allSatisfy(\.isPinned))
            }

            Picker("Filter", selection: $model.clipboardFilter) {
                ForEach(ClipboardItemFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if !model.clipboardPreferences.isEnabled {
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
                description: Text("Copied text, links, images, files, and SnipSnipSnip screenshots appear here.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                            ClipboardItemRow(
                                item: item,
                                image: model.clipboardPreviewImage(for: item),
                                shortcutNumber: index < 9 ? index + 1 : nil,
                                isSelected: selectedItemID == item.id,
                                onCopy: { model.copyClipboardItem(item) },
                                onCopyPlainText: { model.copyClipboardItemAsPlainText(item) },
                                onPaste: { model.pasteClipboardItem(item) },
                                onPastePlainText: { model.pasteClipboardItemAsPlainText(item) },
                                onTogglePinned: { model.togglePinnedClipboardItem(item) },
                                onDelete: { model.deleteClipboardItem(item) },
                                onOpenSnip: { model.openClipboardSnip(item) }
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
                .focusable()
                .onMoveCommand(perform: moveSelection)
                .onChange(of: selectedItemID) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("\(filteredItems.count) shown")
                .foregroundStyle(.secondary)

            Spacer()

            if let selectedItem, selectedItem.supportsPlainTextSanitization {
                Menu("Plain Text") {
                    Button("Copy Plain Text") {
                        model.copyClipboardItemAsPlainText(selectedItem)
                    }

                    Button("Copy & Paste Plain Text") {
                        model.pasteClipboardItemAsPlainText(selectedItem)
                    }
                }
                .help("Sanitize formatting by writing only the plain text value.")
            }

            Button("Copy") {
                if let selectedItem {
                    model.copyClipboardItem(selectedItem)
                }
            }
            .disabled(selectedItem == nil)

            Button("Copy & Paste") {
                if let selectedItem {
                    model.pasteClipboardItem(selectedItem)
                }
            }
            .keyboardShortcut(.return, modifiers: [])
            .help("Copy this item, keep Clipboard History open, return to the previous app, and send Command-V.")
            .disabled(selectedItem == nil)
        }
        .padding(12)
    }

    private var shortcutHandler: some View {
        ClipboardShortcutHandler { number in
            guard number > 0, number <= filteredItems.count else {
                return
            }

            model.copyClipboardItem(filteredItems[number - 1])
        }
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
}

private struct ClipboardItemRow: View {
    let item: ClipboardItem
    let image: NSImage?
    let shortcutNumber: Int?
    let isSelected: Bool
    let onCopy: () -> Void
    let onCopyPlainText: () -> Void
    let onPaste: () -> Void
    let onPastePlainText: () -> Void
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
                    Text(item.kind.typeLabel)
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

            if item.supportsPlainTextSanitization {
                Menu {
                    Button("Copy Plain Text", action: onCopyPlainText)
                    Button("Copy & Paste Plain Text", action: onPastePlainText)
                } label: {
                    Image(systemName: "textformat")
                }
                .help("Sanitize formatting")
            }

            Button(action: onPaste) {
                Image(systemName: "keyboard")
            }
            .help("Copy & Paste: copy this item, keep Clipboard History open, return to the previous app, and send Command-V.")

            if case .snip = item.kind {
                Button(action: onOpenSnip) {
                    Image(systemName: "rectangle.and.pencil.and.ellipsis")
                }
                .help("Open snip in editor")
            }

            Button(action: onTogglePinned) {
                Image(systemName: item.isPinned ? "pin.slash" : "pin")
            }
            .help(item.isPinned ? "Unpin" : "Pin")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .help("Delete")
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

private struct ClipboardShortcutHandler: NSViewRepresentable {
    let onNumberShortcut: (Int) -> Void

    func makeNSView(context: Context) -> ClipboardShortcutView {
        let view = ClipboardShortcutView()
        view.onNumberShortcut = onNumberShortcut
        return view
    }

    func updateNSView(_ view: ClipboardShortcutView, context: Context) {
        view.onNumberShortcut = onNumberShortcut
    }
}

private final class ClipboardShortcutView: NSView {
    var onNumberShortcut: ((Int) -> Void)?
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
            guard let self,
                  self.window?.isKeyWindow == true,
                  event.modifierFlags.intersection([.command, .control, .option]) == .option,
                  let characters = event.charactersIgnoringModifiers,
                  let number = Int(characters),
                  (1...9).contains(number) else {
                return event
            }

            self.onNumberShortcut?(number)
            return nil
        }
    }
}
