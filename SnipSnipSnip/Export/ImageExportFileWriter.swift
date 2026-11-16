import Foundation

nonisolated enum ImageExportFileWriter {
    /// The caller keeps security-scoped access to the destination active for this operation.
    static func write(to destinationURL: URL, encode: (URL) throws -> Void) throws {
        try Task.checkCancellation()
        let stagingDirectory = try makeStagingDirectory(for: destinationURL)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }

        let stagedURL = stagingDirectory.appendingPathComponent(destinationURL.lastPathComponent)
        try encode(stagedURL)
        try install(stagedURL, at: destinationURL)
    }

    /// Async encoders retain the same staging, cancellation, and replacement guarantees.
    static func write(to destinationURL: URL, encode: (URL) async throws -> Void) async throws {
        try Task.checkCancellation()
        let stagingDirectory = try makeStagingDirectory(for: destinationURL)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }

        let stagedURL = stagingDirectory.appendingPathComponent(destinationURL.lastPathComponent)
        try await encode(stagedURL)
        try install(stagedURL, at: destinationURL)
    }

    private static func makeStagingDirectory(for destinationURL: URL) throws -> URL {
        // A save-panel grant can cover only the selected file, not arbitrary siblings.
        // Ask macOS for writable staging on the destination volume so replacement
        // also works when the selected file lives outside the app's sandbox.
        try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destinationURL,
            create: true
        )
    }

    private static func install(_ stagedURL: URL, at destinationURL: URL) throws {
        try Task.checkCancellation()
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: stagedURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: stagedURL, to: destinationURL)
        }
    }
}
