import Foundation

/// Filtering and sectioning share one ordered result, including the numbered shortcuts.
struct ClipboardHistoryQuery {
    var text = ""
    var kind: ClipboardItemFilter = .all
    var time: ClipboardTimeFilter = .all
    var source: String?
    var collection: String?

    var secondaryFilterCount: Int {
        (time == .all ? 0 : 1) + (source == nil ? 0 : 1) + (collection == nil ? 0 : 1)
    }

    var isFiltering: Bool { !text.isEmpty || kind != .all || secondaryFilterCount > 0 }

    func matches(_ item: ClipboardItem, now: Date, calendar: Calendar) -> Bool {
        if kind == .pinned {
            guard item.isPinned else { return false }
        } else if kind != .all, item.kind.filter != kind {
            return false
        }
        if let source, item.sourceApp?.bundleIdentifier != source, item.sourceApp?.displayName != source {
            return false
        }
        if let collection, !item.collectionNames.contains(where: {
            $0.localizedCaseInsensitiveCompare(collection) == .orderedSame
        }) { return false }
        return time.includes(item.copiedAt, now: now, calendar: calendar) && item.matchesSearchQuery(text)
    }
}

enum ClipboardTimeFilter: String, CaseIterable, Identifiable {
    case all, today, sevenDays, thirtyDays

    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: String(localized: "Any Time")
        case .today: String(localized: "Today")
        case .sevenDays: String(localized: "Last 7 Days")
        case .thirtyDays: String(localized: "Last 30 Days")
        }
    }

    func includes(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch self {
        case .all: true
        case .today: calendar.isDate(date, inSameDayAs: now)
        case .sevenDays: date >= (calendar.date(byAdding: .day, value: -7, to: now) ?? .distantPast)
        case .thirtyDays: date >= (calendar.date(byAdding: .day, value: -30, to: now) ?? .distantPast)
        }
    }
}

struct ClipboardHistoryEntry: Identifiable {
    let item: ClipboardItem
    let position: Int
    var id: UUID { item.id }
    var shortcutNumber: Int? { position < 9 ? position + 1 : nil }
}

struct ClipboardHistorySection: Identifiable {
    enum ID: Hashable { case pinned, day(Date) }
    let id: ID
    var entries: [ClipboardHistoryEntry]

    func title(now: Date, calendar: Calendar = .current) -> String {
        switch id {
        case .pinned: return String(localized: "Pinned")
        case let .day(day):
            if calendar.isDate(day, inSameDayAs: now) { return String(localized: "Today") }
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
               calendar.isDate(day, inSameDayAs: yesterday) { return String(localized: "Yesterday") }
            return day.formatted(.dateTime.month(.abbreviated).day().year())
        }
    }
}

struct ClipboardHistorySnapshot {
    let items: [ClipboardItem]
    let sections: [ClipboardHistorySection]

    init(items: [ClipboardItem], query: ClipboardHistoryQuery, now: Date = Date(), calendar: Calendar = .current) {
        self.items = items.filter { query.matches($0, now: now, calendar: calendar) }
        // The store already orders pinned items first, then newest first. Do not
        // reorder here: selection, arrow keys and Option-number must agree.
        var sections: [ClipboardHistorySection] = []
        for (position, item) in self.items.enumerated() {
            let sectionID: ClipboardHistorySection.ID = item.isPinned
                ? .pinned : .day(calendar.startOfDay(for: item.copiedAt))
            let entry = ClipboardHistoryEntry(item: item, position: position)
            if sections.last?.id == sectionID {
                sections[sections.count - 1].entries.append(entry)
            } else {
                sections.append(ClipboardHistorySection(id: sectionID, entries: [entry]))
            }
        }
        self.sections = sections
    }
}

/// Content presentation never changes the stored payload or the copied value.
enum ClipboardItemPresentation {
    static func linkDetail(_ value: String) -> String {
        guard let url = URL(string: value), let host = url.host() else { return value }
        let path = url.path(percentEncoded: false)
        return path.isEmpty || path == "/" ? host : host + path
    }

    static func usesMonospacedText(_ item: ClipboardItem) -> Bool {
        item.semanticType == .code || item.semanticType == .json || item.semanticType == .color
    }

    static func symbol(for item: ClipboardItem) -> String {
        if let semanticType = item.semanticType {
            switch semanticType {
            case .code: return "chevron.left.forwardslash.chevron.right"
            case .json: return "curlybraces"
            case .color: return "paintpalette"
            case .email: return "envelope"
            case .phoneNumber: return "phone"
            }
        }
        switch item.kind {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .image: return "photo"
        case .fileURLs: return "doc"
        case .snip: return "scissors"
        }
    }

    static func title(for item: ClipboardItem) -> String {
        switch item.kind {
        case let .link(value):
            return item.title.isEmpty || item.title == value ? (URL(string: value)?.host() ?? value) : item.title
        case let .fileURLs(paths):
            guard let first = paths.first else { return item.title }
            let name = URL(fileURLWithPath: first).lastPathComponent
            return paths.count > 1 ? String(localized: "\(name) and \(paths.count - 1) more") : name
        case let .text(value):
            let excerpt = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
            return excerpt.isEmpty ? item.title : excerpt
        case .image, .snip: return item.title
        }
    }
}

struct ClipboardColorComponents: Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    var prefersDarkText: Bool {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue) > 0.179
    }

    init?(text: String) {
        let hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard [3, 4, 6, 8].contains(hex.count) else { return nil }
        let expanded = hex.count <= 4 ? hex.map { "\($0)\($0)" }.joined() : hex
        guard let value = UInt64(expanded, radix: 16) else { return nil }
        let hasAlpha = expanded.count == 8
        red = Double((value >> (hasAlpha ? 24 : 16)) & 0xff) / 255
        green = Double((value >> (hasAlpha ? 16 : 8)) & 0xff) / 255
        blue = Double((value >> (hasAlpha ? 8 : 0)) & 0xff) / 255
        alpha = hasAlpha ? Double(value & 0xff) / 255 : 1
    }
}
