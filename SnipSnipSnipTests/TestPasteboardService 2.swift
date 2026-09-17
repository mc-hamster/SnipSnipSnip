import AppKit
@testable import SnipSnipSnip

@MainActor
final class TestPasteboardService: PasteboardServicing, @unchecked Sendable {
    private var strings: [NSPasteboard.PasteboardType: String] = [:]
    private var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
    private var urls: [URL] = []
    private var snapshotWriteFailuresRemaining = 0
    var rejectsDataWrites = false

    private(set) var changeCount = 0

    var typeNames: [String] {
        Array(Set(strings.keys.map(\.rawValue) + dataByType.keys.map(\.rawValue)))
    }

    @discardableResult
    func clearContents() -> Bool {
        strings.removeAll()
        dataByType.removeAll()
        urls.removeAll()
        changeCount += 1
        return true
    }

    func fileAndWebURLs() -> [URL] {
        urls
    }

    func data(forType type: NSPasteboard.PasteboardType) -> Data? {
        dataByType[type]
    }

    func string(forType type: NSPasteboard.PasteboardType) -> String? {
        strings[type]
    }

    func itemSnapshots(acceptedTypeIdentifiers: Set<String>) -> [PasteboardItemSnapshot] {
        let representations = dataByType.compactMap { type, data in
            acceptedTypeIdentifiers.contains(type.rawValue)
                ? PasteboardRepresentationSnapshot(typeIdentifier: type.rawValue, data: data)
                : nil
        }
        return representations.isEmpty ? [] : [PasteboardItemSnapshot(representations: representations)]
    }

    @discardableResult
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool {
        strings[type] = string
        dataByType[type] = Data(string.utf8)
        changeCount += 1
        return true
    }

    @discardableResult
    func setData(_ data: Data, forType type: NSPasteboard.PasteboardType) -> Bool {
        guard !rejectsDataWrites else { return false }
        dataByType[type] = data
        changeCount += 1
        return true
    }

    @discardableResult
    func writeFileURLs(_ urls: [URL]) -> Bool {
        self.urls = urls
        changeCount += 1
        return true
    }

    @discardableResult
    func writeItemSnapshots(_ items: [PasteboardItemSnapshot]) -> Bool {
        if snapshotWriteFailuresRemaining > 0 {
            snapshotWriteFailuresRemaining -= 1
            return false
        }
        guard !items.isEmpty else { return false }
        strings.removeAll()
        dataByType.removeAll()
        for item in items {
            for representation in item.representations {
                dataByType[NSPasteboard.PasteboardType(representation.typeIdentifier)] = representation.data
                if representation.typeIdentifier == NSPasteboard.PasteboardType.string.rawValue {
                    strings[.string] = String(data: representation.data, encoding: .utf8)
                }
            }
        }
        changeCount += 1
        return true
    }

    func failNextSnapshotWrite() {
        snapshotWriteFailuresRemaining += 1
    }

    func addType(_ typeName: String) {
        dataByType[NSPasteboard.PasteboardType(typeName)] = Data()
        changeCount += 1
    }
}
