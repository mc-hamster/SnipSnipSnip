import AppKit
import Combine
import CryptoKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ClipboardHistoryStore: ObservableObject {
    private struct StoredState: Codable {
        var items: [ClipboardItem]
    }

    private let fileManager: FileManager
    private let rootURL: URL
    private let assetsURL: URL
    private let indexURL: URL

    @Published private(set) var items: [ClipboardItem]

    init(fileManager: FileManager = .default, baseURL: URL? = nil) {
        self.fileManager = fileManager

        let resolvedRootURL = baseURL ?? Self.defaultHistoryURL(fileManager: fileManager)
        rootURL = resolvedRootURL
        assetsURL = resolvedRootURL.appendingPathComponent("assets", isDirectory: true)
        indexURL = resolvedRootURL.appendingPathComponent("clipboard-history.json")

        if let data = try? Data(contentsOf: indexURL),
           let state = try? JSONDecoder().decode(StoredState.self, from: data) {
            items = state.items.sorted(by: Self.timelineSort)
        } else {
            items = []
        }
    }

    static func defaultHistoryURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("SnipSnipSnip", isDirectory: true)
            .appendingPathComponent("Clipboard", isDirectory: true)
    }

    func recordText(
        _ text: String,
        sourceApp: ClipboardSourceApp?,
        preferences: ClipboardPreferences,
        copiedAt: Date = Date()
    ) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return
        }

        let isLink = URL(string: trimmedText).map { ["http", "https", "mailto"].contains($0.scheme?.localizedLowercase ?? "") } ?? false
        if isLink {
            recordLink(trimmedText, sourceApp: sourceApp, preferences: preferences, copiedAt: copiedAt)
            return
        }

        let kind: ClipboardItemKind = .text(text)
        let preview = Self.previewText(for: text)
        let byteSize = Int64(text.data(using: .utf8)?.count ?? 0)
        let item = ClipboardItem(
            id: UUID(),
            kind: kind,
            previewText: preview,
            searchableText: text,
            sourceApp: sourceApp,
            copiedAt: copiedAt,
            isPinned: false,
            contentHash: Self.contentHash(prefix: kind.typeLabel, data: Data(text.utf8)),
            byteSize: byteSize
        )

        upsert(item, preferences: preferences)
    }

    func recordLink(
        _ urlString: String,
        title: String? = nil,
        searchableText: String? = nil,
        sourceApp: ClipboardSourceApp?,
        preferences: ClipboardPreferences,
        copiedAt: Date = Date()
    ) {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            return
        }

        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = normalizedTitle?.isEmpty == false ? normalizedTitle! : trimmedURL
        let resolvedSearchableText = searchableText ?? [preview, trimmedURL]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let byteSize = Int64(resolvedSearchableText.data(using: .utf8)?.count ?? 0)
        let kind: ClipboardItemKind = .link(trimmedURL)
        let item = ClipboardItem(
            id: UUID(),
            kind: kind,
            previewText: Self.previewText(for: preview),
            searchableText: resolvedSearchableText,
            sourceApp: sourceApp,
            copiedAt: copiedAt,
            isPinned: false,
            contentHash: Self.contentHash(prefix: kind.typeLabel, data: Data(trimmedURL.utf8)),
            byteSize: byteSize
        )

        upsert(item, preferences: preferences)
    }

    func recordFileURLs(
        _ urls: [URL],
        sourceApp: ClipboardSourceApp?,
        preferences: ClipboardPreferences,
        copiedAt: Date = Date()
    ) {
        let paths = urls.filter(\.isFileURL).map(\.path).filter { !$0.isEmpty }
        guard !paths.isEmpty else {
            return
        }

        let preview = paths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
        let searchableText = paths.joined(separator: " ")
        let item = ClipboardItem(
            id: UUID(),
            kind: .fileURLs(paths),
            previewText: preview,
            searchableText: searchableText,
            sourceApp: sourceApp,
            copiedAt: copiedAt,
            isPinned: false,
            contentHash: Self.contentHash(prefix: "Files", data: Data(searchableText.utf8)),
            byteSize: Int64(searchableText.data(using: .utf8)?.count ?? 0)
        )

        upsert(item, preferences: preferences)
    }

    func recordImageData(
        _ data: Data,
        sourceApp: ClipboardSourceApp?,
        preferences: ClipboardPreferences,
        copiedAt: Date = Date(),
        title: String = "Image",
        searchableText: String? = nil
    ) {
        let hash = Self.contentHash(prefix: "Image", data: data)
        let assetName = "\(UUID().uuidString).png"
        let previewText = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Image" : title
        let resolvedSearchableText = searchableText ?? previewText

        do {
            try ensureDirectories()
            try data.write(to: assetsURL.appendingPathComponent(assetName), options: .atomic)
            let item = ClipboardItem(
                id: UUID(),
                kind: .image(assetName: assetName),
                previewText: previewText,
                searchableText: resolvedSearchableText,
                sourceApp: sourceApp,
                copiedAt: copiedAt,
                isPinned: false,
                contentHash: hash,
                byteSize: Int64(data.count)
            )
            upsert(item, preferences: preferences)
        } catch {
            try? fileManager.removeItem(at: assetsURL.appendingPathComponent(assetName))
        }
    }

    func recordSnip(
        pngData: Data,
        title: String,
        searchableText: String,
        sessionID: UUID?,
        preferences: ClipboardPreferences,
        copiedAt: Date = Date()
    ) {
        let hash = Self.contentHash(prefix: "Snip", data: pngData)
        let assetName = "\(UUID().uuidString).png"

        do {
            try ensureDirectories()
            try pngData.write(to: assetsURL.appendingPathComponent(assetName), options: .atomic)
            let item = ClipboardItem(
                id: UUID(),
                kind: .snip(assetName: assetName, sessionID: sessionID, title: title),
                previewText: title,
                searchableText: searchableText,
                sourceApp: ClipboardSourceApp(name: AppBranding.displayName, bundleIdentifier: Bundle.main.bundleIdentifier),
                copiedAt: copiedAt,
                isPinned: false,
                contentHash: hash,
                byteSize: Int64(pngData.count)
            )
            upsert(item, preferences: preferences)
        } catch {
            try? fileManager.removeItem(at: assetsURL.appendingPathComponent(assetName))
        }
    }

    func assetURL(for item: ClipboardItem) -> URL? {
        switch item.kind {
        case let .image(assetName), let .snip(assetName, _, _):
            return assetsURL.appendingPathComponent(assetName)
        case .text, .link, .fileURLs:
            return nil
        }
    }

    func image(for item: ClipboardItem) -> NSImage? {
        guard let assetURL = assetURL(for: item) else {
            return nil
        }

        return NSImage(contentsOf: assetURL)
    }

    func dataForPasteboard(for item: ClipboardItem) -> Data? {
        guard let assetURL = assetURL(for: item) else {
            return nil
        }

        return try? Data(contentsOf: assetURL)
    }

    func togglePinned(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else {
            return
        }

        items[index].isPinned.toggle()
        items.sort(by: Self.timelineSort)
        persist()
    }

    func delete(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else {
            return
        }

        deleteAssets(for: items[index])
        items.remove(at: index)
        persist()
    }

    func clearUnpinned() {
        let removedItems = items.filter { !$0.isPinned }
        removedItems.forEach(deleteAssets)
        items.removeAll { !$0.isPinned }
        persist()
    }

    func clearAll() {
        items.forEach(deleteAssets)
        items.removeAll()
        persist()
    }

    func prune(using preferences: ClipboardPreferences) {
        pruneItems(using: preferences.sanitized())
        persist()
    }

    private func upsert(_ item: ClipboardItem, preferences: ClipboardPreferences) {
        var insertedItem = item

        if let existingIndex = items.firstIndex(where: { $0.contentHash == item.contentHash }) {
            insertedItem.id = items[existingIndex].id
            insertedItem.isPinned = items[existingIndex].isPinned
            deleteAssets(for: items[existingIndex])
            items.remove(at: existingIndex)
        }

        items.insert(insertedItem, at: 0)
        items.sort(by: Self.timelineSort)
        pruneItems(using: preferences.sanitized())
        persist()
    }

    private func pruneItems(using preferences: ClipboardPreferences) {
        while items.count > preferences.maxItemCount,
              let removalIndex = items.lastIndex(where: { !$0.isPinned }) {
            deleteAssets(for: items[removalIndex])
            items.remove(at: removalIndex)
        }

        var totalSize = items.reduce(Int64(0)) { $0 + max($1.byteSize, 0) }
        while totalSize > preferences.maxStorageBytes,
              let removalIndex = items.lastIndex(where: { !$0.isPinned }) {
            totalSize = max(0, totalSize - max(items[removalIndex].byteSize, 0))
            deleteAssets(for: items[removalIndex])
            items.remove(at: removalIndex)
        }
    }

    private func persist() {
        do {
            try ensureDirectories()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(StoredState(items: items))
            try data.write(to: indexURL, options: .atomic)
        } catch {
            // Clipboard history should never block capture or copy workflows.
        }
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(at: assetsURL, withIntermediateDirectories: true)
    }

    private func deleteAssets(for item: ClipboardItem) {
        guard let assetURL = assetURL(for: item) else {
            return
        }

        try? fileManager.removeItem(at: assetURL)
    }

    private static func timelineSort(_ lhs: ClipboardItem, _ rhs: ClipboardItem) -> Bool {
        if lhs.isPinned != rhs.isPinned {
            return lhs.isPinned && !rhs.isPinned
        }

        return lhs.copiedAt > rhs.copiedAt
    }

    static func previewText(for text: String) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard collapsed.count > 160 else {
            return collapsed
        }

        return String(collapsed.prefix(157)) + "..."
    }

    static func contentHash(prefix: String, data: Data) -> String {
        let digest = SHA256.hash(data: Data(prefix.utf8) + data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
