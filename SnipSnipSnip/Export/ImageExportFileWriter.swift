import Foundation

nonisolated enum ImageExportFileWriter {
    /// The caller keeps security-scoped access to the destination active for this operation.
    static func write(to destinationURL: URL, encode: (URL) throws -> Void) throws {
        try Task.checkCancellation()
        let fileManager = FileManager.default

        // A save-panel grant can cover only the selected file, not arbitrary siblings.
        // Ask macOS for writable staging on the destination volume so replacement
        // also works when the selected file lives outside the app's sandbox.
        let stagingDirectory = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destinationURL,
            create: true
        )
        defer { try? fileManager.removeItem(at: stagingDirectory) }

        let stagedURL = stagingDirectory.appendingPathComponent(destinationURL.lastPathComponent)
        try encode(stagedURL)
        try Task.checkCancellation()

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
