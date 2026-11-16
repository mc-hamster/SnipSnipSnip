import AppKit
import SwiftUI

struct ClipboardItemCommands {
    var copyTitle: String
    var copy: () -> Void
    var copyOriginal: () -> Void
    var copyPlainText: () -> Void
    var togglePinned: () -> Void
    var delete: () -> Void
    var open: () -> Void
    var reveal: () -> Void
}

/// The same commands are available from the row menu, contextual menu and inspector.
struct ClipboardItemMenuContent: View {
    let item: ClipboardItem
    let commands: ClipboardItemCommands
    var preview: (() -> Void)? = nil

    var body: some View {
        Button(commands.copyTitle, systemImage: "doc.on.doc", action: commands.copy)
        if item.supportsPlainTextSanitization {
            Button("Copy Original", action: commands.copyOriginal)
            Button("Copy Plain Text", action: commands.copyPlainText)
        }
        if let preview { Button("Preview", systemImage: "eye", action: preview) }
        Divider()
        Button(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin",
               action: commands.togglePinned)
        switch item.kind {
        case .snip:
            Button("Open Snip in Editor", systemImage: "pencil", action: commands.open)
        case .link:
            Button("Open Link", systemImage: "arrow.up.right.square", action: commands.open)
        case .fileURLs:
            Button("Open", systemImage: "arrow.up.right.square", action: commands.open)
            Button("Reveal in Finder", systemImage: "folder", action: commands.reveal)
        default: EmptyView()
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive, action: commands.delete)
    }
}

struct ClipboardItemRow: View {
    let entry: ClipboardHistoryEntry
    let image: NSImage?
    let isSelected: Bool
    let isEdited: Bool
    let justCopied: Bool
    let now: Date
    let commands: ClipboardItemCommands
    let activate: () -> Void
    let preview: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovered = false

    private var item: ClipboardItem { entry.item }
    private var showsActions: Bool { isHovered || isSelected }
    private var swatch: ClipboardColorComponents? {
        guard item.semanticType == .color,
              let value = ClipboardColorComponents(text: item.plainTextValue ?? ""), value.alpha == 1 else { return nil }
        return value
    }
    private var ink: Color {
        guard let swatch else { return .primary }
        return swatch.prefersDarkText ? .black : .white
    }
    private var surface: Color {
        if let swatch { return Color(red: swatch.red, green: swatch.green, blue: swatch.blue) }
        return Color(nsColor: .textBackgroundColor).opacity(reduceTransparency ? 1 : 0.82)
    }

    var body: some View {
        Button(action: activate) {
            VStack(alignment: .leading, spacing: 0) {
                if let image {
                    ClipboardImagePreview(image: image, cropsToFill: true)
                        .frame(height: 166)
                        .accessibilityHidden(true)
                } else {
                    textContent.padding(.horizontal, 14).padding(.top, 13).padding(.bottom, 10)
                }
                metadata.padding(.horizontal, 14).padding(.bottom, 12).padding(.top, image == nil ? 0 : 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(surface)
            .clipShape(RoundedRectangle(cornerRadius: 13))
            .overlay {
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(isSelected ? Color.primary : Color(nsColor: .separatorColor),
                                  lineWidth: isSelected || contrast == .increased ? 1.5 : 0.5)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 13)
                    .fill(Color.primary.opacity(isHovered && !isSelected ? 0.035 : 0))
            }
            .contentShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(commands.copyTitle) + Text(": ") + Text(ClipboardItemPresentation.title(for: item)))
        .accessibilityValue(isSelected ? String(localized: "Selected") : "")
        .accessibilityIdentifier("clipboard.item.\(item.id.uuidString)")
        .accessibilityAction(named: Text("Preview"), preview)
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 10) {
                Button(action: preview) { Image(systemName: "eye") }
                    .help("Preview")
                    .accessibilityLabel("Preview")
                    .accessibilityIdentifier("clipboard.preview.\(item.id.uuidString)")
                Menu { ClipboardItemMenuContent(item: item, commands: commands, preview: preview) } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More Actions")
                .accessibilityLabel("More Actions")
            }
            .font(.system(size: 12))
            .buttonStyle(.borderless)
            .foregroundStyle(ink)
            .padding(.trailing, 14)
            .padding(.bottom, 12)
            .opacity(showsActions ? 1 : 0)
            .allowsHitTesting(showsActions)
            .accessibilityHidden(!showsActions)
        }
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isSelected)
        .contextMenu { ClipboardItemMenuContent(item: item, commands: commands, preview: preview) }
    }

    private var textContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(ClipboardItemPresentation.title(for: item))
                .font(ClipboardItemPresentation.usesMonospacedText(item)
                      ? .system(size: swatch == nil ? 13 : 16, weight: swatch == nil ? .regular : .semibold, design: .monospaced)
                      : .system(size: 14, weight: item.kind.filter == .links ? .medium : .regular))
                .foregroundStyle(ink)
                .lineSpacing(3)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if case let .link(value) = item.kind {
                Text(ClipboardItemPresentation.linkDetail(value))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var metadata: some View {
        HStack(spacing: 7) {
            ClipboardSourceIcon(source: item.sourceApp, fallback: ClipboardItemPresentation.symbol(for: item))
            Text(Self.relativeDate.localizedString(for: item.copiedAt, relativeTo: now))
                .help(item.sourceApp?.displayName ?? item.kind.typeLabel)
            if item.isPinned { Image(systemName: "pin.fill").accessibilityLabel("Pinned") }
            if isEdited { Text("Edited") }
            if justCopied {
                Label("Copied", systemImage: "checkmark")
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("clipboard.copyConfirmation")
            }
            Spacer(minLength: 0)
            if let number = entry.shortcutNumber {
                Text("⌥\(number)")
                    .monospaced()
                    .opacity(showsActions ? 0 : 1)
                    .accessibilityHidden(true)
            }
            if showsActions { Color.clear.frame(width: 40, height: 1).accessibilityHidden(true) }
        }
        .font(.system(size: 11))
        .foregroundStyle(swatch == nil ? Color.secondary : ink.opacity(0.85))
        .lineLimit(1)
    }

    private static let relativeDate: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

struct ClipboardColorSwatch: View {
    let components: ClipboardColorComponents
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(red: components.red, green: components.green, blue: components.blue, opacity: components.alpha))
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(contrast == .increased ? Color.primary : Color(nsColor: .separatorColor), lineWidth: 1)
            }
    }
}

struct ClipboardSourceIcon: View {
    let source: ClipboardSourceApp?
    var fallback = "app"
    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: fallback).resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
        .task(id: source?.bundleIdentifier) {
            icon = source?.bundleIdentifier.flatMap { ClipboardAppIconCache.icon(for: $0) }
        }
    }
}

@MainActor
private enum ClipboardAppIconCache {
    static let icons: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()

    static func icon(for bundleIdentifier: String) -> NSImage? {
        if let cached = icons.object(forKey: bundleIdentifier as NSString) { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons.setObject(icon, forKey: bundleIdentifier as NSString)
        return icon
    }
}
