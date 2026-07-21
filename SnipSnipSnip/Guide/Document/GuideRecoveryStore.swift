import Foundation

nonisolated final class GuideRecoveryStore: @unchecked Sendable {
    private let lock = NSLock()
    private let files: any FileSystemServicing
    let rootURL: URL

    init(files: any FileSystemServicing = SystemFileService(), rootURL: URL? = nil) {
        self.files = files
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? files.temporaryDirectory
            self.rootURL = support
                .appendingPathComponent("SnipSnipSnip", isDirectory: true)
                .appendingPathComponent("Recovery/Guides", isDirectory: true)
        }
    }

    func save(_ document: EditableGuideDocument) throws {
        guard !document.project.isPrivate else { return }
        lock.lock(); defer { lock.unlock() }
        try files.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let url = recoveryURL(for: document.project.id)
        try SSSGuideDocumentPackage.saveRecoveryCheckpoint(document: document, to: url, files: files)
    }

    func newestRecoveryURL() -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard let urls = try? FileManager.default.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return nil }
        return urls.filter { $0.pathExtension.lowercased() == "sssguide" }.max {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left < right
        }
    }

    func loadNewest() throws -> EditableGuideDocument? {
        guard let url = newestRecoveryURL() else { return nil }
        return try SSSGuideDocumentPackage.load(from: url, files: files)
    }

    func remove(projectID: UUID) {
        lock.lock(); defer { lock.unlock() }
        try? files.removeItem(at: recoveryURL(for: projectID))
    }

    private func recoveryURL(for projectID: UUID) -> URL {
        rootURL.appendingPathComponent(projectID.uuidString.lowercased()).appendingPathExtension("sssguide")
    }
}
