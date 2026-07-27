import AppKit
import Combine
import CryptoKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ClipboardHistoryStore: ObservableObject {
    private struct StoredState: Codable {
        var schemaVersion: Int?
        var items: [ClipboardItem]

        init(schemaVersion: Int? = 2, items: [ClipboardItem]) {
            self.schemaVersion = schemaVersion
            self.items = items
        }
    }

    private let fileManager: FileManager
    private let rootURL: URL
    private let assetsURL: URL
    private let indexURL: URL
    private let cryptor: ClipboardHistoryCryptor
    private let imageCache = NSCache<NSString, NSImage>()
    private var isStorageAvailable: Bool
    private var hasLoadedStoredHistory: Bool

    @Published private(set) var items: [ClipboardItem]
    @Published private(set) var recoveryMessage: String?

    init(
        fileManager: FileManager = .default,
        baseURL: URL? = nil,
        keyProvider: any ClipboardEncryptionKeyProviding = SystemClipboardEncryptionKeyProvider(),
        loadStoredHistory: Bool = true
    ) {
        self.fileManager = fileManager
        cryptor = ClipboardHistoryCryptor(keyProvider: keyProvider)

        let resolvedRootURL = baseURL ?? Self.defaultHistoryURL(fileManager: fileManager)
        rootURL = resolvedRootURL
        assetsURL = resolvedRootURL.appendingPathComponent("assets", isDirectory: true)
        indexURL = resolvedRootURL.appendingPathComponent("clipboard-history.json")

        recoveryMessage = nil
        isStorageAvailable = false
        hasLoadedStoredHistory = false
        items = []

        if loadStoredHistory {
            activateStorage()
        }
    }

    func activateStorage() {
        guard !hasLoadedStoredHistory else {
            return
        }

        hasLoadedStoredHistory = true
        isStorageAvailable = true
        recoveryMessage = nil

        guard let storedData = try? Data(contentsOf: indexURL) else {
            return
        }

        do {
            let decrypted = try cryptor.decryptIfNeeded(storedData)
            let state = try JSONDecoder().decode(StoredState.self, from: decrypted.data)
            items = state.items.sorted(by: Self.timelineSort)
            migrateAssetsToEncryption()
            if !decrypted.wasEncrypted {
                persist()
            }
        } catch {
            items = []
            if error is ClipboardEncryptionError {
                isStorageAvailable = false
                recoveryMessage = "Encrypted Clipboard History is temporarily unavailable because its Keychain key could not be opened. Existing history was left untouched."
            } else {
                recoveryMessage = "Clipboard History found a damaged index and started a fresh history. The damaged file was preserved for recovery."
                let recoveryURL = rootURL.appendingPathComponent("clipboard-history-corrupt-\(UUID().uuidString).data")
                try? fileManager.copyItem(at: indexURL, to: recoveryURL)
            }
        }
    }

    func deactivateStorage() {
        items = []
        imageCache.removeAllObjects()
        recoveryMessage = nil
        isStorageAvailable = false
        hasLoadedStoredHistory = false
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
        copiedAt: Date = Date(),
        pasteboardItems: [PasteboardItemSnapshot] = []
    ) {
        guard isStorageAvailable else { return }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return
        }

        let isLink = URL(string: trimmedText).map { ["http", "https", "mailto"].contains($0.scheme?.localizedLowercase ?? "") } ?? false
        if isLink {
            recordLink(
                trimmedText,
                sourceApp: sourceApp,
                preferences: preferences,
                copiedAt: copiedAt,
                pasteboardItems: pasteboardItems
            )
            return
        }

        let payloadByteSize = Self.payloadByteSize(pasteboardItems)
        guard Int64(text.utf8.count) + payloadByteSize <= preferences.sanitized().maxItemSizeBytes else { return }

        let kind: ClipboardItemKind = .text(text)
        let preview = Self.previewText(for: text)
        let payloadResult = try? storedPayload(from: pasteboardItems)
        let byteSize = Int64(text.data(using: .utf8)?.count ?? 0) + (payloadResult?.byteSize ?? 0)
        var item = ClipboardItem(
            id: UUID(),
            kind: kind,
            previewText: preview,
            searchableText: text,
            sourceApp: sourceApp,
            copiedAt: copiedAt,
            isPinned: false,
            contentHash: Self.contentHash(
                prefix: kind.typeLabel,
                data: Data(text.utf8),
                pasteboardItems: pasteboardItems
            ),
            byteSize: byteSize,
            storedPayload: payloadResult?.payload,
            semanticType: Self.semanticType(for: text)
        )

        item.normalizedSearchText = Self.normalizedSearchText(for: item)

        upsert(item, preferences: preferences)
    }

    func recordLink(
        _ urlString: String,
        title: String? = nil,
        searchableText: String? = nil,
        sourceApp: ClipboardSourceApp?,
        preferences: ClipboardPreferences,
        copiedAt: Date = Date(),
        pasteboardItems: [PasteboardItemSnapshot] = []
    ) {
        guard isStorageAvailable else { return }
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            return
        }

        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = normalizedTitle?.isEmpty == false ? normalizedTitle! : trimmedURL
        let resolvedSearchableText = searchableText ?? [preview, trimmedURL]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let payloadByteSize = Self.payloadByteSize(pasteboardItems)
        guard Int64(resolvedSearchableText.utf8.count) + payloadByteSize <= preferences.sanitized().maxItemSizeBytes else { return }
        let payloadResult = try? storedPayload(from: pasteboardItems)
        let byteSize = Int64(resolvedSearchableText.data(using: .utf8)?.count ?? 0) + (payloadResult?.byteSize ?? 0)
        let kind: ClipboardItemKind = .link(trimmedURL)
        var item = ClipboardItem(
            id: UUID(),
            kind: kind,
            previewText: Self.previewText(for: preview),
            searchableText: resolvedSearchableText,
            sourceApp: sourceApp,
            copiedAt: copiedAt,
            isPinned: false,
            contentHash: Self.contentHash(
                prefix: kind.typeLabel,
                data: Data(trimmedURL.utf8),
                pasteboardItems: pasteboardItems
            ),
            byteSize: byteSize,
            storedPayload: payloadResult?.payload
        )

        item.normalizedSearchText = Self.normalizedSearchText(for: item)

        upsert(item, preferences: preferences)
    }

    func recordFileURLs(
        _ urls: [URL],
        sourceApp: ClipboardSourceApp?,
        preferences: ClipboardPreferences,
        copiedAt: Date = Date(),
        pasteboardItems: [PasteboardItemSnapshot] = []
    ) {
        guard isStorageAvailable else { return }
        let paths = urls.filter(\.isFileURL).map(\.path).filter { !$0.isEmpty }
        guard !paths.isEmpty else {
            return
        }

        let preview = paths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
        let searchableText = paths.joined(separator: " ")
        guard Int64(searchableText.utf8.count) + Self.payloadByteSize(pasteboardItems) <= preferences.sanitized().maxItemSizeBytes else { return }
        let payloadResult = try? storedPayload(from: pasteboardItems)
        let payloadSize = payloadResult?.byteSize ?? 0
        var item = ClipboardItem(
            id: UUID(),
            kind: .fileURLs(paths),
            previewText: preview,
            searchableText: searchableText,
            sourceApp: sourceApp,
            copiedAt: copiedAt,
            isPinned: false,
            contentHash: Self.contentHash(
                prefix: "Files",
                data: Data(searchableText.utf8),
                pasteboardItems: pasteboardItems
            ),
            byteSize: Int64(searchableText.data(using: .utf8)?.count ?? 0) + payloadSize,
            storedPayload: payloadResult?.payload
        )

        item.normalizedSearchText = Self.normalizedSearchText(for: item)

        upsert(item, preferences: preferences)
    }

    func recordImageData(
        _ data: Data,
        sourceApp: ClipboardSourceApp?,
        preferences: ClipboardPreferences,
        copiedAt: Date = Date(),
        title: String = "Image",
        searchableText: String? = nil,
        pasteboardItems: [PasteboardItemSnapshot] = []
    ) {
        guard isStorageAvailable else { return }
        guard Int64(data.count) + Self.payloadByteSize(pasteboardItems, excludingMatching: data) <= preferences.sanitized().maxItemSizeBytes else { return }
        let hash = Self.contentHash(prefix: "Image", data: data, pasteboardItems: pasteboardItems)
        let assetName = "\(UUID().uuidString).png"
        let previewText = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Image" : title
        let resolvedSearchableText = searchableText ?? previewText

        do {
            try ensureDirectories()
            try writeEncryptedAsset(data, named: assetName)
            let payloadResult = try storedPayload(
                from: pasteboardItems,
                reusingAssetName: assetName,
                forData: data
            )
            var item = ClipboardItem(
                id: UUID(),
                kind: .image(assetName: assetName),
                previewText: previewText,
                searchableText: resolvedSearchableText,
                sourceApp: sourceApp,
                copiedAt: copiedAt,
                isPinned: false,
                contentHash: hash,
                byteSize: Int64(data.count) + payloadResult.byteSize,
                storedPayload: payloadResult.payload
            )
            item.normalizedSearchText = Self.normalizedSearchText(for: item)
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
        guard isStorageAvailable else { return }
        guard Int64(pngData.count) <= preferences.sanitized().maxItemSizeBytes else { return }
        let hash = Self.contentHash(prefix: "Snip", data: pngData)
        let assetName = "\(UUID().uuidString).png"

        do {
            try ensureDirectories()
            try writeEncryptedAsset(pngData, named: assetName)
            var item = ClipboardItem(
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
            item.normalizedSearchText = Self.normalizedSearchText(for: item)
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
        let cacheKey = item.id.uuidString as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached
        }
        guard let assetURL = assetURL(for: item) else {
            return nil
        }

        guard let storedData = try? Data(contentsOf: assetURL),
              let decrypted = try? cryptor.decryptIfNeeded(storedData).data else {
            return nil
        }
        guard let image = NSImage(data: decrypted) else { return nil }
        let maxDimension: CGFloat = 512
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        let thumbnailSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let thumbnail = NSImage(size: thumbnailSize)
        thumbnail.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: thumbnailSize))
        thumbnail.unlockFocus()
        imageCache.setObject(thumbnail, forKey: cacheKey)
        return thumbnail
    }

    func dataForPasteboard(for item: ClipboardItem) -> Data? {
        guard let assetURL = assetURL(for: item) else {
            return nil
        }

        guard let storedData = try? Data(contentsOf: assetURL) else { return nil }
        return try? cryptor.decryptIfNeeded(storedData).data
    }

    func pasteboardItemSnapshots(for item: ClipboardItem) -> [PasteboardItemSnapshot]? {
        guard let payload = item.storedPayload else { return nil }
        let snapshots = payload.items.compactMap { storedItem -> PasteboardItemSnapshot? in
            let representations = storedItem.representations.compactMap { representation -> PasteboardRepresentationSnapshot? in
                let data: Data?
                switch representation.value {
                case let .inlineData(inlineData):
                    data = inlineData
                case let .assetName(assetName):
                    let url = assetsURL.appendingPathComponent(assetName)
                    guard let storedData = try? Data(contentsOf: url) else { return nil }
                    data = try? cryptor.decryptIfNeeded(storedData).data
                }
                guard let data, !data.isEmpty else { return nil }
                return PasteboardRepresentationSnapshot(typeIdentifier: representation.typeIdentifier, data: data)
            }
            return representations.isEmpty ? nil : PasteboardItemSnapshot(representations: representations)
        }
        return snapshots.count == payload.items.count ? snapshots : nil
    }

    func togglePinned(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else {
            return
        }

        items[index].isPinned.toggle()
        items.sort(by: Self.timelineSort)
        persist()
    }

    func toggleCollection(_ collectionName: String, for item: ClipboardItem) {
        let normalizedName = collectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty,
              normalizedName.count <= 60,
              let index = items.firstIndex(where: { $0.id == item.id }) else {
            return
        }
        if let collectionIndex = items[index].collectionNames.firstIndex(where: {
            $0.localizedCaseInsensitiveCompare(normalizedName) == .orderedSame
        }) {
            items[index].collectionNames.remove(at: collectionIndex)
        } else {
            items[index].collectionNames.append(normalizedName)
            items[index].collectionNames.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
        items[index].normalizedSearchText = Self.normalizedSearchText(for: items[index])
        persist()
    }

    func delete(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else {
            return
        }

        deleteAssets(for: items[index])
        imageCache.removeObject(forKey: item.id.uuidString as NSString)
        items.remove(at: index)
        persist()
    }

    func clearUnpinned() {
        let removedItems = items.filter { !$0.isPinned }
        removedItems.forEach(deleteAssets)
        removedItems.forEach { imageCache.removeObject(forKey: $0.id.uuidString as NSString) }
        items.removeAll { !$0.isPinned }
        persist()
    }

    func clearAll() {
        items.forEach(deleteAssets)
        imageCache.removeAllObjects()
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
            if items[existingIndex].copiedAt > item.copiedAt {
                deleteAssets(for: item)
                return
            }
            insertedItem.id = items[existingIndex].id
            insertedItem.isPinned = items[existingIndex].isPinned
            insertedItem.collectionNames = items[existingIndex].collectionNames
            deleteAssets(for: items[existingIndex])
            imageCache.removeObject(forKey: items[existingIndex].id.uuidString as NSString)
            items.remove(at: existingIndex)
        }

        items.insert(insertedItem, at: 0)
        items.sort(by: Self.timelineSort)
        pruneItems(using: preferences.sanitized())
        persist()
    }

    private func pruneItems(using preferences: ClipboardPreferences) {
        if preferences.retentionDays > 0,
           let cutoff = Calendar.current.date(byAdding: .day, value: -preferences.retentionDays, to: Date()) {
            let expiredItems = items.filter { !$0.isPinned && $0.copiedAt < cutoff }
            expiredItems.forEach(deleteAssets)
            expiredItems.forEach { imageCache.removeObject(forKey: $0.id.uuidString as NSString) }
            items.removeAll { !$0.isPinned && $0.copiedAt < cutoff }
        }

        while items.count > preferences.maxItemCount,
              let removalIndex = items.lastIndex(where: { !$0.isPinned }) {
            deleteAssets(for: items[removalIndex])
            imageCache.removeObject(forKey: items[removalIndex].id.uuidString as NSString)
            items.remove(at: removalIndex)
        }

        var totalSize = items.reduce(Int64(0)) { $0 + max($1.byteSize, 0) }
        while totalSize > preferences.maxStorageBytes,
              let removalIndex = items.lastIndex(where: { !$0.isPinned }) {
            totalSize = max(0, totalSize - max(items[removalIndex].byteSize, 0))
            deleteAssets(for: items[removalIndex])
            imageCache.removeObject(forKey: items[removalIndex].id.uuidString as NSString)
            items.remove(at: removalIndex)
        }
    }

    private func persist() {
        guard isStorageAvailable else { return }
        do {
            try ensureDirectories()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(StoredState(items: items))
            let encryptedData = try cryptor.encrypt(data)
            try writeDataWithBestAvailableFileProtection(
                encryptedData,
                to: indexURL
            )
        } catch {
            // Clipboard history should never block capture or copy workflows.
        }
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        var protectedRootURL = rootURL
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? protectedRootURL.setResourceValues(resourceValues)
        let spotlightExclusionURL = rootURL.appendingPathComponent(".metadata_never_index")
        if !fileManager.fileExists(atPath: spotlightExclusionURL.path) {
            try writeDataWithBestAvailableFileProtection(
                Data(),
                to: spotlightExclusionURL
            )
        }
    }

    private func deleteAssets(for item: ClipboardItem) {
        var assetNames = Set<String>()
        if let assetURL = assetURL(for: item) {
            assetNames.insert(assetURL.lastPathComponent)
        }
        item.storedPayload?.items.forEach { storedItem in
            storedItem.representations.forEach { representation in
                if case let .assetName(assetName) = representation.value {
                    assetNames.insert(assetName)
                }
            }
        }
        assetNames.forEach { assetName in
            try? fileManager.removeItem(at: assetsURL.appendingPathComponent(assetName))
        }
    }

    private func writeEncryptedAsset(_ data: Data, named assetName: String) throws {
        let encryptedData = try cryptor.encrypt(data)
        try writeDataWithBestAvailableFileProtection(
            encryptedData,
            to: assetsURL.appendingPathComponent(assetName)
        )
    }

    private func writeDataWithBestAvailableFileProtection(
        _ data: Data,
        to url: URL
    ) throws {
        do {
            try data.write(
                to: url,
                options: [.atomic, .completeFileProtection]
            )
        } catch {
            // File protection can be unavailable to unsigned hosts or on some
            // macOS volumes. Clipboard payloads remain AES-GCM encrypted.
            try data.write(to: url, options: .atomic)
        }
    }

    private func migrateAssetsToEncryption() {
        let names = Set(items.flatMap { item -> [String] in
            var names: [String] = []
            if let assetURL = assetURL(for: item) {
                names.append(assetURL.lastPathComponent)
            }
            item.storedPayload?.items.forEach { storedItem in
                storedItem.representations.forEach { representation in
                    if case let .assetName(assetName) = representation.value {
                        names.append(assetName)
                    }
                }
            }
            return names
        })

        for name in names {
            let url = assetsURL.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  !data.starts(with: ClipboardHistoryCryptor.envelopeMagic),
                  let encrypted = try? cryptor.encrypt(data) else {
                continue
            }
            try? writeDataWithBestAvailableFileProtection(encrypted, to: url)
        }
    }

    private func storedPayload(
        from snapshots: [PasteboardItemSnapshot],
        reusingAssetName: String? = nil,
        forData reusedData: Data? = nil
    ) throws -> (payload: ClipboardStoredPayload?, byteSize: Int64) {
        guard !snapshots.isEmpty else { return (nil, 0) }
        var writtenAssetNames: [String] = []
        var storedByteSize: Int64 = 0

        do {
            let items = try snapshots.map { snapshot in
                let representations = try snapshot.representations.map { representation in
                    let value: ClipboardStoredRepresentationValue
                    if let reusingAssetName, let reusedData, representation.data == reusedData {
                        value = .assetName(reusingAssetName)
                    } else if representation.data.count <= 64 * 1_024 {
                        value = .inlineData(representation.data)
                        storedByteSize += Int64(representation.data.count)
                    } else {
                        let assetName = "\(UUID().uuidString).clipdata"
                        try writeEncryptedAsset(representation.data, named: assetName)
                        writtenAssetNames.append(assetName)
                        storedByteSize += Int64(representation.data.count)
                        value = .assetName(assetName)
                    }
                    return ClipboardStoredRepresentation(
                        typeIdentifier: representation.typeIdentifier,
                        value: value
                    )
                }
                return ClipboardStoredPayloadItem(representations: representations)
            }
            return (ClipboardStoredPayload(items: items), storedByteSize)
        } catch {
            writtenAssetNames.forEach { try? fileManager.removeItem(at: assetsURL.appendingPathComponent($0)) }
            throw error
        }
    }

    private static func payloadByteSize(
        _ snapshots: [PasteboardItemSnapshot],
        excludingMatching excludedData: Data? = nil
    ) -> Int64 {
        snapshots.reduce(0) { partial, item in
            partial + item.representations.reduce(0) { subtotal, representation in
                subtotal + (representation.data == excludedData ? 0 : Int64(representation.data.count))
            }
        }
    }

    private static func normalizedSearchText(for item: ClipboardItem) -> String {
        [
            item.title,
            item.previewText,
            item.searchableText,
            item.sourceApp?.name,
            item.sourceApp?.bundleIdentifier,
            item.kind.typeLabel,
            item.semanticType?.label,
            item.collectionNames.joined(separator: " ")
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .localizedLowercase
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

    private static func contentHash(
        prefix: String,
        data: Data,
        pasteboardItems: [PasteboardItemSnapshot]
    ) -> String {
        guard !pasteboardItems.isEmpty else { return contentHash(prefix: prefix, data: data) }
        var hasher = SHA256()
        hasher.update(data: Data(prefix.utf8))
        hasher.update(data: data)
        for item in pasteboardItems {
            hasher.update(data: Data([0]))
            for representation in item.representations.sorted(by: { $0.typeIdentifier < $1.typeIdentifier }) {
                hasher.update(data: Data(representation.typeIdentifier.utf8))
                hasher.update(data: representation.data)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func semanticType(for text: String) -> ClipboardSemanticType? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) ||
            (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")),
           let data = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return .json
        }

        let colorPattern = #"^#(?:[0-9A-Fa-f]{3,4}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$"#
        if trimmed.range(of: colorPattern, options: .regularExpression) != nil {
            return .color
        }

        let emailPattern = #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#
        if trimmed.range(of: emailPattern, options: .regularExpression) != nil {
            return .email
        }

        let phonePattern = #"^\+?[0-9][0-9 ()\-.]{6,}[0-9]$"#
        if trimmed.range(of: phonePattern, options: .regularExpression) != nil {
            return .phoneNumber
        }

        let codeSignals = ["func ", "class ", "struct ", "const ", "let ", "var ", "import ", "=>", "</", "#!/"]
        if trimmed.contains("\n"), codeSignals.contains(where: trimmed.contains) {
            return .code
        }
        return nil
    }
}
