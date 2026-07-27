import Foundation

nonisolated enum ClipboardSemanticType: String, Codable, Equatable, Sendable {
    case code, json, color, email, phoneNumber

    var label: String {
        switch self {
        case .code: "Code"
        case .json: "JSON"
        case .color: "Color"
        case .email: "Email"
        case .phoneNumber: "Phone"
        }
    }
}

nonisolated enum ClipboardStoredRepresentationValue: Codable, Equatable, Sendable {
    case inlineData(Data)
    case assetName(String)

    private enum CodingKeys: String, CodingKey { case type, data, assetName }
    private enum ValueType: String, Codable { case inlineData, assetName }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ValueType.self, forKey: .type) {
        case .inlineData:
            self = .inlineData(try container.decode(Data.self, forKey: .data))
        case .assetName:
            self = .assetName(try container.decode(String.self, forKey: .assetName))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .inlineData(data):
            try container.encode(ValueType.inlineData, forKey: .type)
            try container.encode(data, forKey: .data)
        case let .assetName(assetName):
            try container.encode(ValueType.assetName, forKey: .type)
            try container.encode(assetName, forKey: .assetName)
        }
    }
}

nonisolated struct ClipboardStoredRepresentation: Codable, Equatable, Sendable {
    var typeIdentifier: String
    var value: ClipboardStoredRepresentationValue
}

nonisolated struct ClipboardStoredPayloadItem: Codable, Equatable, Sendable {
    var representations: [ClipboardStoredRepresentation]
}

nonisolated struct ClipboardStoredPayload: Codable, Equatable, Sendable {
    var items: [ClipboardStoredPayloadItem]
}

nonisolated enum ClipboardItemKind: Codable, Equatable, Sendable {
    case text(String)
    case link(String)
    case image(assetName: String)
    case fileURLs([String])
    case snip(assetName: String, sessionID: UUID?, title: String)

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case assetName
        case fileURLs
        case sessionID
        case title
    }

    enum KindType: String, Codable {
        case text
        case link
        case image
        case fileURLs
        case snip
    }

    var typeLabel: String {
        switch self {
        case .text:
            return "Text"
        case .link:
            return "Link"
        case .image:
            return "Image"
        case .fileURLs:
            return "Files"
        case .snip:
            return "Snip"
        }
    }

    var filter: ClipboardItemFilter {
        switch self {
        case .text:
            return .text
        case .link:
            return .links
        case .image:
            return .images
        case .fileURLs:
            return .files
        case .snip:
            return .snips
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(KindType.self, forKey: .type)

        switch type {
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .link:
            self = .link(try container.decode(String.self, forKey: .text))
        case .image:
            self = .image(assetName: try container.decode(String.self, forKey: .assetName))
        case .fileURLs:
            self = .fileURLs(try container.decode([String].self, forKey: .fileURLs))
        case .snip:
            self = .snip(
                assetName: try container.decode(String.self, forKey: .assetName),
                sessionID: try container.decodeIfPresent(UUID.self, forKey: .sessionID),
                title: try container.decode(String.self, forKey: .title)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .text(text):
            try container.encode(KindType.text, forKey: .type)
            try container.encode(text, forKey: .text)
        case let .link(text):
            try container.encode(KindType.link, forKey: .type)
            try container.encode(text, forKey: .text)
        case let .image(assetName):
            try container.encode(KindType.image, forKey: .type)
            try container.encode(assetName, forKey: .assetName)
        case let .fileURLs(fileURLs):
            try container.encode(KindType.fileURLs, forKey: .type)
            try container.encode(fileURLs, forKey: .fileURLs)
        case let .snip(assetName, sessionID, title):
            try container.encode(KindType.snip, forKey: .type)
            try container.encode(assetName, forKey: .assetName)
            try container.encodeIfPresent(sessionID, forKey: .sessionID)
            try container.encode(title, forKey: .title)
        }
    }
}

nonisolated struct ClipboardSourceApp: Codable, Equatable, Sendable {
    var name: String?
    var bundleIdentifier: String?

    var displayName: String {
        name ?? bundleIdentifier ?? "Unknown App"
    }
}

nonisolated struct ClipboardItem: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var kind: ClipboardItemKind
    var previewText: String
    var searchableText: String
    var sourceApp: ClipboardSourceApp?
    var copiedAt: Date
    var isPinned: Bool
    var contentHash: String
    var byteSize: Int64
    var storedPayload: ClipboardStoredPayload?
    var normalizedSearchText: String?
    var semanticType: ClipboardSemanticType?
    var collectionNames: [String]

    private enum CodingKeys: String, CodingKey {
        case id, kind, previewText, searchableText, sourceApp, copiedAt, isPinned, contentHash, byteSize
        case storedPayload, normalizedSearchText, semanticType, collectionNames
    }

    init(
        id: UUID,
        kind: ClipboardItemKind,
        previewText: String,
        searchableText: String,
        sourceApp: ClipboardSourceApp?,
        copiedAt: Date,
        isPinned: Bool,
        contentHash: String,
        byteSize: Int64,
        storedPayload: ClipboardStoredPayload? = nil,
        normalizedSearchText: String? = nil,
        semanticType: ClipboardSemanticType? = nil,
        collectionNames: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.previewText = previewText
        self.searchableText = searchableText
        self.sourceApp = sourceApp
        self.copiedAt = copiedAt
        self.isPinned = isPinned
        self.contentHash = contentHash
        self.byteSize = byteSize
        self.storedPayload = storedPayload
        self.normalizedSearchText = normalizedSearchText
        self.semanticType = semanticType
        self.collectionNames = collectionNames
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(ClipboardItemKind.self, forKey: .kind)
        previewText = try container.decode(String.self, forKey: .previewText)
        searchableText = try container.decode(String.self, forKey: .searchableText)
        sourceApp = try container.decodeIfPresent(ClipboardSourceApp.self, forKey: .sourceApp)
        copiedAt = try container.decode(Date.self, forKey: .copiedAt)
        isPinned = try container.decode(Bool.self, forKey: .isPinned)
        contentHash = try container.decode(String.self, forKey: .contentHash)
        byteSize = try container.decode(Int64.self, forKey: .byteSize)
        storedPayload = try container.decodeIfPresent(ClipboardStoredPayload.self, forKey: .storedPayload)
        normalizedSearchText = try container.decodeIfPresent(String.self, forKey: .normalizedSearchText)
        semanticType = try container.decodeIfPresent(ClipboardSemanticType.self, forKey: .semanticType)
        collectionNames = try container.decodeIfPresent([String].self, forKey: .collectionNames) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(previewText, forKey: .previewText)
        try container.encode(searchableText, forKey: .searchableText)
        try container.encodeIfPresent(sourceApp, forKey: .sourceApp)
        try container.encode(copiedAt, forKey: .copiedAt)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encode(contentHash, forKey: .contentHash)
        try container.encode(byteSize, forKey: .byteSize)
        try container.encodeIfPresent(storedPayload, forKey: .storedPayload)
        try container.encodeIfPresent(normalizedSearchText, forKey: .normalizedSearchText)
        try container.encodeIfPresent(semanticType, forKey: .semanticType)
        try container.encode(collectionNames, forKey: .collectionNames)
    }

    var title: String {
        switch kind {
        case .text:
            return previewText.isEmpty ? "Text" : previewText
        case .link:
            return previewText
        case .image:
            return previewText.isEmpty ? "Image" : previewText
        case .fileURLs:
            return previewText
        case let .snip(_, _, title):
            return title
        }
    }

    var plainTextValue: String? {
        switch kind {
        case let .text(text), let .link(text):
            return text
        case .image, .fileURLs, .snip:
            return nil
        }
    }

    var supportsPlainTextSanitization: Bool {
        plainTextValue != nil
    }

    func matchesSearchQuery(_ query: String) -> Bool {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return true
        }

        let haystack = normalizedSearchText ?? [
            title,
            previewText,
            searchableText,
            sourceApp?.name,
            sourceApp?.bundleIdentifier,
            kind.typeLabel,
            semanticType?.label,
            collectionNames.joined(separator: " ")
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .localizedLowercase

        return haystack.contains(normalizedQuery.localizedLowercase)
    }
}

nonisolated enum ClipboardItemFilter: String, CaseIterable, Identifiable, Codable, Sendable {
    case all
    case text
    case links
    case images
    case files
    case snips
    case pinned

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all:
            return "All"
        case .text:
            return "Text"
        case .links:
            return "Links"
        case .images:
            return "Images"
        case .files:
            return "Files"
        case .snips:
            return "Snips"
        case .pinned:
            return "Pinned"
        }
    }
}

nonisolated struct ClipboardIgnoredApp: Identifiable, Codable, Equatable, Sendable {
    var id: String { match.localizedLowercase }
    var name: String
    var match: String

    func matches(_ sourceApp: ClipboardSourceApp?) -> Bool {
        let normalizedMatch = match.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !normalizedMatch.isEmpty else {
            return false
        }

        let normalizedName = sourceApp?.name?.localizedLowercase
        let normalizedBundleIdentifier = sourceApp?.bundleIdentifier?.localizedLowercase
        return normalizedName == normalizedMatch || normalizedBundleIdentifier == normalizedMatch
    }
}

nonisolated struct ClipboardPreferences: Codable, Equatable, Sendable {
    static let defaultIgnoredApps: [ClipboardIgnoredApp] = [
        ClipboardIgnoredApp(name: "Apple Passwords", match: "com.apple.Passwords"),
        ClipboardIgnoredApp(name: "Apple Passwords Menu Bar", match: "com.apple.Passwords.MenuBarExtra"),
        ClipboardIgnoredApp(name: "1Password", match: "com.1password.1password"),
        ClipboardIgnoredApp(name: "1Password 7", match: "com.agilebits.onepassword7"),
        ClipboardIgnoredApp(name: "Bitwarden", match: "com.bitwarden.desktop"),
        ClipboardIgnoredApp(name: "Dashlane", match: "com.dashlane.dashlanephonefinal"),
        ClipboardIgnoredApp(name: "LastPass", match: "com.lastpass.LastPass"),
        ClipboardIgnoredApp(name: "KeePassXC", match: "org.keepassxc.keepassxc"),
        ClipboardIgnoredApp(name: "Keeper Password Manager", match: "com.keepersecurity.passwordmanager"),
        ClipboardIgnoredApp(name: "RoboForm", match: "RoboForm"),
        ClipboardIgnoredApp(name: "Enpass", match: "Enpass"),
        ClipboardIgnoredApp(name: "mSecure", match: "mSecure"),
        ClipboardIgnoredApp(name: "mSecure", match: "com.mseven.mSecure"),
        ClipboardIgnoredApp(name: "NordPass", match: "com.nordsec.NordPass"),
        ClipboardIgnoredApp(name: "Proton Pass", match: "me.proton.pass"),
        ClipboardIgnoredApp(name: "KeeWeb", match: "KeeWeb"),
        ClipboardIgnoredApp(name: "MacPass", match: "MacPass"),
        ClipboardIgnoredApp(name: "Strongbox", match: "Strongbox"),
        ClipboardIgnoredApp(name: "Secrets", match: "Secrets"),
        ClipboardIgnoredApp(name: "Buttercup", match: "Buttercup"),
        ClipboardIgnoredApp(name: "SafeInCloud", match: "SafeInCloud")
    ]

    static let `default` = ClipboardPreferences(
        isEnabled: false,
        maxItemCount: 100,
        maxStorageMB: 256,
        ignoredApps: defaultIgnoredApps,
        retentionDays: 0,
        maxItemSizeMB: 25,
        recordsUncopiedSnips: true
    )

    var isEnabled: Bool
    var maxItemCount: Int
    var maxStorageMB: Int
    var ignoredApps: [ClipboardIgnoredApp]
    var retentionDays: Int
    var maxItemSizeMB: Int
    var recordsUncopiedSnips: Bool

    private enum CodingKeys: String, CodingKey {
        case isEnabled, maxItemCount, maxStorageMB, ignoredApps
        case retentionDays, maxItemSizeMB, recordsUncopiedSnips
    }

    init(
        isEnabled: Bool,
        maxItemCount: Int,
        maxStorageMB: Int,
        ignoredApps: [ClipboardIgnoredApp],
        retentionDays: Int = 0,
        maxItemSizeMB: Int = 25,
        recordsUncopiedSnips: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.maxItemCount = maxItemCount
        self.maxStorageMB = maxStorageMB
        self.ignoredApps = ignoredApps
        self.retentionDays = retentionDays
        self.maxItemSizeMB = maxItemSizeMB
        self.recordsUncopiedSnips = recordsUncopiedSnips
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        maxItemCount = try container.decode(Int.self, forKey: .maxItemCount)
        maxStorageMB = try container.decode(Int.self, forKey: .maxStorageMB)
        ignoredApps = try container.decode([ClipboardIgnoredApp].self, forKey: .ignoredApps)
        retentionDays = try container.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 0
        maxItemSizeMB = try container.decodeIfPresent(Int.self, forKey: .maxItemSizeMB) ?? 25
        recordsUncopiedSnips = try container.decodeIfPresent(Bool.self, forKey: .recordsUncopiedSnips) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(maxItemCount, forKey: .maxItemCount)
        try container.encode(maxStorageMB, forKey: .maxStorageMB)
        try container.encode(ignoredApps, forKey: .ignoredApps)
        try container.encode(retentionDays, forKey: .retentionDays)
        try container.encode(maxItemSizeMB, forKey: .maxItemSizeMB)
        try container.encode(recordsUncopiedSnips, forKey: .recordsUncopiedSnips)
    }

    var maxStorageBytes: Int64 {
        Int64(maxStorageMB) * 1_024 * 1_024
    }

    var maxItemSizeBytes: Int64 {
        Int64(maxItemSizeMB) * 1_024 * 1_024
    }

    func ignores(_ sourceApp: ClipboardSourceApp?) -> Bool {
        ignoredApps.contains { $0.matches(sourceApp) }
    }

    func sanitized() -> ClipboardPreferences {
        ClipboardPreferences(
            isEnabled: isEnabled,
            maxItemCount: min(max(maxItemCount, 10), 1_000),
            maxStorageMB: min(max(maxStorageMB, 25), 5_120),
            ignoredApps: Array(Dictionary(grouping: ignoredApps, by: \.id).compactMap { $0.value.first }
                .sorted {
                    let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
                    if nameOrder == .orderedSame {
                        return $0.id < $1.id
                    }
                    return nameOrder == .orderedAscending
                }),
            retentionDays: [0, 1, 7, 30, 90].contains(retentionDays) ? retentionDays : 0,
            maxItemSizeMB: min(max(maxItemSizeMB, 1), 250),
            recordsUncopiedSnips: recordsUncopiedSnips
        )
    }
}
