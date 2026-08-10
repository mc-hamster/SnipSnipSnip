import Foundation

nonisolated final class VideoRecoveryStore: @unchecked Sendable {
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
                .appendingPathComponent("Recovery/Videos", isDirectory: true)
        }
    }

    var recoveryURL: URL {
        rootURL.appendingPathComponent("last-session.sssvideo", isDirectory: true)
    }

    func save(_ document: EditableVideoDocument) throws {
        lock.lock(); defer { lock.unlock() }
        try files.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try SSSVideoDocumentPackage.saveRecoveryCheckpoint(
            document: document,
            to: recoveryURL,
            files: files
        )
    }

    func load() throws -> EditableVideoDocument? {
        lock.lock(); defer { lock.unlock() }
        guard files.directoryExists(at: recoveryURL) else { return nil }
        return try SSSVideoDocumentPackage.load(from: recoveryURL, files: files)
    }

    func hasRecovery() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return files.directoryExists(at: recoveryURL)
    }

    func remove() {
        lock.lock(); defer { lock.unlock() }
        try? files.removeItem(at: recoveryURL)
    }
}
