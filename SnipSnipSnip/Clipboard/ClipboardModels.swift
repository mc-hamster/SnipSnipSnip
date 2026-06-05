import Foundation

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

    func matchesSearchQuery(_ query: String) -> Bool {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return true
        }

        let haystack = [
            title,
            previewText,
            searchableText,
            sourceApp?.name,
            sourceApp?.bundleIdentifier,
            kind.typeLabel
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

        let candidates = [
            sourceApp?.name,
            sourceApp?.bundleIdentifier
        ]
        .compactMap { $0?.localizedLowercase }

        return candidates.contains { $0 == normalizedMatch || $0.contains(normalizedMatch) }
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
        ClipboardIgnoredApp(name: "NordPass", match: "com.nordsec.NordPass"),
        ClipboardIgnoredApp(name: "Proton Pass", match: "me.proton.pass")
    ]

    static let `default` = ClipboardPreferences(
        isEnabled: true,
        maxItemCount: 100,
        maxStorageMB: 256,
        ignoredApps: defaultIgnoredApps
    )

    var isEnabled: Bool
    var maxItemCount: Int
    var maxStorageMB: Int
    var ignoredApps: [ClipboardIgnoredApp]

    var maxStorageBytes: Int64 {
        Int64(maxStorageMB) * 1_024 * 1_024
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
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        )
    }
}
