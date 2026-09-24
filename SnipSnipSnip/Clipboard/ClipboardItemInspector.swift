import AppKit
import SwiftUI

struct ClipboardItemInspector: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let item: ClipboardItem
    let image: NSImage?
    @Binding var text: String
    let isEdited: Bool
    let collections: [String]
    let commands: ClipboardItemCommands
    let reset: () -> Void
    let prettyPrintJSON: () -> Void
    let addCollection: (String) -> Void
    let removeCollection: (String) -> Void
    @State private var showsDetails = false
    @State private var showsCollectionPicker = false
    @State private var collectionName = ""
    @State private var isEditing = false
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 22) {
                            preview
                            HStack(spacing: 10) {
                                openAction
                                if item.supportsPlainTextSanitization, !isEditing {
                                    Button("Edit Text", systemImage: "pencil") {
                                        isEditing = true
                                        isEditorFocused = true
                                    }
                                    .accessibilityIdentifier("clipboard.editText")
                                }
                            }
                            if isEdited, !isEditing {
                                Label("Edited · Original kept", systemImage: "pencil")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Spacer(minLength: 28)
                        metadata
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 18)
                    .frame(minHeight: geometry.size.height, alignment: .top)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityIdentifier("clipboard.inspector")
        .onChange(of: item.id) { _, _ in
            showsCollectionPicker = false
            collectionName = ""
            isEditing = false
            isEditorFocused = false
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label(item.semanticType?.label ?? item.kind.typeLabel,
                  systemImage: ClipboardItemPresentation.symbol(for: item))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button(action: commands.togglePinned) {
                Image(systemName: item.isPinned ? "pin.fill" : "pin")
            }
            .help(item.isPinned ? "Unpin" : "Pin")
            .accessibilityLabel(item.isPinned ? "Unpin" : "Pin")
            .accessibilityIdentifier("clipboard.pin")
            Menu {
                ClipboardItemMenuContent(item: item, commands: commands)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More Actions")
            .accessibilityLabel("More Actions")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            HStack(spacing: 8) {
                ClipboardSourceIcon(source: item.sourceApp)
                Text(item.sourceApp?.displayName ?? item.kind.typeLabel).lineLimit(1)
                Spacer(minLength: 4)
                Text(item.copiedAt.formatted(date: .abbreviated, time: .shortened)).lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            collectionSection

            DisclosureGroup("Details", isExpanded: $showsDetails) {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Copied", value: item.copiedAt.formatted(date: .abbreviated, time: .standard))
                    if let source = item.sourceApp {
                        LabeledContent("Source", value: source.displayName)
                    }
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file))
                    if let payload = item.storedPayload {
                        LabeledContent("Items", value: "\(payload.items.count)")
                    }
                }
                .textSelection(.enabled)
                .padding(.top, 12)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("clipboard.details")
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let image {
            ClipboardImagePreview(image: image)
                .frame(height: 300)
                .accessibilityLabel("Clipboard Image Preview")
            if item.title != item.kind.typeLabel {
                Text(item.title).font(.title3.weight(.medium)).textSelection(.enabled)
            }
        }

        if item.supportsPlainTextSanitization {
            textPreview
        } else if case let .fileURLs(paths) = item.kind {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(paths.enumerated()), id: \.offset) { _, path in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: FileManager.default.fileExists(atPath: path) ? "doc" : "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(FileManager.default.fileExists(atPath: path) ? "File Available" : "File Unavailable")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(URL(fileURLWithPath: path).lastPathComponent).font(.body.weight(.medium))
                            Text(path).font(.caption).foregroundStyle(.secondary)
                        }
                        .textSelection(.enabled)
                    }
                }
            }
        } else if image == nil {
            Text(item.searchableText)
                .font(.body)
                .textSelection(.enabled)
        }
    }

    private var textPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isEditing {
                Text("Edit before copying. The original stays unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $text)
                    .id(item.id)
                    .focused($isEditorFocused)
                    .font(ClipboardItemPresentation.usesMonospacedText(item) ? .body.monospaced() : .body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 240)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(contrast == .increased ? Color.primary : Color(nsColor: .separatorColor)))
                    .accessibilityLabel("Edit Clipboard Text")
                    .accessibilityIdentifier("clipboard.textEditor")

                HStack(spacing: 8) {
                    Menu("Transform") {
                        Button("Trim Whitespace") { text = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                        Button("UPPERCASE") { text = text.uppercased() }
                        Button("lowercase") { text = text.lowercased() }
                        Button("Pretty Print JSON", action: prettyPrintJSON)
                    }
                    .fixedSize()
                    Spacer(minLength: 0)
                    if isEdited {
                        Label("Edited", systemImage: "pencil")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("This draft is kept while Clipboard History is open.")
                    }
                    Button("Reset", action: reset)
                        .disabled(!isEdited)
                        .help("Restore this draft to the original clipboard text.")
                        .accessibilityIdentifier("clipboard.resetDraft")
                    Button("Done") { isEditing = false; isEditorFocused = false }
                        .accessibilityIdentifier("clipboard.finishEditing")
                }
                .controlSize(.small)
            } else {
                ClipboardTextPreview(item: item, text: text)
                    .accessibilityIdentifier("clipboard.textPreview")
            }
        }
    }

    @ViewBuilder
    private var openAction: some View {
        switch item.kind {
        case .link:
            Button("Open Link", systemImage: "arrow.up.right.square", action: commands.open)
        case .snip:
            Button("Open Snip in Editor", systemImage: "pencil", action: commands.open)
        case .fileURLs:
            ViewThatFits(in: .horizontal) {
                HStack {
                    Button("Open", action: commands.open)
                    Button("Reveal in Finder", action: commands.reveal)
                }
                VStack(alignment: .leading) {
                    Button("Open", action: commands.open)
                    Button("Reveal in Finder", action: commands.reveal)
                }
            }
        default: EmptyView()
        }
    }

    private var collectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                showsCollectionPicker = true
            } label: {
                Label("Add to Collection", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Add to Collection")
            .popover(isPresented: $showsCollectionPicker) { collectionPicker }
            .accessibilityIdentifier("clipboard.addCollection")
            ForEach(item.collectionNames, id: \.self) { name in
                HStack {
                    Label(name, systemImage: "folder").lineLimit(2)
                    Spacer(minLength: 0)
                    Button { removeCollection(name) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help(String(localized: "Remove from \(name)"))
                        .accessibilityLabel(String(localized: "Remove from \(name)"))
                }
                .font(.caption)
            }
        }
    }

    private var collectionPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add to Collection").font(.headline)
            let available = collections.filter { name in
                !item.collectionNames.contains { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }
            }
            if !available.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(available, id: \.self) { name in
                            Button {
                                addCollection(name)
                                showsCollectionPicker = false
                            } label: {
                                Label(name, systemImage: "folder").frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .frame(maxHeight: 160)
                Divider()
            }
            TextField("Collection name", text: $collectionName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(createCollection)
            HStack {
                Button("Cancel") { showsCollectionPicker = false }
                Spacer()
                Button("Add", action: createCollection)
                    .disabled(collectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 270)
    }

    private func createCollection() {
        let name = collectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        addCollection(name)
        collectionName = ""
        showsCollectionPicker = false
    }
}
